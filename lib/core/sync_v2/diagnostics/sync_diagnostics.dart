import 'dart:async';

/// 同步诊断数据模型
class SyncDiagnosticsData {
  // 角色信息
  final String role; // 'host' | 'client' | 'none'
  final String? roomId;
  final String? peerId;

  // 连接状态
  final String
  connectionState; // 'disconnected' | 'connecting' | 'connected' | 'hosting' | 'error'
  final int lastPingRtt;
  final int reconnectCount;
  final int peerCount;

  // 时钟同步
  final int roomNowMs;
  final int rttMs;
  final int offsetEmaMs; // EMA 平滑后的偏移
  final int jitterMs;

  // 样本过滤统计
  final int droppedSamplesCount; // 丢弃样本计数
  final String? lastDroppedReason; // 最近丢弃原因
  final int lastGoodRttMs; // 最近合格样本的 RTT

  // 播放位置
  final int hostPosMs;
  final int clientPosMs;
  final int latencyCompMs;

  // 同步控制
  final int deltaMs;
  final double speedSet;
  final bool seekPerformed;
  final DateTime? lastSeekAt;

  // 状态机
  final String
  state; // 'idle' | 'discovering' | 'joining' | 'syncing' | 'playing' | 'error'
  final String? errorMessage;

  // FutureStart 同起开播
  final String
  futureStartState; // 'idle' | 'preparing' | 'waiting' | 'started' | 'failed'
  final int startAtRoomTimeMs;
  final int actualStartRoomTimeMs;
  final int startErrorMs;
  final int leadMs;

  // Catch-up 追帧
  final int lastHostStateAtRoomTimeMs;
  final int lastHostPosMs;
  final int computedTargetPosMs;
  final bool catchUpPerformed;
  final int catchUpDeltaMs;

  // KeepSync 持续同步
  final bool keepSyncEnabled;
  final int keepSyncDeltaMs;
  final int keepSyncPredictedDeltaMs; // 预测偏差
  final int keepSyncTargetPosMs;
  final int keepSyncClientPosMs;
  final double keepSyncSpeed;
  final double keepSyncSpeedEma;
  final double keepSyncSpeedCmd; // 限幅后的速度命令
  final int keepSyncHoldRemainingMs; // hold 剩余时间
  final String keepSyncLastAction; // 'noop' | 'speed' | 'seek'
  final int keepSyncSeekCount;
  final int keepSyncSpeedSetCount;
  final int keepSyncDroppedCount;
  final String? keepSyncDroppedReason;
  final String? keepSyncReason; // 决策原因

  // 时间戳
  final DateTime updatedAt;

  const SyncDiagnosticsData({
    this.role = 'none',
    this.roomId,
    this.peerId,
    this.connectionState = 'disconnected',
    this.lastPingRtt = 0,
    this.reconnectCount = 0,
    this.peerCount = 0,
    this.roomNowMs = 0,
    this.rttMs = 0,
    this.offsetEmaMs = 0,
    this.jitterMs = 0,
    this.droppedSamplesCount = 0,
    this.lastDroppedReason,
    this.lastGoodRttMs = 0,
    this.hostPosMs = 0,
    this.clientPosMs = 0,
    this.latencyCompMs = 0,
    this.deltaMs = 0,
    this.speedSet = 1.0,
    this.seekPerformed = false,
    this.lastSeekAt,
    this.state = 'idle',
    this.errorMessage,
    this.futureStartState = 'idle',
    this.startAtRoomTimeMs = 0,
    this.actualStartRoomTimeMs = 0,
    this.startErrorMs = 0,
    this.leadMs = 1500,
    this.lastHostStateAtRoomTimeMs = 0,
    this.lastHostPosMs = 0,
    this.computedTargetPosMs = 0,
    this.catchUpPerformed = false,
    this.catchUpDeltaMs = 0,
    this.keepSyncEnabled = false,
    this.keepSyncDeltaMs = 0,
    this.keepSyncPredictedDeltaMs = 0,
    this.keepSyncTargetPosMs = 0,
    this.keepSyncClientPosMs = 0,
    this.keepSyncSpeed = 1.0,
    this.keepSyncSpeedEma = 1.0,
    this.keepSyncSpeedCmd = 1.0,
    this.keepSyncHoldRemainingMs = 0,
    this.keepSyncLastAction = 'noop',
    this.keepSyncSeekCount = 0,
    this.keepSyncSpeedSetCount = 0,
    this.keepSyncDroppedCount = 0,
    this.keepSyncDroppedReason,
    this.keepSyncReason,
    required this.updatedAt,
  });

