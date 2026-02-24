import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../diagnostics/sync_log.dart';
import 'transport_interface.dart';
import 'protocol.dart';

/// WebSocket Transport 实现
/// 使用 WebSocket 进行设备间通信
class WebSocketTransport implements Transport {
  // 连接状态
  TransportState _state = TransportState.disconnected;
  final _stateController = StreamController<TransportState>.broadcast();

  // 消息流
  final _messageController = StreamController<TransportMessage>.broadcast();

  // 连接的客户端列表（Host 模式）
  final Map<String, WebSocket> _connectedPeers = {};
  final Map<String, String> _peerSessionIds = {}; // peerId -> sessionId
  final Map<String, String> _originalPeerIdToClientId =
      {}; // 临时 peerId -> 客户端 peerId 映射

  // WebSocket 连接（Client 模式）
  WebSocket? _webSocket;
  String? _sessionId;

  // WebSocket 服务器（Host 模式）
  HttpServer? _httpServer;

  // 重连相关
  Timer? _reconnectTimer;
  String? _reconnectHost;
  int? _reconnectPort;
  int _reconnectCount = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _reconnectDelay = Duration(seconds: 2);

  // Transport 日志
  final List<String> _transportLogs = [];
  static const int _maxLogEntries = 200; // 增加到 200 条
  final _logController = StreamController<String>.broadcast();

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportMessage> get messageStream => _messageController.stream;

  @override
  List<String> get connectedPeers => _connectedPeers.keys.toList();

  /// 获取 session ID
  String? get sessionId => _sessionId;

  /// 获取重连次数
  int get reconnectCount => _reconnectCount;

  /// 获取 transport 日志
  List<String> get transportLogs => List.unmodifiable(_transportLogs);

  /// 获取日志流（供 UI 节流监听）
  Stream<String> get logStream => _logController.stream;

