import 'dart:async';

import '../diagnostics/sync_log.dart';
import '../diagnostics/sync_diagnostics.dart';

/// 时钟同步样本
class ClockSample {
  final int seq;
  final int t0ClientMs; // 客户端发送 ping 时间
  final int t1ServerMs; // 服务器收到并回复时间
  final int t2ClientMs; // 客户端收到 pong 时间
  final int rttMs;
  final int offsetRawMs;
  final DateTime timestamp;

  const ClockSample({
    required this.seq,
    required this.t0ClientMs,
    required this.t1ServerMs,
    required this.t2ClientMs,
    required this.rttMs,
    required this.offsetRawMs,
    required this.timestamp,
  });
}

/// 房间时钟 - NTP-like 时钟同步
/// 提供基于 Host 时钟的统一时间基准
class RoomClock {
  final SyncDiagnostics _diagnostics = SyncDiagnostics();

  // ==================== 时钟偏移 ====================

  // 原始偏移（最近一次）
  int _offsetRawMs = 0;

  // EMA 平滑后的偏移
  int _offsetEmaMs = 0;

  // EMA 平滑因子（0-1，越大越敏感）
  double _emaAlpha = 0.1;

  // 默认 alpha 值
  static const double kDefaultAlpha = 0.1;

  // ==================== RTT 和 Jitter ====================

  // 最近一次 RTT
  int _rttMs = 0;

  // RTT 的 EMA
  double _rttEma = 0;

  // Jitter（RTT 的绝对偏差 EMA）
  int _jitterMs = 0;
  double _jitterEma = 0;

  // ==================== 样本管理 ====================

  // 样本列表
  final List<ClockSample> _samples = [];

  // 最大样本数
  static const int _maxSamples = 30;

  // 样本计数
  int _sampleCount = 0;

  // 序列号
  int _seq = 0;

  // ==================== 样本过滤 ====================

  // 丢弃样本计数
  int _droppedSamplesCount = 0;

  // 最近丢弃原因
  String? _lastDroppedReason;

  // 最近合格样本的 RTT
  int _lastGoodRttMs = 0;

  // 最近 5 个合格样本（用于 min-rtt strategy）
  final List<ClockSample> _goodSamples = [];
  static const int _maxGoodSamples = 5;

  // RTT 过滤阈值（ms）
  static const int _maxRttForFilter = 200;

  // Offset 跳跃过滤阈值（ms）
  static const int _maxOffsetJump = 120;

  // ==================== 锁定状态 ====================

  // 是否已锁定
  bool _isLocked = false;

  // 锁定状态变化流
  final _lockController = StreamController<bool>.broadcast();

  // 锁定所需最小样本数
  static const int _minSamplesForLock = 3;

  // 锁定允许的最大 RTT（ms）
  static const int _maxRttForLock = 300;

  // 锁定允许的最大 jitter（ms）
  static const int _maxJitterForLock = 100;

  // ==================== 定时同步 ====================

  // 同步定时器
  Timer? _syncTimer;

  // 正常同步间隔
  static const Duration _normalSyncInterval = Duration(milliseconds: 800);

  // 后台同步间隔（降低频率）
  static const Duration _backgroundSyncInterval = Duration(seconds: 2);

  // 快速采样间隔（恢复前台后）
  static const Duration _fastSyncInterval = Duration(milliseconds: 200);

  // 快速采样次数
  static const int _fastSampleCount = 3;

  // 当前快速采样计数
  int _fastSampleRemaining = 0;

  // 是否在后台模式
  bool _isBackground = false;

  // ==================== epoch ====================

  int _epoch = 0;

  // ==================== 公开属性 ====================

  /// 当前房间时间（毫秒）
  /// Client: 本地时间 + 偏移
  int get roomNowMs => DateTime.now().millisecondsSinceEpoch + _offsetEmaMs;

  /// 原始偏移（最近一次样本）
  int get offsetRawMs => _offsetRawMs;

  /// EMA 平滑后的偏移
  int get offsetEmaMs => _offsetEmaMs;

  /// 最近一次 RTT
  int get rttMs => _rttMs;

  /// Jitter（网络抖动）
  int get jitterMs => _jitterMs;

  /// 是否已锁定（时钟同步稳定）
  bool get isLocked => _isLocked;

  /// 锁定状态变化流
  Stream<bool> get lockStream => _lockController.stream;

  /// 样本计数
  int get sampleCount => _sampleCount;

  /// 当前 epoch
  int get epoch => _epoch;

  /// 当前 seq
  int get seq => _seq;

  /// EMA alpha 值
  double get emaAlpha => _emaAlpha;

  /// 丢弃样本计数
  int get droppedSamplesCount => _droppedSamplesCount;

  /// 最近丢弃原因
  String? get lastDroppedReason => _lastDroppedReason;

  /// 最近合格样本的 RTT
  int get lastGoodRttMs => _lastGoodRttMs;

  // ==================== 配置方法 ====================

