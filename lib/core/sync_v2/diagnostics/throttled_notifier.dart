import 'dart:async';
import 'package:flutter/foundation.dart';

import 'sync_diagnostics.dart';

/// 节流诊断数据通知器
/// 内部状态可高频更新，但 UI 通知最多每 250ms 一次
class ThrottledDiagnosticsNotifier extends ChangeNotifier {
  // 内部缓冲状态（高频更新）
  SyncDiagnosticsData _bufferedData = SyncDiagnosticsData(
    updatedAt: DateTime.now(),
  );

  // 上次发布给 UI 的状态
  SyncDiagnosticsData _publishedData = SyncDiagnosticsData(
    updatedAt: DateTime.now(),
  );

  // 节流定时器
  Timer? _throttleTimer;

  // 节流间隔（毫秒）
  final int throttleIntervalMs;

  // 是否有待发布的更新
  bool _hasPendingUpdate = false;

  ThrottledDiagnosticsNotifier({this.throttleIntervalMs = 250});

  /// 获取当前发布的数据（UI 使用）
  SyncDiagnosticsData get data => _publishedData;

  /// 获取缓冲数据（内部使用）
  SyncDiagnosticsData get bufferedData => _bufferedData;

  /// 高频更新内部状态（不立即通知 UI）
  void updateBuffer(SyncDiagnosticsData newData) {
    _bufferedData = newData;
    _hasPendingUpdate = true;

    // 如果定时器未启动，启动节流定时器
    _startThrottleTimerIfNeeded();
  }

  /// 高频更新部分字段
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
  }) {
    _bufferedData = _bufferedData.copyWith(
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
      updatedAt: DateTime.now(),
    );
    _hasPendingUpdate = true;
    _startThrottleTimerIfNeeded();
  }

  /// 立即发布（用于重要状态变化，如连接断开）
  void publishNow() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _publishToUi();
  }

  /// 重置数据
  void reset() {
    _bufferedData = SyncDiagnosticsData(updatedAt: DateTime.now());
    _hasPendingUpdate = true;
    publishNow();
  }

  void _startThrottleTimerIfNeeded() {
    if (_throttleTimer != null) return;

    _throttleTimer = Timer(
      Duration(milliseconds: throttleIntervalMs),
      _onThrottleTick,
    );
  }

  void _onThrottleTick() {
    _throttleTimer = null;

    if (_hasPendingUpdate) {
      _publishToUi();
    }
  }

  void _publishToUi() {
    _publishedData = _bufferedData;
    _hasPendingUpdate = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    super.dispose();
  }
}

/// Transport 日志节流管理器
/// 日志写入可高频，但 UI 展示只在节流 tick 时刷新
class ThrottledLogNotifier extends ChangeNotifier {
  // 内部日志列表（最多 200 条）
  final List<String> _logs = [];
  static const int _maxLogs = 200;

  // 发布给 UI 的日志列表（最多 50 条）
  List<String> _publishedLogs = [];
  static const int _maxPublishedLogs = 50;

  // 节流定时器
  Timer? _throttleTimer;

  // 是否有待发布的更新
  bool _hasPendingUpdate = false;

  // 节流间隔（毫秒）
  final int throttleIntervalMs;

  ThrottledLogNotifier({this.throttleIntervalMs = 500});

  /// 获取发布的日志（UI 使用）
  List<String> get logs => List.unmodifiable(_publishedLogs);

  /// 添加日志（高频调用）
  void addLog(String log) {
    _logs.add(log);

    // 超出最大数量时移除旧日志
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    _hasPendingUpdate = true;
    _startThrottleTimerIfNeeded();
  }

  /// 清空日志
  void clear() {
    _logs.clear();
    _hasPendingUpdate = true;
    _publishNow();
  }

  void _startThrottleTimerIfNeeded() {
    if (_throttleTimer != null) return;

    _throttleTimer = Timer(
      Duration(milliseconds: throttleIntervalMs),
      _onThrottleTick,
    );
  }

  void _onThrottleTick() {
    _throttleTimer = null;

    if (_hasPendingUpdate) {
      _publishToUi();
    }
  }

  void _publishNow() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _publishToUi();
  }

  void _publishToUi() {
    // 只取最近 50 条给 UI
    final start = _logs.length > _maxPublishedLogs
        ? _logs.length - _maxPublishedLogs
        : 0;
    _publishedLogs = _logs.sublist(start);
    _hasPendingUpdate = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    super.dispose();
  }
}
