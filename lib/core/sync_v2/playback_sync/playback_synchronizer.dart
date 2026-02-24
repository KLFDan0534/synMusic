import 'dart:async';

import '../diagnostics/sync_log.dart';
import '../diagnostics/sync_diagnostics.dart';
import '../clock/room_clock.dart';

/// 播放同步器
/// 负责保持 Client 与 Host 播放位置对齐
class PlaybackSynchronizer {
  final RoomClock _clock;
  final SyncDiagnostics _diagnostics = SyncDiagnostics();

  // 同步参数
  static const int _targetDeltaMs = 80; // 目标精度 80ms
  static const int _seekThresholdMs = 1000; // seek 阈值 1000ms
  static const double _minSpeed = 0.8;
  static const double _maxSpeed = 1.2;
  static const double _speedStep = 0.02;

  // 当前状态
  int _hostPosMs = 0;
  int _clientPosMs = 0;
  int _latencyCompMs =
      100; // 默认音频输出延迟补偿 100ms（Android AudioTrack buffer + 处理延迟）
  double _currentSpeed = 1.0;
  bool _seekPerformed = false;
  DateTime? _lastSeekAt;

  // 同步状态
  bool _isSyncing = false;
  Timer? _syncTimer;

  // 播放控制回调
  void Function(int positionMs)? _onSeek;
  void Function(double speed)? _onSpeedChange;
  int Function()? _onGetPosition;

  PlaybackSynchronizer({required RoomClock clock}) : _clock = clock;

  /// 当前 Host 位置
  int get hostPosMs => _hostPosMs;

  /// 当前 Client 位置
  int get clientPosMs => _clientPosMs;

  /// 延迟补偿值
  int get latencyCompMs => _latencyCompMs;

  /// 当前播放速度
  double get currentSpeed => _currentSpeed;

  /// 是否正在同步
  bool get isSyncing => _isSyncing;

  /// 设置播放控制回调
  void setCallbacks({
    void Function(int positionMs)? onSeek,
    void Function(double speed)? onSpeedChange,
    int Function()? onGetPosition,
  }) {
    _onSeek = onSeek;
    _onSpeedChange = onSpeedChange;
    _onGetPosition = onGetPosition;
  }

  /// 更新 Host 位置（从网络接收）
  void updateHostPosition(int hostPosMs, int hostTimestampMs) {
    // 计算传输延迟补偿
    final nowMs = _clock.roomNowMs;
    final transportDelay = nowMs - hostTimestampMs;

    // 补偿后的 Host 位置
    _hostPosMs = (hostPosMs + transportDelay).toInt();

    // 触发同步
    if (_isSyncing) {
      _performSync();
    }
  }

  /// 开始同步
  void startSync() {
    if (_isSyncing) return;

    _isSyncing = true;

    // 定期执行同步检查
    _syncTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _performSync();
    });

    SyncLog.i('Playback sync started', role: 'client');
    _diagnostics.updatePartial(state: 'syncing');
  }

  /// 停止同步
  void stopSync() {
    _isSyncing = false;
    _syncTimer?.cancel();
    _syncTimer = null;

    // 恢复正常速度
    _setSpeed(1.0);

    SyncLog.i('Playback sync stopped', role: 'client');
    _diagnostics.updatePartial(state: 'idle');
  }

  /// 执行同步
  void _performSync() {
    // 获取当前 Client 位置
    if (_onGetPosition != null) {
      _clientPosMs = _onGetPosition!();
    }

    // 计算偏差（包含延迟补偿）
    final deltaMs = _hostPosMs - _clientPosMs - _latencyCompMs;

    // 更新诊断数据
    _diagnostics.updatePartial(
      hostPosMs: _hostPosMs,
      clientPosMs: _clientPosMs,
      latencyCompMs: _latencyCompMs,
      deltaMs: deltaMs,
      speedSet: _currentSpeed,
    );

    // 记录同步快照
    SyncLog.syncSnapshot(
      role: 'client',
      roomId: 'current',
      epoch: _clock.epoch,
      seq: _clock.seq,
      rttMs: _diagnostics.data.rttMs,
      offsetMs: _clock.offsetEmaMs,
      jitterMs: _diagnostics.data.jitterMs,
      hostPosMs: _hostPosMs,
      clientPosMs: _clientPosMs,
      latencyCompMs: _latencyCompMs,
      deltaMs: deltaMs,
      speedSet: _currentSpeed,
      seekPerformed: _seekPerformed,
    );

    // 判断是否需要 seek
    if (deltaMs.abs() > _seekThresholdMs) {
      _performSeek(deltaMs);
      return;
    }

    // 使用倍速修复小偏差
    _adjustSpeed(deltaMs);
  }

  /// 执行 seek
  void _performSeek(int deltaMs) {
    if (_onSeek == null) return;

    final targetPos = _hostPosMs - _latencyCompMs;
    _onSeek!(targetPos);

    _seekPerformed = true;
    _lastSeekAt = DateTime.now();

    SyncLog.i(
      'Seek performed: deltaMs=$deltaMs (delta > ${_seekThresholdMs}ms)',
      role: 'client',
    );

    _diagnostics.updatePartial(seekPerformed: true, lastSeekAt: _lastSeekAt);

    // 重置速度
    _setSpeed(1.0);
  }

  /// 调整播放速度
  void _adjustSpeed(int deltaMs) {
    // 在目标精度内，不需要调整
    if (deltaMs.abs() <= _targetDeltaMs) {
      if (_currentSpeed != 1.0) {
        _setSpeed(1.0);
      }
      return;
    }

    // 计算目标速度
    double targetSpeed;
    if (deltaMs > 0) {
      // Client 落后，加速追赶
      targetSpeed = 1.0 + (deltaMs / 500.0).clamp(0.0, 0.2);
    } else {
      // Client 超前，减速等待
      targetSpeed = 1.0 - (deltaMs.abs() / 500.0).clamp(0.0, 0.2);
    }

    // 限制速度范围
    targetSpeed = targetSpeed.clamp(_minSpeed, _maxSpeed);

    // 渐进调整（避免突变）
    if ((targetSpeed - _currentSpeed).abs() > _speedStep) {
      if (targetSpeed > _currentSpeed) {
        _setSpeed(_currentSpeed + _speedStep);
      } else {
        _setSpeed(_currentSpeed - _speedStep);
      }
    } else {
      _setSpeed(targetSpeed);
    }

    _seekPerformed = false;
  }

  /// 设置播放速度
  void _setSpeed(double speed) {
    if (_currentSpeed == speed) return;

    _currentSpeed = speed;
    _onSpeedChange?.call(speed);

    SyncLog.d('Speed adjusted: $speed', role: 'client');

    _diagnostics.updatePartial(speedSet: speed);
  }

  /// 手动校准延迟
  void calibrateLatency(int latencyMs) {
    _latencyCompMs = latencyMs;
    SyncLog.i('Latency calibrated: ${latencyMs}ms', role: 'client');
    _diagnostics.updatePartial(latencyCompMs: latencyMs);
  }

  /// 释放资源
  void dispose() {
    stopSync();
  }
}

// 使用 Dart 内置的 clamp 方法