  void _updateState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(_state);
      _addLog('State changed: $newState');
      SyncLog.d('Transport state changed: $newState');
    }
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 23);
    final logEntry = '[$timestamp] $message';
    _transportLogs.add(logEntry);
    if (_transportLogs.length > _maxLogEntries) {
      _transportLogs.removeAt(0);
    }
    // 发送到日志流（供 UI 节流监听）
    _logController.add(logEntry);
  }

  // ==================== Client 模式 ====================

  @override
  Future<void> connect(String host, int port) async {
    if (_state == TransportState.connected ||
        _state == TransportState.connecting) {
      SyncLog.w('Already connected or connecting, ignoring connect request');
      return;
    }

    _reconnectHost = host;
    _reconnectPort = port;
    _updateState(TransportState.connecting);

    _addLog('Connecting to $host:$port');
    SyncLog.i('Connecting to $host:$port', role: 'client');

    try {
      final socket = await WebSocket.connect('ws://$host:$port');
      _webSocket = socket;

      socket.listen(
        _onClientMessage,
        onError: _onClientError,
        onDone: _onClientDone,
      );

      _updateState(TransportState.connected);
      _addLog('Connected to server');
      SyncLog.i('Connected to $host:$port', role: 'client');

      // 开始心跳
      _startHeartbeat();

      // 重置重连计数
      _reconnectCount = 0;
    } catch (e, s) {
      _addLog('Connect failed: $e');
      SyncLog.e('Failed to connect', role: 'client', error: e, stackTrace: s);
      _updateState(TransportState.error);
      _scheduleReconnect();
      rethrow;
    }
  }

  /// 发送握手消息
  Future<void> sendHello({
    required String roomId,
    required String peerId,
    required String deviceInfo,
  }) async {
    final hello = HelloMessage(
      protoVer: kProtoVer,
      roomId: roomId,
      peerId: peerId,
      role: 'client',
      deviceInfo: deviceInfo,
    );
    await _sendJson(hello.toJson());
    _addLog('Sent hello');
  }

  void _onClientMessage(dynamic data) {
    Map<String, dynamic>? json;
    try {
      // 安全解码，避免强转失败
      final decoded = jsonDecode(data as String);
      if (decoded is! Map<String, dynamic>) {
        _logUnknownMessage(data, null, 'decoded is not a Map');
        return;
      }
      json = decoded;
    } catch (e) {
      _logUnknownMessage(data, null, 'jsonDecode failed: $e');
      return;
    }

    final type = extractType(json);
    if (type == null) {
      _logUnknownMessage(data, json, 'no type field');
      return;
    }

    final message = parseMessage(json);

    // 先处理特殊消息（如 pong），但不重复添加到消息流
    if (message != null) {
      _handleClientMessage(message, json);
    }

    // 统一添加到消息流（使用原始 json 作为 payload）
    final transportMsg = TransportMessage(
      type: type,
      payload: json,
      timestamp: DateTime.now(),
    );
    _messageController.add(transportMsg);
  }

  /// 记录未知消息（限频 2 秒）
  static DateTime? _lastUnknownLogTime;
  void _logUnknownMessage(
    dynamic raw,
    Map<String, dynamic>? json,
    String reason,
  ) {
    final now = DateTime.now();
    if (_lastUnknownLogTime != null &&
        now.difference(_lastUnknownLogTime!).inSeconds < 2) {
      return; // 限频：2 秒内只记录一条
    }
    _lastUnknownLogTime = now;

    final rawStr = raw?.toString() ?? 'null';
    final truncated = rawStr.length > 200 ? rawStr.substring(0, 200) : rawStr;
    final keys = json?.keys.toList() ?? [];
    final keysStr = keys.isEmpty ? '[]' : keys.toString();

    _addLog('unknown_message keys=$keysStr reason=$reason');
    SyncLog.w(
      '[Transport] unknown_message keys=$keysStr raw="$truncated"',
      rateLimitKey: 'unknown_message',
    );
  }

  void _handleClientMessage(
    SyncMessage message,
    Map<String, dynamic> originalJson,
  ) {
    switch (message.type) {
      case SyncProtocol.welcome:
        final welcome = message as WelcomeMessage;
        _sessionId = welcome.sessionId;
        _addLog('Received welcome, sessionId: $_sessionId');
        SyncLog.i('Received welcome from server', role: 'client');
        break;

      case SyncProtocol.pong:
        final pong = message as PongMessage;
        final t2ClientMs = DateTime.now().millisecondsSinceEpoch;
        final rtt = t2ClientMs - pong.t0ClientMs;
        _addLog('Received pong seq=${pong.seq}, RTT: ${rtt}ms');
        // 不需要在这里添加到消息流，_onClientMessage 会统一处理
        break;

      case SyncProtocol.peerJoin:
        final join = message as PeerJoinMessage;
        _addLog('Peer joined: ${join.peerId}');
        break;

      case SyncProtocol.peerLeave:
        final leave = message as PeerLeaveMessage;
        _addLog('Peer left: ${leave.peerId}');
        break;
    }
  }

  void _onClientError(dynamic error) {
    _addLog('WebSocket error: $error');
    SyncLog.e('WebSocket error', role: 'client', error: error);
    _updateState(TransportState.error);
    _scheduleReconnect();
  }

  void _onClientDone() {
    _addLog('WebSocket closed by server');
    SyncLog.w('WebSocket closed by server', role: 'client');
    _updateState(TransportState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectCount >= _maxReconnectAttempts) {
      _addLog('Max reconnect attempts reached');
      SyncLog.w('Max reconnect attempts reached', role: 'client');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () async {
      if (_reconnectHost != null && _reconnectPort != null) {
        _reconnectCount++;
        _addLog('Reconnecting... (attempt $_reconnectCount)');
        try {
          await connect(_reconnectHost!, _reconnectPort!);
        } catch (e) {
          // 忽略重连错误，会再次调度
        }
      }
    });
  }

  // ==================== Host 模式 ====================

  @override
  Future<void> startServer(int port) async {
    if (_state == TransportState.hosting) {
      SyncLog.w('Already hosting, ignoring start request');
      return;
    }

    _addLog('Starting server on port $port');
    SyncLog.i('Starting server on port $port', role: 'host');

    try {
      _httpServer = await HttpServer.bind('0.0.0.0', port);
      _httpServer!.listen(_onHttpRequest);

      _updateState(TransportState.hosting);
      _addLog('Server started on port $port');
      SyncLog.i('Server started on port $port', role: 'host');

      // 开始心跳广播
      _startHeartbeat();
    } catch (e, s) {
      _addLog('Server start failed: $e');
      SyncLog.e(
        'Failed to start server',
        role: 'host',
        error: e,
        stackTrace: s,
      );
      _updateState(TransportState.error);
      rethrow;
    }
  }

  void _onHttpRequest(HttpRequest request) {
    if (request.headers.value('upgrade')?.toLowerCase() == 'websocket') {
      _upgradeWebSocket(request);
    } else {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.close();
    }
  }

  Future<void> _upgradeWebSocket(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final peerId = 'peer_${DateTime.now().millisecondsSinceEpoch}';

      _connectedPeers[peerId] = socket;
      _addLog('Peer connected: $peerId');
      SyncLog.i('Peer connected: $peerId', role: 'host');

      socket.listen(
        (data) => _onHostMessage(data, peerId),
        onError: (error) => _onHostError(error, peerId),
        onDone: () => _onHostDone(peerId),
      );
    } catch (e) {
      _addLog('WebSocket upgrade failed: $e');
      SyncLog.e('WebSocket upgrade failed', role: 'host', error: e);
    }
  }

  void _onHostMessage(dynamic data, String peerId) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(data as String);
      if (decoded is! Map<String, dynamic>) {
        _logUnknownMessage(data, null, 'decoded is not a Map from $peerId');
        return;
      }
      json = decoded;
    } catch (e) {
      _logUnknownMessage(data, null, 'jsonDecode failed from $peerId: $e');
      return;
    }

    final type = extractType(json);
    if (type == null) {
      _logUnknownMessage(data, json, 'no type field from $peerId');
      return;
    }

    _addLog('Host received: $type from $peerId');
    final message = parseMessage(json);

    if (message != null) {
      _handleHostMessage(message, peerId);
    }

    final transportMsg = TransportMessage(
      type: type,
      payload: json,
      timestamp: DateTime.now(),
      senderId: peerId,
    );
    _messageController.add(transportMsg);
  }

  void _handleHostMessage(SyncMessage message, String peerId) {
    switch (message.type) {
      case SyncProtocol.hello:
        final hello = message as HelloMessage;
        // 更新 peerId 为客户端提供的 ID
        final clientPeerId = hello.peerId;
        if (clientPeerId != peerId && _connectedPeers.containsKey(peerId)) {
          final socket = _connectedPeers.remove(peerId)!;
          _connectedPeers[clientPeerId] = socket;
          _peerSessionIds[clientPeerId] = _generateSessionId();
          // 保存映射关系，用于后续消息处理
          _originalPeerIdToClientId[peerId] = clientPeerId;
          _addLog('Peer identified: $clientPeerId (was $peerId)');
        }

        // 发送 welcome
        final sessionId = _peerSessionIds[clientPeerId] ?? _generateSessionId();
        final welcome = WelcomeMessage(
          sessionId: sessionId,
          serverNowMs: DateTime.now().millisecondsSinceEpoch,
        );
        _sendToPeer(clientPeerId, welcome.toJson());
        _addLog('Sent welcome to $clientPeerId');

        // 广播 peer_join 给其他客户端
        final joinMsg = PeerJoinMessage(
          peerId: clientPeerId,
          role: hello.role,
          deviceInfo: hello.deviceInfo,
        );
        _broadcastExcept(joinMsg.toJson(), clientPeerId);

        // 同时发送给 SyncV2Controller 处理（让 Host 能收到）
        _messageController.add(
          TransportMessage.create(SyncProtocol.peerJoin, joinMsg.toJson()),
        );
        break;

      case SyncProtocol.ping:
        final ping = message as PingMessage;
        _addLog('Received ping seq=${ping.seq} t0=${ping.t0ClientMs}');
        final pong = PongMessage(
          seq: ping.seq,
          t0ClientMs: ping.t0ClientMs,
          t1ServerMs: DateTime.now().millisecondsSinceEpoch,
        );
        // 使用映射找到正确的客户端 peerId
        final clientPeerId = _originalPeerIdToClientId[peerId] ?? peerId;
        _sendToPeer(clientPeerId, pong.toJson());
        _addLog('Sent pong seq=${pong.seq} to $clientPeerId');
        // 使用 rate limit 降噪，每 2 秒最多打印 1 条
        SyncLog.i(
          '[Host] Sent pong seq=${pong.seq} to $clientPeerId',
          role: 'host',
          rateLimitKey: 'host_pong',
        );
        break;
    }
  }

  void _onHostError(dynamic error, String peerId) {
    _addLog('Peer $peerId error: $error');
    SyncLog.e('Peer $peerId error', role: 'host', error: error);
  }

  void _onHostDone(String peerId) {
    _connectedPeers.remove(peerId);
    _peerSessionIds.remove(peerId);
    _addLog('Peer disconnected: $peerId');
    SyncLog.i('Peer disconnected: $peerId', role: 'host');

    // 广播 peer_leave
    final leaveMsg = PeerLeaveMessage(peerId: peerId);
    _broadcast(leaveMsg.toJson());
  }

  String _generateSessionId() {
    return 'session_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
  }

  // ==================== 消息发送 ====================

  @override
  Future<void> send(TransportMessage message) async {
    if (_state != TransportState.connected) {
      SyncLog.w('Cannot send: not connected');
      return;
    }
    // 直接发送 payload，而不是封装后的 TransportMessage
    await _sendJson(message.payload);
  }

  Future<void> _sendJson(Map<String, dynamic> json) async {
    if (_webSocket == null) {
      _addLog('Cannot send: WebSocket is null');
      return;
    }
    final data = jsonEncode(json);
    _addLog('Sending: ${json['type']}');
    _webSocket!.add(data);
  }

  @override
  Future<void> broadcast(TransportMessage message) async {
    if (_state != TransportState.hosting) {
      SyncLog.w('Cannot broadcast: not hosting');
      return;
    }
    // 直接发送 payload 内容，而不是包装成 TransportMessage
    final json = message.payload;
    // 自检：确保消息有 type 字段
    final type = extractType(json);
    if (type == null) {
      SyncLog.e(
        '[Transport] broadcast: message has no type field!',
        error: 'protocol_mismatch',
      );
      assert(false, 'broadcast: message has no type field');
      return;
    }
    _broadcast(json);
  }

  @override
  Future<void> sendToPeer(String peerId, TransportMessage message) async {
    if (_state != TransportState.hosting) {
      SyncLog.w('Cannot sendToPeer: not hosting');
      return;
    }
    final json = message.payload;
    _sendToPeer(peerId, json);
    final type = extractType(json) ?? 'unknown';
    _addLog('Sent to $peerId: $type');
  }

  void _broadcast(Map<String, dynamic> json) {
    final data = jsonEncode(json);
    for (final socket in _connectedPeers.values) {
      socket.add(data);
    }
    final type = extractType(json) ?? 'unknown';
    _addLog('Broadcast: $type');
  }

  void _broadcastExcept(Map<String, dynamic> json, String exceptPeerId) {
    final data = jsonEncode(json);
    for (final entry in _connectedPeers.entries) {
      if (entry.key != exceptPeerId) {
        entry.value.add(data);
      }
    }
  }

  void _sendToPeer(String peerId, Map<String, dynamic> json) {
    final socket = _connectedPeers[peerId];
    if (socket != null) {
      socket.add(jsonEncode(json));
    }
  }

  // ==================== 心跳机制 ====================
  // 注意：心跳机制已移至 ClockSynchronizer 统一控制
  // WebSocketTransport 不再主动发送 ping，只响应 ping/pong

  void _startHeartbeat() {
    // 不再主动发送 ping，由 ClockSynchronizer 控制
    // 这里保留空实现以兼容现有代码
  }

  void _stopHeartbeat() {
    // 空实现
  }

  // ==================== 断开连接 ====================

  @override
  Future<void> disconnect() async {
    if (_state != TransportState.connected) return;

    _addLog('Disconnecting');
    SyncLog.i('Disconnecting', role: 'client');

    _stopHeartbeat();
    _reconnectTimer?.cancel();

    await _webSocket?.close();
    _webSocket = null;
    _sessionId = null;
    _reconnectHost = null;
    _reconnectPort = null;

    _updateState(TransportState.disconnected);
  }

  @override
  Future<void> stopServer() async {
    if (_state != TransportState.hosting) return;

    _addLog('Stopping server');
    SyncLog.i('Stopping server', role: 'host');

    _stopHeartbeat();

    // 关闭所有客户端连接
    for (final socket in _connectedPeers.values) {
      await socket.close();
    }
    _connectedPeers.clear();
    _peerSessionIds.clear();

    await _httpServer?.close();
    _httpServer = null;

    _updateState(TransportState.disconnected);
  }

  /// 手动触发重连（用于网络恢复后）
  Future<void> triggerReconnect() async {
    if (_reconnectHost != null && _reconnectPort != null) {
      _reconnectCount = 0; // 重置计数
      await connect(_reconnectHost!, _reconnectPort!);
    }
  }

  void dispose() {
    disconnect();
    stopServer();
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _stateController.close();
    _messageController.close();
  }
}
