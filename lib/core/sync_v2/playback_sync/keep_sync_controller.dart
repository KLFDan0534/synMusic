import '../diagnostics/sync_log.dart';

/// KeepSync 同步动作类型
enum KeepSyncAction {
  noop, // 无操作
  speed, // 调整播放速度
  seek, // 跳转位置
}

/// KeepSync 同步决策结果
class KeepSyncDecision {
  final KeepSyncAction action;
  final double? speed; // action=speed 时有效
  final int? seekMs; // action=seek 时有效
  final int deltaMs; // 当前偏差
  final int predictedDeltaMs; // 预测偏差
  final int targetPosMs; // 目标位置
  final int clientPosMs; // 客户端当前位置
  final double speedCmd; // 限幅后的速度命令
  final int holdRemainingMs; // hold 剩余时间
  final String? reason; // 决策原因

  const KeepSyncDecision({
    required this.action,
    this.speed,
    this.seekMs,
    required this.deltaMs,
    required this.predictedDeltaMs,
    required this.targetPosMs,
    required this.clientPosMs,
    this.speedCmd = 1.0,
    this.holdRemainingMs = 0,
    this.reason,
  });
}

/// KeepSync 配置参数
class KeepSyncConfig {
  // 死区范围（|delta| <= 此值不调整）
  final int deadbandMs;

  // seek 阈值（|delta| > 此值执行 seek）
  final int seekThresholdMs;

  // 速度调整系数（delta * k = speedDelta）
  final double speedK;

  // 速度范围 [min, max]
  final double speedMin;
  final double speedMax;

  // 速度 EMA alpha
  final double speedAlpha;

  // 速度设置最小间隔
  final int speedIntervalMs;

  // seek 冷却时间
  final int seekCooldownMs;

  // seek 后速度冷却时间
  final int speedCooldownAfterSeekMs;

  // host_state 过期阈值
  final int hostStateStaleMs;

  // 预测时间窗口（默认 500ms，host_state 间隔）
  final int predictionWindowMs;

  // 每次速度变化最大步长
  final double maxSpeedStepPerUpdate;

  // 反转 guard 触发阈值
  final int reverseGuardThresholdMs;

  // 反转 guard hold 时间
  final int reverseGuardHoldMs;

  // 高 jitter 阈值
  final int highJitterThresholdMs;

  // 高 RTT 阈值
  final int highRttThresholdMs;

  // 高 jitter/RTT 时的 alpha 降权比例
  final double jitterAlphaRatio;

  const KeepSyncConfig({
    this.deadbandMs = 30,
    this.seekThresholdMs = 1000,
    this.speedK = 0.0002, // 降低响应速度
    this.speedMin = 0.96,
    this.speedMax = 1.04,
    this.speedAlpha = 0.2,
    this.speedIntervalMs = 400,
    this.seekCooldownMs = 1500,
    this.speedCooldownAfterSeekMs = 500,
    this.hostStateStaleMs = 1200,
    this.predictionWindowMs = 500,
    this.maxSpeedStepPerUpdate = 0.005, // 每次最多变 0.5%
    this.reverseGuardThresholdMs = 120,
    this.reverseGuardHoldMs = 800,
    this.highJitterThresholdMs = 40,
    this.highRttThresholdMs = 120,
    this.jitterAlphaRatio = 0.5,
  });

  /// iOS 安全模式配置（更保守）
  static const KeepSyncConfig iosSafe = KeepSyncConfig(
    deadbandMs: 40,
    seekThresholdMs: 1000,
    speedK: 0.00015,
    speedMin: 0.98,
    speedMax: 1.02,
    speedAlpha: 0.12,
    speedIntervalMs: 800,
    seekCooldownMs: 2000,
    speedCooldownAfterSeekMs: 500,
    hostStateStaleMs: 1200,
    predictionWindowMs: 500,
    maxSpeedStepPerUpdate: 0.003, // iOS 每次最多变 0.3%
    reverseGuardThresholdMs: 120,
    reverseGuardHoldMs: 1000,
    highJitterThresholdMs: 30,
    highRttThresholdMs: 100,
    jitterAlphaRatio: 0.3,
  );
}

/// KeepSync 持续同步控制器
/// 负责播放过程中的持续同步决策
class KeepSyncController {
  KeepSyncConfig _config;

  // 当前状态
  double _currentSpeed = 1.0;
  double _speedEma = 1.0;
  int _lastSpeedSetAtMs = 0;
  int _lastSeekAtMs = 0;

  // epoch/trackId 追踪
  int? _activeEpoch;
  String? _activeTrackId;

  // 统计
  int _seekCount = 0;
  int _speedSetCount = 0;
  int _droppedHostStateCount = 0;
  String? _lastDroppedReason;

  // 是否启用（默认开启）
  bool _enabled = true;

  // 反转 guard 状态
  int _lastDeltaSign = 0; // -1, 0, 1
  int _holdUntilMs = 0; // hold 结束时间

  KeepSyncController({KeepSyncConfig? config})
    : _config = config ?? const KeepSyncConfig();

