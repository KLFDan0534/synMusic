import 'dart:async';

import 'package:flutter/services.dart';

import '../diagnostics/sync_log.dart';
import 'discovered_room.dart';

/// mDNS/Bonjour 服务类型
const String kSyncMusicServiceType = '_syncmusic._tcp';

/// mDNS 服务管理器
/// 通过 MethodChannel 调用原生 mDNS/Bonjour 实现
class MdnsService {
  static final MdnsService _instance = MdnsService._internal();
  factory MdnsService() => _instance;
  MdnsService._internal();

  // MethodChannel
  static const MethodChannel _channel = MethodChannel('com.syncmusic/mdns');

  // 发现的房间列表
  final Map<String, DiscoveredRoom> _discoveredRooms = {};

  // 流控制器
  final _roomsController = StreamController<List<DiscoveredRoom>>.broadcast();

  // 扫描状态
  bool _isScanning = false;
  bool _isPublished = false;

  // 是否已初始化监听
  bool _listenersInitialized = false;

  // Debounce 相关
  Timer? _debounceTimer;
  static const Duration _debounceDuration = Duration(milliseconds: 300);
  bool _hasPendingUpdate = false;

  /// 发现的房间列表流
  Stream<List<DiscoveredRoom>> get roomsStream => _roomsController.stream;

  /// 当前发现的房间列表
  List<DiscoveredRoom> get rooms => _discoveredRooms.values.toList();

  /// 是否正在扫描
  bool get isScanning => _isScanning;

  /// 是否已发布
  bool get isPublished => _isPublished;