  /// 设置 EMA alpha 值
  void setEmaAlpha(double alpha) {
    if (alpha > 0 && alpha <= 1) {
      _emaAlpha = alpha;
      SyncLog.i('[Clock] EMA alpha set to $alpha');
    }
  }

  // ==================== 时钟同步 ====================

  /// Host 创建新 epoch
  int newEpoch() {
    _epoch++;
    _seq = 0;
    SyncLog.d('[Clock] New epoch: $_epoch', role: 'host');
    return _epoch;
  }

  /// 获取下一个 seq
  int nextSeq() {
    _seq++;
    return _seq;
  }

  /// 处理 NTP-like 时钟同步样本
  /// t0ClientMs: 客户端发送 ping 的时间
  /// t1ServerMs: 服务器收到并回复的时间
  /// t2ClientMs: 客户端收到 pong 的时间
  void processSample({
    required int seq,
    required int t0ClientMs,
    required int t1ServerMs,
    required int t2ClientMs,
  }) {
    // 计算 RTT
    final rttMs = t2ClientMs - t0ClientMs;

    // 计算原始偏移
    // offset = t1ServerMs - (t0ClientMs + t2ClientMs) / 2
    // 这表示：client 的 localNow + offset ≈ serverNow
    final offsetRawMs = t1ServerMs - ((t0ClientMs + t2ClientMs) ~/ 2);

    // 基础有效性检查
    if (rttMs < 0) {
      _recordDroppedSample(seq, rttMs, offsetRawMs, 'rtt_negative');
      return;
    }

    // 样本过滤：RTT 过高
    if (rttMs > _maxRttForFilter) {
      _recordDroppedSample(seq, rttMs, offsetRawMs, 'rtt_too_high');
      return;
    }

    // 样本过滤：Offset 跳跃过大（需要已有 offsetEma）
    if (_offsetEmaMs != 0 &&
        (offsetRawMs - _offsetEmaMs).abs() > _maxOffsetJump) {
      _recordDroppedSample(seq, rttMs, offsetRawMs, 'offset_jump');
      return;
    }

    // 样本通过过滤，创建样本
    final sample = ClockSample(
      seq: seq,
      t0ClientMs: t0ClientMs,
      t1ServerMs: t1ServerMs,
      t2ClientMs: t2ClientMs,
      rttMs: rttMs,
      offsetRawMs: offsetRawMs,
      timestamp: DateTime.now(),
    );

    // 添加到样本列表
    _samples.add(sample);
    if (_samples.length > _maxSamples) {
      _samples.removeAt(0);
    }

    // 添加到合格样本列表（用于 min-rtt strategy）
    _goodSamples.add(sample);
    if (_goodSamples.length > _maxGoodSamples) {
      _goodSamples.removeAt(0);
    }

    _sampleCount++;
    _seq = seq;
    _rttMs = rttMs;
    _offsetRawMs = offsetRawMs;
    _lastGoodRttMs = rttMs;
    _lastDroppedReason = null; // 清除丢弃原因

    // 更新 RTT EMA
    if (_rttEma == 0) {
      _rttEma = rttMs.toDouble();
    } else {
      _rttEma = _emaAlpha * rttMs + (1 - _emaAlpha) * _rttEma;
    }

    // 更新 Jitter（RTT 的绝对偏差 EMA）
    final rttDeviation = (rttMs - _rttEma).abs();
    if (_jitterEma == 0) {
      _jitterEma = rttDeviation;
    } else {
      _jitterEma = _emaAlpha * rttDeviation + (1 - _emaAlpha) * _jitterEma;
    }
    _jitterMs = _jitterEma.round();

    // Min-RTT Strategy：从最近 5 个合格样本中选 RTT 最小的更新 offsetEma
    final chosenSample = _chooseBestSample();
    final chosenOffsetMs = chosenSample.offsetRawMs;
    final chosenRttMs = chosenSample.rttMs;

    // 更新 offset EMA（使用选中的样本）
    if (_offsetEmaMs == 0) {
      _offsetEmaMs = chosenOffsetMs;
    } else {
      _offsetEmaMs =
          (_emaAlpha * chosenOffsetMs + (1 - _emaAlpha) * _offsetEmaMs).round();
    }

    // 检查是否锁定
    _checkLocked();

    // 结构化日志（包含选中样本信息）
    SyncLog.i(
      '[Clock] sample seq=$seq rttMs=$rttMs offsetRawMs=$offsetRawMs offsetEmaMs=$_offsetEmaMs jitterMs=$_jitterMs alpha=$_emaAlpha locked=$_isLocked chosenRtt=$chosenRttMs',
      rateLimitKey: 'clock_sample',
    );

    // 更新诊断数据
    _diagnostics.updatePartial(
      rttMs: _rttMs,
      offsetEmaMs: _offsetEmaMs,
      jitterMs: _jitterMs,
      droppedSamplesCount: _droppedSamplesCount,
      lastDroppedReason: _lastDroppedReason,
      lastGoodRttMs: _lastGoodRttMs,
    );
  }

