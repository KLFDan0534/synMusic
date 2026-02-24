import 'dart:async';
import 'dart:io';

import '../diagnostics/sync_log.dart';

/// 音源分发器（Host 端）
/// 通过 HTTP 服务分发音频文件
class AudioDistributor {
  // HTTP 服务器
  HttpServer? _server;

  // 分发的音频文件列表
  final Map<String, AudioSourceInfo> _sources = {};

  // 服务端口
  int _port = 8080;

  // 是否正在运行
  bool _isRunning = false;

  /// 服务端口
  int get port => _port;

  /// 是否正在运行
  bool get isRunning => _isRunning;

  /// 已注册的音源列表
  List<AudioSourceInfo> get sources => _sources.values.toList();

  /// 启动分发服务
  Future<bool> start({int port = 8080}) async {
    if (_isRunning) {
      SyncLog.w('Distributor already running', role: 'host');
      return true;
    }

    _port = port;

    try {
      // 绑定 HTTP 服务器
      _server = await HttpServer.bind('0.0.0.0', port);
      _isRunning = true;

      // 处理请求
      _server!.listen(_handleRequest);

      SyncLog.i('Audio distributor started on port $port', role: 'host');
      return true;
    } catch (e, s) {
      SyncLog.e(
        'Failed to start distributor',
        role: 'host',
        error: e,
        stackTrace: s,
      );
      return false;
    }
  }

  /// 停止分发服务
  Future<void> stop() async {
    if (!_isRunning) return;

    await _server?.close();
    _server = null;
    _isRunning = false;
    _sources.clear();

    SyncLog.i('Audio distributor stopped', role: 'host');
  }

  /// 注册音源
  Future<AudioSourceInfo?> registerSource({
    required String sourceId,
    required String filePath,
    String? displayName,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        SyncLog.w('File not found: $filePath', role: 'host');
        return null;
      }

      // 在 Isolate 中计算 hash（避免阻塞 UI）
      final hash = await _computeHash(filePath);
      final stat = await file.stat();

      final info = AudioSourceInfo(
        sourceId: sourceId,
        filePath: filePath,
        displayName: displayName ?? filePath.split('/').last,
        fileSize: stat.size,
        hash: hash,
        codec: _detectCodec(filePath),
      );

      _sources[sourceId] = info;

      SyncLog.i(
        'Registered audio source: $sourceId',
        role: 'host',
        roomId: sourceId,
      );

      return info;
    } catch (e, s) {
      SyncLog.e(
        'Failed to register source',
        role: 'host',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  /// 取消注册音源
  void unregisterSource(String sourceId) {
    _sources.remove(sourceId);
    SyncLog.d('Unregistered source: $sourceId', role: 'host');
  }

  /// 处理 HTTP 请求
  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    SyncLog.d('HTTP request: $path', role: 'host');

    // 列表接口
    if (path == '/sources' || path == '/sources/') {
      _handleSourcesList(request);
      return;
    }

    // 文件下载接口
    if (path.startsWith('/source/')) {
      final sourceId = path.substring(8);
      await _handleSourceDownload(request, sourceId);
      return;
    }

    // Hash 校验接口
    if (path.startsWith('/hash/')) {
      final sourceId = path.substring(6);
      _handleHashCheck(request, sourceId);
      return;
    }

    // 未知路径
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  /// 处理列表请求
  void _handleSourcesList(HttpRequest request) {
    final sources = _sources.values
        .map(
          (s) => {
            'sourceId': s.sourceId,
            'displayName': s.displayName,
            'fileSize': s.fileSize,
            'hash': s.hash,
            'codec': s.codec,
          },
        )
        .toList();

    request.response.headers.contentType = ContentType.json;
    request.response.write('{"sources": ${sources.toString()}}');
    request.response.close();
  }

  /// 处理文件下载请求
  Future<void> _handleSourceDownload(
    HttpRequest request,
    String sourceId,
  ) async {
    final source = _sources[sourceId];
    if (source == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final file = File(source.filePath);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // 支持范围请求（断点续传）
    final range = request.headers.value('range');
    if (range != null) {
      await _handleRangeRequest(request, file, range);
    } else {
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.contentLength = source.fileSize;
      await file.openRead().pipe(request.response);
    }

    SyncLog.i('Served audio: $sourceId', role: 'host');
  }

  /// 处理范围请求
  Future<void> _handleRangeRequest(
    HttpRequest request,
    File file,
    String range,
  ) async {
    // 解析范围
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (match == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final start = int.parse(match.group(1)!);
    final fileLength = await file.length();
    final end = match.group(2)!.isEmpty
        ? fileLength - 1
        : int.parse(match.group(2)!);

    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      'Content-Range',
      'bytes $start-$end/$fileLength',
    );
    request.response.headers.contentLength = end - start + 1;

    final raf = await file.open(mode: FileMode.read);
    await raf.setPosition(start);

    // 读取并发送
    final remaining = end - start + 1;
    var sent = 0;
    const chunkSize = 64 * 1024; // 64KB chunks

    while (sent < remaining) {
      final toRead = (remaining - sent).clamp(0, chunkSize);
      final bytes = await raf.read(toRead);
      request.response.add(bytes);
      sent += bytes.length;
    }

    await raf.close();
    await request.response.close();
  }

  /// 处理 Hash 校验请求
  void _handleHashCheck(HttpRequest request, String sourceId) {
    final source = _sources[sourceId];
    if (source == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
      return;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write('{"hash": "${source.hash}"}');
    request.response.close();
  }

  /// 计算 SHA256 hash（在 Isolate 中执行）
  Future<String> _computeHash(String filePath) async {
    // 简化实现：使用文件大小和修改时间作为 "hash"
    // TODO: 实际实现应该在 Isolate 中计算 SHA256
    final file = File(filePath);
    final stat = await file.stat();
    return 'size_${stat.size}_time_${stat.modified.millisecondsSinceEpoch}';
  }

  /// 检测编解码器
  String _detectCodec(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp3':
        return 'mp3';
      case 'm4a':
      case 'aac':
        return 'aac';
      case 'wav':
        return 'pcm';
      case 'flac':
        return 'flac';
      default:
        return 'unknown';
    }
  }
}

/// 音源信息
class AudioSourceInfo {
  final String sourceId;
  final String filePath;
  final String displayName;
  final int fileSize;
  final String hash;
  final String codec;

  const AudioSourceInfo({
    required this.sourceId,
    required this.filePath,
    required this.displayName,
    required this.fileSize,
    required this.hash,
    required this.codec,
  });

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'displayName': displayName,
    'fileSize': fileSize,
    'hash': hash,
    'codec': codec,
  };
}