  /// 创建副本
  SyncDiagnosticsData copyWith({
    String? role,
    String? roomId,
    String? peerId,
    String? connectionState,
    int? lastPingRtt,
    int? reconnectCount,
    int? peerCount,
    int? roomNowMs,
    int? rttMs,
    int? offsetEmaMs,
    int? jitterMs,
    int? droppedSamplesCount,
    String? lastDroppedReason,
    int? lastGoodRttMs,
    int? hostPosMs,
    int? clientPosMs,
    int? latencyCompMs,
    int? deltaMs,
    double? speedSet,
    bool? seekPerformed,
    DateTime? lastSeekAt,
    String? state,
    String? errorMessage,
    String? futureStartState,
    int? startAtRoomTimeMs,
    int? actualStartRoomTimeMs,
    int? startErrorMs,
    int? leadMs,
    int? lastHostStateAtRoomTimeMs,
    int? lastHostPosMs,
    int? computedTargetPosMs,
    bool? catchUpPerformed,
    int? catchUpDeltaMs,
    bool? keepSyncEnabled,
    int? keepSyncDeltaMs,
    int? keepSyncPredictedDeltaMs,
    int? keepSyncTargetPosMs,
    int? keepSyncClientPosMs,
    double? keepSyncSpeed,
    double? keepSyncSpeedEma,
    double? keepSyncSpeedCmd,
    int? keepSyncHoldRemainingMs,
    String? keepSyncLastAction,
    int? keepSyncSeekCount,
    int? keepSyncSpeedSetCount,
    int? keepSyncDroppedCount,
    String? keepSyncDroppedReason,
    String? keepSyncReason,
    DateTime? updatedAt,
  }) {
    return SyncDiagnosticsData(
      role: role ?? this.role,
      roomId: roomId ?? this.roomId,
      peerId: peerId ?? this.peerId,
      connectionState: connectionState ?? this.connectionState,
      lastPingRtt: lastPingRtt ?? this.lastPingRtt,
      reconnectCount: reconnectCount ?? this.reconnectCount,
      peerCount: peerCount ?? this.peerCount,
      roomNowMs: roomNowMs ?? this.roomNowMs,
      rttMs: rttMs ?? this.rttMs,
      offsetEmaMs: offsetEmaMs ?? this.offsetEmaMs,
      jitterMs: jitterMs ?? this.jitterMs,
      droppedSamplesCount: droppedSamplesCount ?? this.droppedSamplesCount,
      lastDroppedReason: lastDroppedReason ?? this.lastDroppedReason,
      lastGoodRttMs: lastGoodRttMs ?? this.lastGoodRttMs,
      hostPosMs: hostPosMs ?? this.hostPosMs,
      clientPosMs: clientPosMs ?? this.clientPosMs,
      latencyCompMs: latencyCompMs ?? this.latencyCompMs,
      deltaMs: deltaMs ?? this.deltaMs,
      speedSet: speedSet ?? this.speedSet,
      seekPerformed: seekPerformed ?? this.seekPerformed,
      lastSeekAt: lastSeekAt ?? this.lastSeekAt,
      state: state ?? this.state,
      errorMessage: errorMessage ?? this.errorMessage,
      futureStartState: futureStartState ?? this.futureStartState,
      startAtRoomTimeMs: startAtRoomTimeMs ?? this.startAtRoomTimeMs,
      actualStartRoomTimeMs:
          actualStartRoomTimeMs ?? this.actualStartRoomTimeMs,
      startErrorMs: startErrorMs ?? this.startErrorMs,
      leadMs: leadMs ?? this.leadMs,
      lastHostStateAtRoomTimeMs:
          lastHostStateAtRoomTimeMs ?? this.lastHostStateAtRoomTimeMs,
      lastHostPosMs: lastHostPosMs ?? this.lastHostPosMs,
      computedTargetPosMs: computedTargetPosMs ?? this.computedTargetPosMs,
      catchUpPerformed: catchUpPerformed ?? this.catchUpPerformed,
      catchUpDeltaMs: catchUpDeltaMs ?? this.catchUpDeltaMs,
      keepSyncEnabled: keepSyncEnabled ?? this.keepSyncEnabled,
      keepSyncDeltaMs: keepSyncDeltaMs ?? this.keepSyncDeltaMs,
      keepSyncPredictedDeltaMs:
          keepSyncPredictedDeltaMs ?? this.keepSyncPredictedDeltaMs,
      keepSyncTargetPosMs: keepSyncTargetPosMs ?? this.keepSyncTargetPosMs,
      keepSyncClientPosMs: keepSyncClientPosMs ?? this.keepSyncClientPosMs,
      keepSyncSpeed: keepSyncSpeed ?? this.keepSyncSpeed,
      keepSyncSpeedEma: keepSyncSpeedEma ?? this.keepSyncSpeedEma,
      keepSyncSpeedCmd: keepSyncSpeedCmd ?? this.keepSyncSpeedCmd,
      keepSyncHoldRemainingMs:
          keepSyncHoldRemainingMs ?? this.keepSyncHoldRemainingMs,
      keepSyncLastAction: keepSyncLastAction ?? this.keepSyncLastAction,
      keepSyncSeekCount: keepSyncSeekCount ?? this.keepSyncSeekCount,
      keepSyncSpeedSetCount:
          keepSyncSpeedSetCount ?? this.keepSyncSpeedSetCount,
      keepSyncDroppedCount: keepSyncDroppedCount ?? this.keepSyncDroppedCount,
      keepSyncDroppedReason:
          keepSyncDroppedReason ?? this.keepSyncDroppedReason,
      keepSyncReason: keepSyncReason ?? this.keepSyncReason,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 格式化为可读字符串
  String toFormattedString() {
    final lines = <String>[
      '=== Sync Diagnostics ===',
      'Time: ${updatedAt.toIso8601String()}',
      'State: $state',
      'Role: $role',
      if (roomId != null) 'Room: $roomId',
      if (peerId != null) 'Peer: $peerId',
      '',
      '-- Connection --',
      'connectionState: $connectionState',
      'lastPingRtt: ${lastPingRtt}ms',
      'reconnectCount: $reconnectCount',
      'peerCount: $peerCount',
      '',
      '-- Clock Sync --',
      'roomNowMs: $roomNowMs',
      'rttMs: $rttMs',
      'offsetEmaMs: $offsetEmaMs',
      'jitterMs: $jitterMs',
      '',
      '-- Playback --',
      'hostPosMs: $hostPosMs',
      'clientPosMs: $clientPosMs',
      'latencyCompMs: $latencyCompMs',
      '',
      '-- Sync Control --',
      'deltaMs: $deltaMs',
      'speedSet: $speedSet',
      'seekPerformed: $seekPerformed',
      if (lastSeekAt != null) 'lastSeekAt: ${lastSeekAt!.toIso8601String()}',
      if (errorMessage != null) 'Error: $errorMessage',
    ];
    return lines.join('\n');
  }
}

/// 同步诊断管理器
/// 收集并暴露同步系统的诊断数据
class SyncDiagnostics {
  static final SyncDiagnostics _instance = SyncDiagnostics._internal();
  factory SyncDiagnostics() => _instance;
  SyncDiagnostics._internal();

  // 当前诊断数据
  SyncDiagnosticsData _data = SyncDiagnosticsData(updatedAt: DateTime.now());

  // 数据流控制器
  final _controller = StreamController<SyncDiagnosticsData>.broadcast();

  /// 诊断数据流（供 UI 订阅）
  Stream<SyncDiagnosticsData> get stream => _controller.stream;

  /// 当前诊断数据
  SyncDiagnosticsData get data => _data;

  /// 更新诊断数据
  void update(SyncDiagnosticsData newData) {
    _data = newData;
    _controller.add(_data);
  }

  /// 更新部分字段
  void updatePartial({
    String? role,
    String? roomId,
    String? peerId,
    String? connectionState,
    int? lastPingRtt,
    int? reconnectCount,
    int? peerCount,
    int? roomNowMs,
    int? rttMs,
    int? offsetEmaMs,
    int? jitterMs,
    int? droppedSamplesCount,
    String? lastDroppedReason,
    int? lastGoodRttMs,
    int? hostPosMs,
    int? clientPosMs,
    int? latencyCompMs,
    int? deltaMs,
    double? speedSet,
    bool? seekPerformed,
    DateTime? lastSeekAt,
    String? state,
    String? errorMessage,
    String? futureStartState,
    int? startAtRoomTimeMs,
    int? actualStartRoomTimeMs,
    int? startErrorMs,
    int? leadMs,
    int? lastHostStateAtRoomTimeMs,
    int? lastHostPosMs,
    int? computedTargetPosMs,
    bool? catchUpPerformed,
    int? catchUpDeltaMs,
    bool? keepSyncEnabled,
    int? keepSyncDeltaMs,
    int? keepSyncPredictedDeltaMs,
    int? keepSyncTargetPosMs,
    int? keepSyncClientPosMs,
    double? keepSyncSpeed,
    double? keepSyncSpeedEma,
    double? keepSyncSpeedCmd,
    int? keepSyncHoldRemainingMs,
    String? keepSyncLastAction,
    int? keepSyncSeekCount,
    int? keepSyncSpeedSetCount,
    int? keepSyncDroppedCount,
    String? keepSyncDroppedReason,
    String? keepSyncReason,
  }) {
    _data = _data.copyWith(
      role: role,
      roomId: roomId,
      peerId: peerId,
      connectionState: connectionState,
      lastPingRtt: lastPingRtt,
      reconnectCount: reconnectCount,
      peerCount: peerCount,
      roomNowMs: roomNowMs,
      rttMs: rttMs,
      offsetEmaMs: offsetEmaMs,
      jitterMs: jitterMs,
      droppedSamplesCount: droppedSamplesCount,
      lastDroppedReason: lastDroppedReason,
      lastGoodRttMs: lastGoodRttMs,
      hostPosMs: hostPosMs,
      clientPosMs: clientPosMs,
      latencyCompMs: latencyCompMs,
      deltaMs: deltaMs,
      speedSet: speedSet,
      seekPerformed: seekPerformed,
      lastSeekAt: lastSeekAt,
      state: state,
      errorMessage: errorMessage,
      futureStartState: futureStartState,
      startAtRoomTimeMs: startAtRoomTimeMs,
      actualStartRoomTimeMs: actualStartRoomTimeMs,
      startErrorMs: startErrorMs,
      leadMs: leadMs,
      lastHostStateAtRoomTimeMs: lastHostStateAtRoomTimeMs,
      lastHostPosMs: lastHostPosMs,
      computedTargetPosMs: computedTargetPosMs,
      catchUpPerformed: catchUpPerformed,
      catchUpDeltaMs: catchUpDeltaMs,
      keepSyncEnabled: keepSyncEnabled,
      keepSyncDeltaMs: keepSyncDeltaMs,
      keepSyncPredictedDeltaMs: keepSyncPredictedDeltaMs,
      keepSyncTargetPosMs: keepSyncTargetPosMs,
      keepSyncClientPosMs: keepSyncClientPosMs,
      keepSyncSpeed: keepSyncSpeed,
      keepSyncSpeedEma: keepSyncSpeedEma,
      keepSyncSpeedCmd: keepSyncSpeedCmd,
      keepSyncHoldRemainingMs: keepSyncHoldRemainingMs,
      keepSyncLastAction: keepSyncLastAction,
      keepSyncSeekCount: keepSyncSeekCount,
      keepSyncSpeedSetCount: keepSyncSpeedSetCount,
      keepSyncDroppedCount: keepSyncDroppedCount,
      keepSyncDroppedReason: keepSyncDroppedReason,
      keepSyncReason: keepSyncReason,
      updatedAt: DateTime.now(),
    );
    _controller.add(_data);
  }

  /// 重置诊断数据
  void reset() {
    _data = SyncDiagnosticsData(updatedAt: DateTime.now());
    _controller.add(_data);
  }

  /// 释放资源
  void dispose() {
    _controller.close();
  }
}