  /// 记录丢弃的样本
  void _recordDroppedSample(
    int seq,
    int rttMs,
    int offsetRawMs,
    String reason,
  ) {
    _droppedSamplesCount++;
    _lastDroppedReason = reason;

    SyncLog.w(
      '[Clock] drop seq=$seq rttMs=$rttMs offsetRawMs=$offsetRawMs reason=$reason',
      rateLimitKey: 'clock_drop',
    );

    // 更新诊断数据（即使丢弃也要更新统计）
    _diagnostics.updatePartial(
      droppedSamplesCount: _droppedSamplesCount,
      lastDroppedReason: _lastDroppedReason,
    );
  }

  /// 从最近合格样本中选择最佳样本（min-rtt strategy）
  ClockSample _chooseBestSample() {
    if (_goodSamples.isEmpty) {
      // 不应该发生，但作为保护
      return ClockSample(
        seq: _seq,
        t0ClientMs: 0,
        t1ServerMs: 0,
        t2ClientMs: 0,
        rttMs: _rttMs,
        offsetRawMs: _offsetRawMs,
        timestamp: DateTime.now(),
      );
    }

    // 选择 RTT 最小的样本
    ClockSample best = _goodSamples.first;
    for (final sample in _goodSamples) {
      if (sample.rttMs < best.rttMs) {
        best = sample;
      }
    }
    return best;
  }

  /// 检查是否锁定
  void _checkLocked() {
    final wasLocked = _isLocked;

    if (_sampleCount < _minSamplesForLock) {
      _isLocked = false;
    } else if (_rttMs > _maxRttForLock) {
      _isLocked = false;
    } else if (_jitterMs > _maxJitterForLock) {
      _isLocked = false;
    } else {
      _isLocked = true;
    }

    // 状态变化时发射事件
    if (wasLocked != _isLocked) {
      _lockController.add(_isLocked);
    }
  }

  // ==================== 定时同步控制 ====================

  /// 启动定时同步
  void startPeriodicSync({
    required void Function(int seq, int t0ClientMs) onSendPing,
    Duration? interval,
  }) {
    _syncTimer?.cancel();

    final syncInterval = interval ?? _normalSyncInterval;

    _syncTimer = Timer.periodic(syncInterval, (_) {
      final seq = nextSeq();
      final t0ClientMs = DateTime.now().millisecondsSinceEpoch;
      onSendPing(seq, t0ClientMs);
    });
  }

  /// 停止定时同步
  void stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// 进入后台模式（降低同步频率）
  void enterBackground({
    required void Function(int seq, int t0ClientMs) onSendPing,
  }) {
    if (_isBackground) return;
    _isBackground = true;

    SyncLog.i('[Clock] Entering background mode');

    // 降低同步频率
    stopPeriodicSync();
    startPeriodicSync(
      onSendPing: onSendPing,
      interval: _backgroundSyncInterval,
    );
  }

  /// 恢复前台模式（快速采样重新锁定）
  void enterForeground({
    required void Function(int seq, int t0ClientMs) onSendPing,
  }) {
    if (!_isBackground) return;
    _isBackground = false;

    SyncLog.i('[Clock] Entering foreground mode, fast sampling');

    // 快速采样 3 次
    _fastSampleRemaining = _fastSampleCount;
    stopPeriodicSync();

    _syncTimer = Timer.periodic(_fastSyncInterval, (_) {
      if (_fastSampleRemaining > 0) {
        final seq = nextSeq();
        final t0ClientMs = DateTime.now().millisecondsSinceEpoch;
        onSendPing(seq, t0ClientMs);
        _fastSampleRemaining--;
      } else {
        // 恢复正常频率
        stopPeriodicSync();
        startPeriodicSync(onSendPing: onSendPing);
      }
    });
  }

  // ==================== 重置 ====================

  /// 重置时钟（断线重连后调用）
  /// keepHistory: 是否保留历史样本（用于快速恢复）
  void reset({bool keepHistory = false}) {
    _offsetRawMs = 0;
    _offsetEmaMs = 0;
    _rttMs = 0;
    _rttEma = 0;
    _jitterMs = 0;
    _jitterEma = 0;
    _sampleCount = 0;
    _seq = 0;
    _isLocked = false;
    _fastSampleRemaining = 0;
    _isBackground = false;

    // 重置丢弃样本统计
    _droppedSamplesCount = 0;
    _lastDroppedReason = null;
    _lastGoodRttMs = 0;

    if (!keepHistory) {
      _samples.clear();
      _goodSamples.clear();
    }

    stopPeriodicSync();

    SyncLog.i('[Clock] Reset (keepHistory=$keepHistory)');
    _diagnostics.updatePartial(rttMs: 0, offsetEmaMs: 0, jitterMs: 0);
  }

  /// 释放资源
  void dispose() {
    stopPeriodicSync();
    _samples.clear();
  }
}