  /// 初始化 MethodChannel 监听
  void _ensureListenersInitialized() {
    if (_listenersInitialized) return;
    _listenersInitialized = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRoomDiscovered':
          _handleRoomDiscovered(call.arguments as Map<dynamic, dynamic>);
          break;
        case 'onRoomLost':
          _handleRoomLost(call.arguments as Map<dynamic, dynamic>);
          break;
        case 'onRoomsCleared':
          _handleRoomsCleared();
          break;
        case 'onPublishError':
          _handlePublishError(call.arguments as Map<dynamic, dynamic>);
          break;
        case 'onScanError':
          _handleScanError(call.arguments as Map<dynamic, dynamic>);
          break;
      }
      return null;
    });
  }

  /// 处理发现房间回调
  void _handleRoomDiscovered(Map<dynamic, dynamic> data) {
    final room = DiscoveredRoom(
      roomId: data['roomId'] as String? ?? '',
      roomName: data['roomName'] as String? ?? 'Unknown',
      hostIp: data['hostIp'] as String? ?? '',
      hostWsPort: data['hostWsPort'] as int? ?? 8765,
      hostHttpPort: data['hostHttpPort'] as int? ?? 8080,
      appVersion: data['appVersion'] as String? ?? '1.0.0',
      codec: data['codec'] as String? ?? 'mp3',
      discoveredAt: DateTime.now(),
    );

    final existing = _discoveredRooms[room.roomId];
    if (existing != null) {
      // 检查是否是重复解析（IP/端口不变则忽略）
      if (existing.hostIp == room.hostIp &&
          existing.hostWsPort == room.hostWsPort) {
        // 只更新 lastSeen，不触发 UI 刷新
        _discoveredRooms[room.roomId] = room.withLastSeen();
        return;
      }
      _discoveredRooms[room.roomId] = room.withLastSeen();
    } else {
      _discoveredRooms[room.roomId] = room;
      SyncLog.i(
        'Discovered new room: ${room.toLogString()}',
        role: 'client',
        roomId: room.roomId,
      );
    }

    // 使用 debounce 延迟发布
    _scheduleDebouncedUpdate();
  }

  /// 调度 debounce 更新
  void _scheduleDebouncedUpdate() {
    _hasPendingUpdate = true;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, _publishDebouncedUpdate);
  }

  /// 发布 debounce 后的更新
  void _publishDebouncedUpdate() {
    if (_hasPendingUpdate) {
      _roomsController.add(rooms);
      _hasPendingUpdate = false;
    }
  }

  /// 处理房间丢失回调
  void _handleRoomLost(Map<dynamic, dynamic> data) {
    final roomId = data['roomId'] as String?;
    if (roomId != null && _discoveredRooms.remove(roomId) != null) {
      SyncLog.i('Room disappeared: $roomId', role: 'client', roomId: roomId);
      _roomsController.add(rooms);
    }
  }

  /// 处理房间清空回调
  void _handleRoomsCleared() {
    _discoveredRooms.clear();
    _roomsController.add(rooms);
  }

  /// 处理发布错误回调
  void _handlePublishError(Map<dynamic, dynamic> data) {
    final error = data['error'] as String? ?? 'Unknown error';
    SyncLog.e('Failed to publish room: $error', role: 'host');
    _isPublished = false;
  }

  /// 处理扫描错误回调
  void _handleScanError(Map<dynamic, dynamic> data) {
    final error = data['error'] as String? ?? 'Unknown error';
    SyncLog.e('Failed to scan: $error', role: 'client');
    _isScanning = false;
  }

  /// 开始扫描房间
  Future<void> startScanning({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_isScanning) {
      SyncLog.w('Already scanning, ignoring start request', role: 'client');
      return;
    }

    _ensureListenersInitialized();
    _isScanning = true;
    _discoveredRooms.clear();

    SyncLog.i('Starting mDNS scanning', role: 'client');

    try {
      await _channel.invokeMethod('startScanning');

      // 超时后自动停止
      Future.delayed(timeout, () {
        if (_isScanning) {
          stopScanning();
        }
      });
    } catch (e, s) {
      SyncLog.e(
        'Failed to start scanning',
        role: 'client',
        error: e,
        stackTrace: s,
      );
      _isScanning = false;
    }
  }

  /// 停止扫描
  Future<void> stopScanning() async {
    if (!_isScanning) return;

    _isScanning = false;

    SyncLog.i('Stopped mDNS scanning', role: 'client');

    try {
      await _channel.invokeMethod('stopScanning');
    } catch (e, s) {
      SyncLog.e(
        'Failed to stop scanning',
        role: 'client',
        error: e,
        stackTrace: s,
      );
    }
  }

  /// 发布房间服务（Host 调用）
  Future<bool> publishRoom({
    required String roomId,
    required String roomName,
    required int wsPort,
    required int httpPort,
    required String appVersion,
    String codec = 'mp3',
  }) async {
    _ensureListenersInitialized();

    SyncLog.i('Publishing room via mDNS', role: 'host', roomId: roomId);

    try {
      final result = await _channel.invokeMethod('publishRoom', {
        'roomId': roomId,
        'roomName': roomName,
        'wsPort': wsPort,
        'httpPort': httpPort,
        'appVersion': appVersion,
        'codec': codec,
      });

      _isPublished = result == true;
      if (_isPublished) {
        SyncLog.i('Room published successfully', role: 'host', roomId: roomId);
      }
      return _isPublished;
    } catch (e, s) {
      SyncLog.e(
        'Failed to publish room',
        role: 'host',
        error: e,
        stackTrace: s,
      );
      _isPublished = false;
      return false;
    }
  }

  /// 取消发布房间服务
  Future<void> unpublishRoom() async {
    if (!_isPublished) return;

    SyncLog.i('Unpublishing room', role: 'host');

    try {
      await _channel.invokeMethod('unpublishRoom');
      _isPublished = false;
    } catch (e, s) {
      SyncLog.e(
        'Failed to unpublish room',
        role: 'host',
        error: e,
        stackTrace: s,
      );
    }
  }

  /// 清空所有发现的房间
  void clearRooms() {
    _discoveredRooms.clear();
    _roomsController.add(rooms);
  }

  /// 释放资源
  void dispose() {
    stopScanning();
    unpublishRoom();
    _roomsController.close();
  }
}
