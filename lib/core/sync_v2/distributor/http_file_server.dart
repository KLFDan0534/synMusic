import 'dart:async';
import 'dart:io';

import '../diagnostics/sync_log.dart';
import 'track_meta.dart';

/// HTTP 文件服务器（Host 端）
/// 用于向 Client 提供音频文件下载
class HttpFileServer {
  // 单例
  static final HttpFileServer _instance = HttpFileServer._internal();
  factory HttpFileServer() => _instance;
  HttpFileServer._internal();

  // HTTP 服务器
  HttpServer? _server;

  // 当前服务的曲目
  TrackMeta? _currentTrack;

  // 服务端口
  int _port = 8787;
  static const int kDefaultPort = 8787;

  // 状态
  bool _isRunning = false;

  // 缓存的局域网 IP
  String? _localIp;

  // 流控制器
  final _statusController = StreamController<HttpFileServerStatus>.broadcast();

  /// 状态流
  Stream<HttpFileServerStatus> get statusStream => _statusController.stream;

  /// 是否正在运行
  bool get isRunning => _isRunning;

  /// 当前端口
  int get port => _port;

  /// 当前曲目
  TrackMeta? get currentTrack => _currentTrack;

  /// 获取本机局域网 IP（公开）
  String get localIp => _localIp ?? '';

  /// 获取本机局域网 IP
  Future<String> _getLocalIp() async {
    if (_localIp != null) return _localIp!;

    try {
      final interfaces = await NetworkInterface.list();
      SyncLog.i(
        '[HttpFileServer] Found ${interfaces.length} network interfaces',
      );

      for (final interface in interfaces) {
        SyncLog.i('[HttpFileServer] Interface: ${interface.name}');
        for (final addr in interface.addresses) {
          SyncLog.i(
            '[HttpFileServer]   Address: ${addr.address}, type: ${addr.type}, loopback: ${addr.isLoopback}',
          );
          // 优先选择 IPv4 地址，且排除回环地址
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            _localIp = addr.address;
            SyncLog.i('[HttpFileServer] Selected local IP: $_localIp');
            return _localIp!;
          }
        }
      }
    } catch (e) {
      SyncLog.e('[HttpFileServer] Failed to get local IP', error: e);
    }
    _localIp = '127.0.0.1'; // fallback
    SyncLog.w('[HttpFileServer] No valid IP found, using fallback: $_localIp');
    return _localIp!;
  }

  /// 服务 URL（供 Client 下载）
  String get serviceUrl {
    if (!_isRunning || _currentTrack == null) {
      SyncLog.w(
        '[HttpFileServer] serviceUrl called but not running or no track',
      );
      return '';
    }
    // 使用缓存的局域网 IP
    final ip = _localIp;
    if (ip == null) {
      SyncLog.e('[HttpFileServer] serviceUrl: _localIp is null!');
      return '';
    }
    final url = 'http://$ip:$_port/track/${_currentTrack!.trackId}';
    SyncLog.i('[HttpFileServer] serviceUrl: $url');
    return url;
  }

  /// 启动服务器
  Future<bool> start({int? port, required TrackMeta track}) async {
    if (_isRunning) {
      SyncLog.w('[HttpFileServer] Already running, stopping first');
      await stop();
    }

    _port = port ?? kDefaultPort;
    _currentTrack = track;

    try {
      // 获取本机局域网 IP
      await _getLocalIp();

      // 绑定到所有网络接口
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _isRunning = true;

      SyncLog.i(
        '[HttpFileServer] Started on port $_port, serving track ${track.trackId}',
        role: 'host',
      );

      _statusController.add(
        HttpFileServerStatus(
          isRunning: true,
          port: _port,
          trackId: track.trackId,
        ),
      );

      // 开始监听请求
      _listenRequests();

      return true;
    } catch (e) {
      SyncLog.e('[HttpFileServer] Failed to start: $e', role: 'host', error: e);
      _isRunning = false;
      return false;
    }
  }

  /// 监听 HTTP 请求
  void _listenRequests() {
    _server?.listen((request) async {
      try {
        await _handleRequest(request);
      } catch (e) {
        SyncLog.e(
          '[HttpFileServer] Error handling request: $e',
          role: 'host',
          error: e,
        );
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    });
  }

  /// 处理 HTTP 请求
  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    SyncLog.d(
      '[HttpFileServer] Request: ${request.method} $path',
      role: 'host',
    );

    // 只处理 GET 请求
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    // 解析路径：/track/{trackId}
    if (path.startsWith('/track/')) {
      final trackId = path.substring(7); // 去掉 '/track/'
      await _serveTrack(request, trackId);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  /// 提供曲目文件
  Future<void> _serveTrack(HttpRequest request, String trackId) async {
    if (_currentTrack == null || _currentTrack!.trackId != trackId) {
      SyncLog.w('[HttpFileServer] Track not found: $trackId', role: 'host');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final file = File(_currentTrack!.localPath);
    if (!await file.exists()) {
      SyncLog.w(
        '[HttpFileServer] File not found: ${_currentTrack!.localPath}',
        role: 'host',
      );
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // 设置响应头
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('audio', 'mpeg');
    request.response.headers.contentLength = await file.length();
    request.response.headers.set('Access-Control-Allow-Origin', '*');

    // 支持 Range 请求（可选，V1 先不做）
    final range = request.headers.value('range');
    if (range != null) {
      // TODO: Round 5 实现 Range 支持
    }

    SyncLog.i(
      '[HttpFileServer] Serving track $trackId to ${request.connectionInfo?.remoteAddress.address}',
      role: 'host',
    );

    // 流式传输文件
    try {
      final stream = file.openRead();
      await stream.pipe(request.response);
      SyncLog.i('[HttpFileServer] Transfer complete: $trackId', role: 'host');
    } catch (e) {
      SyncLog.e('[HttpFileServer] Transfer error: $e', role: 'host', error: e);
    }
  }

  /// 停止服务器
  Future<void> stop() async {
    if (!_isRunning) return;

    await _server?.close();
    _server = null;
    _isRunning = false;
    _currentTrack = null;

    SyncLog.i('[HttpFileServer] Stopped', role: 'host');

    _statusController.add(
      HttpFileServerStatus(isRunning: false, port: _port, trackId: null),
    );
  }

  /// 释放资源
  void dispose() {
    stop();
    _statusController.close();
  }
}

/// HTTP 文件服务器状态
class HttpFileServerStatus {
  final bool isRunning;
  final int port;
  final String? trackId;

  const HttpFileServerStatus({
    required this.isRunning,
    required this.port,
    this.trackId,
  });
}
