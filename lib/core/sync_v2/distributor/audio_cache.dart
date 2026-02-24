import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/sync_log.dart';
import '../utils/background_executor.dart';

/// 下载状态
enum DownloadStatus {
  idle, // 空闲
  downloading, // 下载中
  verifying, // 校验中
  completed, // 完成
  failed, // 失败
}

/// 已缓存的曲目
class CachedTrack {
  final String trackId;
  final String localPath;
  final int sizeBytes;
  final DateTime cachedAt;

  const CachedTrack({
    required this.trackId,
    required this.localPath,
    required this.sizeBytes,
    required this.cachedAt,
  });

  String get formattedSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 下载进度
class DownloadProgress {
  final String trackId;
  final DownloadStatus status;
  final int bytesReceived;
  final int totalBytes;
  final double progress; // 0.0 - 1.0
  final String? errorCode;
  final String? errorMessage;
  final String? localPath;

  const DownloadProgress({
    required this.trackId,
    required this.status,
    this.bytesReceived = 0,
    this.totalBytes = 0,
    this.progress = 0.0,
    this.errorCode,
    this.errorMessage,
    this.localPath,
  });

  /// 格式化进度
  String get formattedProgress {
    final received = _formatBytes(bytesReceived);
    final total = _formatBytes(totalBytes);
    return '$received / $total (${(progress * 100).toStringAsFixed(1)}%)';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 音频缓存管理器（Client 端）
/// 负责下载、缓存和校验音频文件
class AudioCache {
  // 单例
  static final AudioCache _instance = AudioCache._internal();
  factory AudioCache() => _instance;
  AudioCache._internal();

  // 后台执行器
  final _executor = BackgroundExecutor();

  // 缓存目录
  String? _cacheDir;

  // 当前下载
  String? _currentTrackId;
  DownloadProgress _currentProgress = const DownloadProgress(
    trackId: '',
    status: DownloadStatus.idle,
  );

  // 流控制器
  final _progressController = StreamController<DownloadProgress>.broadcast();

  // 节流定时器
  Timer? _throttleTimer;
  DownloadProgress? _pendingProgress;
  static const Duration _throttleInterval = Duration(milliseconds: 250);

  /// 进度流（节流后）
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  /// 当前进度
  DownloadProgress get currentProgress => _currentProgress;

  /// 缓存目录
  Future<String> get cacheDir async {
    if (_cacheDir != null) return _cacheDir!;
    final dir = await getApplicationDocumentsDirectory();
    _cacheDir = '${dir.path}/sync_music_cache';
    await Directory(_cacheDir!).create(recursive: true);
    return _cacheDir!;
  }

  /// 获取已缓存的文件列表
  Future<List<CachedTrack>> getCachedTracks() async {
    final dir = await cacheDir;
    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final files = await directory.list().toList();
    final tracks = <CachedTrack>[];

    for (final file in files) {
      if (file is File && file.path.endsWith('.mp3')) {
        final stat = await file.stat();
        final fileName = file.path.split('/').last;
        // 从文件名提取 trackId（格式: trackId.mp3）
        final trackId = fileName.replaceAll('.mp3', '');
        tracks.add(
          CachedTrack(
            trackId: trackId,
            localPath: file.path,
            sizeBytes: stat.size,
            cachedAt: stat.modified,
          ),
        );
      }
    }

    return tracks..sort((a, b) => b.cachedAt.compareTo(a.cachedAt));
  }

  /// 下载并缓存音频文件
  Future<DownloadResult> downloadAndCache({
    required String trackId,
    required String url,
    required String expectedHash,
    required int expectedSize,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_currentTrackId == trackId &&
        _currentProgress.status == DownloadStatus.downloading) {
      SyncLog.w('[AudioCache] Already downloading: $trackId');
      return DownloadResult(
        success: false,
        errorCode: 'already_downloading',
        errorMessage: 'Already downloading this track',
      );
    }

    _currentTrackId = trackId;
    final startTime = DateTime.now();

    try {
      // 初始化进度
      _updateProgress(
        DownloadProgress(
          trackId: trackId,
          status: DownloadStatus.downloading,
          totalBytes: expectedSize,
        ),
      );

      // 获取缓存路径
      final dir = await cacheDir;
      final fileName = '${trackId}_$expectedHash.mp3';
      final localPath = '$dir/$fileName';

      // 检查是否已缓存
      final existingFile = File(localPath);
      if (await existingFile.exists()) {
        final existingSize = await existingFile.length();
        if (existingSize == expectedSize) {
          // 验证 hash
          _updateProgress(
            DownloadProgress(
              trackId: trackId,
              status: DownloadStatus.verifying,
              totalBytes: expectedSize,
              bytesReceived: expectedSize,
              progress: 1.0,
            ),
          );

          final actualHash = await _executor.computeFileSha1(localPath);
          if (actualHash == expectedHash) {
            SyncLog.i('[AudioCache] Already cached: $trackId');
            _updateProgress(
              DownloadProgress(
                trackId: trackId,
                status: DownloadStatus.completed,
                totalBytes: expectedSize,
                bytesReceived: expectedSize,
                progress: 1.0,
                localPath: localPath,
              ),
            );
            return DownloadResult(
              success: true,
              localPath: localPath,
              prepareMs: DateTime.now().difference(startTime).inMilliseconds,
            );
          } else {
            // Hash 不匹配，删除重新下载
            await existingFile.delete();
            SyncLog.w('[AudioCache] Hash mismatch, re-downloading: $trackId');
          }
        }
      }

      // 创建临时文件
      final tempPath = '$localPath.tmp';
      final tempFile = File(tempPath);
      final sink = tempFile.openWrite();

      try {
        // 流式下载
        final client = http.Client();
        final request = http.Request('GET', Uri.parse(url));
        final response = await client.send(request).timeout(timeout);

        if (response.statusCode != 200) {
          throw DownloadException(
            'http_${response.statusCode}',
            'HTTP error: ${response.statusCode}',
          );
        }

        int bytesReceived = 0;
        final contentLength = response.contentLength ?? expectedSize;

        await for (final chunk in response.stream) {
          sink.add(chunk);
          bytesReceived += chunk.length;

          // 更新进度（节流）
          _updateProgress(
            DownloadProgress(
              trackId: trackId,
              status: DownloadStatus.downloading,
              bytesReceived: bytesReceived,
              totalBytes: contentLength,
              progress: contentLength > 0 ? bytesReceived / contentLength : 0,
            ),
          );
        }

        await sink.close();
        client.close();

        // 验证文件大小
        final actualSize = await tempFile.length();
        if (actualSize != expectedSize) {
          throw DownloadException(
            'size_mismatch',
            'Size mismatch: expected $expectedSize, got $actualSize',
          );
        }

        // 验证 hash
        _updateProgress(
          DownloadProgress(
            trackId: trackId,
            status: DownloadStatus.verifying,
            totalBytes: expectedSize,
            bytesReceived: expectedSize,
            progress: 1.0,
          ),
        );

        final actualHash = await _executor.computeFileSha1(tempPath);
        if (actualHash != expectedHash) {
          throw DownloadException(
            'hash_mismatch',
            'Hash mismatch: expected $expectedHash, got $actualHash',
          );
        }

        // 重命名临时文件
        await tempFile.rename(localPath);

        final prepareMs = DateTime.now().difference(startTime).inMilliseconds;

        SyncLog.i(
          '[AudioCache] Download complete: $trackId, size=$expectedSize, prepareMs=$prepareMs',
          role: 'client',
        );

        _updateProgress(
          DownloadProgress(
            trackId: trackId,
            status: DownloadStatus.completed,
            totalBytes: expectedSize,
            bytesReceived: expectedSize,
            progress: 1.0,
            localPath: localPath,
          ),
        );

        return DownloadResult(
          success: true,
          localPath: localPath,
          prepareMs: prepareMs,
        );
      } catch (e) {
        await sink.close();
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        rethrow;
      }
    } on DownloadException catch (e) {
      SyncLog.e(
        '[AudioCache] Download failed: $trackId, error=${e.code}',
        role: 'client',
        error: e,
      );
      _updateProgress(
        DownloadProgress(
          trackId: trackId,
          status: DownloadStatus.failed,
          errorCode: e.code,
          errorMessage: e.message,
        ),
      );
      return DownloadResult(
        success: false,
        errorCode: e.code,
        errorMessage: e.message,
      );
    } on TimeoutException catch (e) {
      SyncLog.e(
        '[AudioCache] Download timeout: $trackId',
        role: 'client',
        error: e,
      );
      _updateProgress(
        DownloadProgress(
          trackId: trackId,
          status: DownloadStatus.failed,
          errorCode: 'timeout',
          errorMessage: 'Download timeout',
        ),
      );
      return DownloadResult(
        success: false,
        errorCode: 'timeout',
        errorMessage: 'Download timeout',
      );
    } catch (e) {
      SyncLog.e(
        '[AudioCache] Download failed: $trackId, error=$e',
        role: 'client',
        error: e,
      );
      _updateProgress(
        DownloadProgress(
          trackId: trackId,
          status: DownloadStatus.failed,
          errorCode: 'download_failed',
          errorMessage: e.toString(),
        ),
      );
      return DownloadResult(
        success: false,
        errorCode: 'download_failed',
        errorMessage: e.toString(),
      );
    }
  }

  /// 更新进度（节流）
  void _updateProgress(DownloadProgress progress) {
    _currentProgress = progress;
    _pendingProgress = progress;

    _throttleTimer?.cancel();
    _throttleTimer = Timer(_throttleInterval, () {
      if (_pendingProgress != null) {
        _progressController.add(_pendingProgress!);
        _pendingProgress = null;
      }
    });
  }

  /// 清理缓存
  Future<void> clearCache() async {
    final dir = await cacheDir;
    final directory = Directory(dir);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
      await directory.create(recursive: true);
    }
    SyncLog.i('[AudioCache] Cache cleared');
  }

  /// 释放资源
  void dispose() {
    _throttleTimer?.cancel();
    _progressController.close();
  }
}

/// 下载结果
class DownloadResult {
  final bool success;
  final String? localPath;
  final int prepareMs;
  final String? errorCode;
  final String? errorMessage;

  const DownloadResult({
    required this.success,
    this.localPath,
    this.prepareMs = 0,
    this.errorCode,
    this.errorMessage,
  });
}

/// 下载异常
class DownloadException implements Exception {
  final String code;
  final String message;

  DownloadException(this.code, this.message);

  @override
  String toString() => 'DownloadException($code): $message';
}