  /// 当前配置
  KeepSyncConfig get config => _config;

  /// 更新配置
  void updateConfig(KeepSyncConfig config) {
    _config = config;
  }

  /// 是否启用
  bool get enabled => _enabled;

  /// 设置启用状态
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      reset();
    }
  }

  /// 当前速度
  double get currentSpeed => _currentSpeed;

  /// 速度 EMA
  double get speedEma => _speedEma;

  /// seek 次数
  int get seekCount => _seekCount;

  /// 速度调整次数
  int get speedSetCount => _speedSetCount;

  /// 丢弃的 host_state 数量
  int get droppedHostStateCount => _droppedHostStateCount;

  /// 最后丢弃原因
  String? get lastDroppedReason => _lastDroppedReason;

  /// 重置状态（换歌/epoch 变化时调用）
  void reset() {
    _currentSpeed = 1.0;
    _speedEma = 1.0;
    _lastSpeedSetAtMs = 0;
    _lastSeekAtMs = 0;
    _activeEpoch = null;
    _activeTrackId = null;
    _seekCount = 0;
    _speedSetCount = 0;
    _droppedHostStateCount = 0;
    _lastDroppedReason = null;
    _lastDeltaSign = 0;
    _holdUntilMs = 0;
  }

  /// 执行同步决策
  KeepSyncDecision decide({
    required bool isPlaying,
    required int epoch,
    required String trackId,
    required int hostPosMs,
    required int sampledAtRoomTimeMs,
    required int roomNowMs,
    required int clientPosMs,
    required int durationMs,
    required int latencyCompMs,
    required bool isClockLocked,
    int jitterMs = 0,
    int rttMs = 0,
  }) {
    // 计算预测 delta
    final elapsedMs = roomNowMs - sampledAtRoomTimeMs;
    final targetPosMs = (hostPosMs + elapsedMs - latencyCompMs).clamp(
      0,
      durationMs,
    );
    final deltaMs = targetPosMs - clientPosMs;

    // 预测 delta 公式:
    // 如果当前速度 > 1，客户端走得快，未来 delta 会变小
    final predictedDeltaMs =
        (deltaMs + (_currentSpeed - 1.0) * _config.predictionWindowMs).round();

    // 未启用，返回 noop 但仍提供 delta
    if (!_enabled) {
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'disabled',
      );
    }

    // 检查是否播放中
    if (!isPlaying) {
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'not_playing',
      );
    }

    // 检查时钟是否锁定
    if (!isClockLocked) {
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'clock_not_locked',
      );
    }

    // 检查 host_state 是否过期
    final ageMs = roomNowMs - sampledAtRoomTimeMs;
    if (ageMs > _config.hostStateStaleMs) {
      _droppedHostStateCount++;
      _lastDroppedReason = 'stale_host_state(age=${ageMs}ms)';
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: _lastDroppedReason,
      );
    }

    // 检查 epoch/trackId 是否变化
    if (_activeEpoch != epoch || _activeTrackId != trackId) {
      reset();
      _activeEpoch = epoch;
      _activeTrackId = trackId;
      SyncLog.i('[KeepSync] 重置: epoch=$epoch trackId=$trackId');
    }

    // 获取当前时间
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // 检查 hold 状态
    final holdRemaining = _holdUntilMs - nowMs;
    if (holdRemaining > 0) {
      // 在 hold 期间，保持速度为 1.0
      if (_currentSpeed != 1.0) {
        _currentSpeed = 1.0;
        _lastSpeedSetAtMs = nowMs;
        _speedSetCount++;
        return KeepSyncDecision(
          action: KeepSyncAction.speed,
          speed: 1.0,
          deltaMs: deltaMs,
          predictedDeltaMs: predictedDeltaMs,
          targetPosMs: targetPosMs,
          clientPosMs: clientPosMs,
          speedCmd: 1.0,
          holdRemainingMs: holdRemaining,
          reason: 'reverse_guard_hold',
        );
      }
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        holdRemainingMs: holdRemaining,
        reason: 'hold',
      );
    }

    // 使用预测 delta 做决策
    final absPredictedDelta = predictedDeltaMs.abs();
    final absDelta = deltaMs.abs();

    // A) |predictedDelta| <= deadband: 不调整
    if (absPredictedDelta <= _config.deadbandMs) {
      // 如果当前速度不是 1.0，可以回归
      if (_currentSpeed != 1.0) {
        _speedEma =
            _speedEma * (1 - _config.speedAlpha) + 1.0 * _config.speedAlpha;
        if (nowMs - _lastSpeedSetAtMs >= _config.speedIntervalMs) {
          _currentSpeed = 1.0;
          _lastSpeedSetAtMs = nowMs;
          _speedSetCount++;
          return KeepSyncDecision(
            action: KeepSyncAction.speed,
            speed: 1.0,
            deltaMs: deltaMs,
            predictedDeltaMs: predictedDeltaMs,
            targetPosMs: targetPosMs,
            clientPosMs: clientPosMs,
            speedCmd: 1.0,
            reason: 'return_to_normal',
          );
        }
      }
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'within_deadband',
      );
    }

    // B) |delta| > seekThreshold: 执行 seek
    if (absDelta > _config.seekThresholdMs) {
      // 检查 seek 冷却
      if (nowMs - _lastSeekAtMs < _config.seekCooldownMs) {
        return KeepSyncDecision(
          action: KeepSyncAction.noop,
          deltaMs: deltaMs,
          predictedDeltaMs: predictedDeltaMs,
          targetPosMs: targetPosMs,
          clientPosMs: clientPosMs,
          reason: 'seek_cooldown',
        );
      }

      _lastSeekAtMs = nowMs;
      _seekCount++;
      _currentSpeed = 1.0;
      _speedEma = 1.0;
      _lastDeltaSign = 0;
      _holdUntilMs = 0;

      SyncLog.i('[KeepSync] Seek: delta=$deltaMs target=$targetPosMs');

      return KeepSyncDecision(
        action: KeepSyncAction.seek,
        seekMs: targetPosMs,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'exceed_threshold',
      );
    }

    // C) deadband < |delta| <= seekThreshold: 调整速度
    // 检查是否在 seek 后的速度冷却期
    if (nowMs - _lastSeekAtMs < _config.speedCooldownAfterSeekMs) {
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'speed_cooldown_after_seek',
      );
    }

    // 检查速度调整间隔
    if (nowMs - _lastSpeedSetAtMs < _config.speedIntervalMs) {
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        reason: 'speed_interval',
      );
    }

    // 检测 delta 符号反转
    final currentDeltaSign = deltaMs.sign;
    if (_lastDeltaSign != 0 && currentDeltaSign != _lastDeltaSign) {
      // 符号反转，检查是否需要触发 guard
      if (absDelta < _config.reverseGuardThresholdMs) {
        // 进入 hold 模式，速度回归 1.0
        _holdUntilMs = nowMs + _config.reverseGuardHoldMs;
        _currentSpeed = 1.0;
        _speedEma = 1.0;
        _lastSpeedSetAtMs = nowMs;
        _speedSetCount++;
        _lastDeltaSign = currentDeltaSign;

        SyncLog.i(
          '[KeepSync] 反转 guard: delta=$deltaMs hold=${_config.reverseGuardHoldMs}ms',
        );

        return KeepSyncDecision(
          action: KeepSyncAction.speed,
          speed: 1.0,
          deltaMs: deltaMs,
          predictedDeltaMs: predictedDeltaMs,
          targetPosMs: targetPosMs,
          clientPosMs: clientPosMs,
          speedCmd: 1.0,
          holdRemainingMs: _config.reverseGuardHoldMs,
          reason: 'reverse_guard',
        );
      }
    }
    _lastDeltaSign = currentDeltaSign;

    // 计算目标速度（基于预测 delta）
    final speedDelta = (predictedDeltaMs * _config.speedK).clamp(
      _config.speedMin - 1.0,
      _config.speedMax - 1.0,
    );
    final speedTarget = 1.0 + speedDelta;

    // 高 jitter/RTT 降权
    double effectiveAlpha = _config.speedAlpha;
    if (jitterMs > _config.highJitterThresholdMs ||
        rttMs > _config.highRttThresholdMs) {
      effectiveAlpha *= _config.jitterAlphaRatio;
    }

    // EMA 平滑
    _speedEma = _speedEma * (1 - effectiveAlpha) + speedTarget * effectiveAlpha;

    // 限幅到有效范围
    final speedEmaClamped = _speedEma.clamp(_config.speedMin, _config.speedMax);

    // 速度变化 rate limit
    final maxStep = _config.maxSpeedStepPerUpdate;
    final speedCmd = speedEmaClamped.clamp(
      _currentSpeed - maxStep,
      _currentSpeed + maxStep,
    );

    // 如果速度变化太小，跳过
    if ((speedCmd - _currentSpeed).abs() < 0.002) {
      return KeepSyncDecision(
        action: KeepSyncAction.noop,
        deltaMs: deltaMs,
        predictedDeltaMs: predictedDeltaMs,
        targetPosMs: targetPosMs,
        clientPosMs: clientPosMs,
        speedCmd: speedCmd,
        reason: 'speed_change_too_small',
      );
    }

    _currentSpeed = speedCmd;
    _lastSpeedSetAtMs = nowMs;
    _speedSetCount++;

    SyncLog.d(
      '[KeepSync] Speed: delta=$deltaMs pred=$predictedDeltaMs speed=$speedCmd (target=$speedTarget ema=$_speedEma)',
    );

    return KeepSyncDecision(
      action: KeepSyncAction.speed,
      speed: speedCmd,
      deltaMs: deltaMs,
      predictedDeltaMs: predictedDeltaMs,
      targetPosMs: targetPosMs,
      clientPosMs: clientPosMs,
      speedCmd: speedCmd,
      reason: jitterMs > _config.highJitterThresholdMs
          ? 'adjust_speed_jitter_degraded'
          : 'adjust_speed',
    );
  }

  /// 释放资源
  void dispose() {
    reset();
  }
}
