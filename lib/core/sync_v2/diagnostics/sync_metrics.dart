import 'dart:convert';
import 'dart:math';

/// 同步样本
class SyncSample {
  final int tsRoomNowMs;
  final int deltaMs;
  final int audiblePosMs;
  final int targetPosMs;
  final int rttMs;
  final int jitterMs;
  final double speed;
  final String action;

  const SyncSample({
    required this.tsRoomNowMs,
    required this.deltaMs,
    required this.audiblePosMs,
    required this.targetPosMs,
    required this.rttMs,
    required this.jitterMs,
    required this.speed,
    required this.action,
  });

  Map<String, dynamic> toJson() => {
    'ts': tsRoomNowMs,
    'delta': deltaMs,
    'audiblePos': audiblePosMs,
    'targetPos': targetPosMs,
    'rtt': rttMs,
    'jitter': jitterMs,
    'speed': speed,
    'action': action,
  };
}

/// 滑窗统计结果
class SyncStats {
  final int sampleCount;
  final double meanMs;
  final double stdMs;
  final int p50Ms;
  final int p95Ms;
  final int p99Ms;
  final double within30msRatio; // abs(delta) <= 30ms 的占比
  final int seekCount;
  final int speedSetCount;
  final int durationSec;

  const SyncStats({
    this.sampleCount = 0,
    this.meanMs = 0,
    this.stdMs = 0,
    this.p50Ms = 0,
    this.p95Ms = 0,
    this.p99Ms = 0,
    this.within30msRatio = 0,
    this.seekCount = 0,
    this.speedSetCount = 0,
    this.durationSec = 0,
  });

  /// 格式化显示
  String get formatted =>
      '样本=$sampleCount 均值=${meanMs.toStringAsFixed(1)}ms '
      'P50=$p50Ms P95=$p95Ms P99=$p99Ms <=30ms=${(within30msRatio * 100).toStringAsFixed(1)}%';
}

/// Drop 原因统计
class DropStats {
  final int staleCount;
  final int clockUnlockedCount;
  final int notReadyCount;
  final int total;

  const DropStats({
    this.staleCount = 0,
    this.clockUnlockedCount = 0,
    this.notReadyCount = 0,
    this.total = 0,
  });

  DropStats copyWith({
    int? staleCount,
    int? clockUnlockedCount,
    int? notReadyCount,
    int? total,
  }) {
    return DropStats(
      staleCount: staleCount ?? this.staleCount,
      clockUnlockedCount: clockUnlockedCount ?? this.clockUnlockedCount,
      notReadyCount: notReadyCount ?? this.notReadyCount,
      total: total ?? this.total,
    );
  }
}

/// 保护模式状态
enum ProtectMode { normal, protect }

/// 保护模式触发原因
enum ProtectTrigger {
  none,
  p95Exceeded, // P95 > 60ms 持续 10s
  seekTooFrequent, // seek > 3/min
  staleDropStreak, // 连续 5 次 stale drop
}

/// 同步指标收集器
class SyncMetricsCollector {
  // 滑窗样本（最近 120s）
  final List<SyncSample> _samples = [];
  static const int _maxSamples = 600; // 200ms 间隔 * 120s = 600

  // Drop 统计
  DropStats _dropStats = const DropStats();
  int _staleDropStreak = 0;

  // 保护模式
  ProtectMode _protectMode = ProtectMode.normal;
  ProtectTrigger _protectTrigger = ProtectTrigger.none;
  int _protectModeEnteredAt = 0;
  int _p95ExceededSince = 0;
  static const int _protectCooldownMs = 10000; // 保护模式持续 10s

  /// 记录样本
  void record({
    required int tsRoomNowMs,
    required int deltaMs,
    required int audiblePosMs,
    required int targetPosMs,
    required int rttMs,
    required int jitterMs,
    required double speed,
    required String action,
  }) {
    final sample = SyncSample(
      tsRoomNowMs: tsRoomNowMs,
      deltaMs: deltaMs,
      audiblePosMs: audiblePosMs,
      targetPosMs: targetPosMs,
      rttMs: rttMs,
      jitterMs: jitterMs,
      speed: speed,
      action: action,
    );

    _samples.add(sample);

    // 限制滑窗大小
    if (_samples.length > _maxSamples) {
      _samples.removeAt(0);
    }

    // 检查保护模式
    _checkProtectMode(tsRoomNowMs);
  }

  /// 记录 drop
  void recordDrop(String reason) {
    switch (reason) {
      case 'stale':
        _dropStats = _dropStats.copyWith(
          staleCount: _dropStats.staleCount + 1,
          total: _dropStats.total + 1,
        );
        _staleDropStreak++;
        break;
      case 'clock_not_locked':
        _dropStats = _dropStats.copyWith(
          clockUnlockedCount: _dropStats.clockUnlockedCount + 1,
          total: _dropStats.total + 1,
        );
        _staleDropStreak = 0;
        break;
      case 'not_playing':
      case 'disabled':
        _dropStats = _dropStats.copyWith(
          notReadyCount: _dropStats.notReadyCount + 1,
          total: _dropStats.total + 1,
        );
        _staleDropStreak = 0;
        break;
      default:
        _staleDropStreak = 0;
    }
  }

  /// 获取最近 30s 统计
  SyncStats getStats30s(int nowMs) {
    return _computeStats(nowMs, 30000);
  }

  /// 获取最近 120s 统计
  SyncStats getStats120s(int nowMs) {
    return _computeStats(nowMs, 120000);
  }

  SyncStats _computeStats(int nowMs, int windowMs) {
    final cutoff = nowMs - windowMs;
    final windowSamples = _samples
        .where((s) => s.tsRoomNowMs >= cutoff)
        .toList();

    if (windowSamples.isEmpty) {
      return const SyncStats();
    }

    // 计算窗口内的 seek/speed 计数
    final windowSeeks = windowSamples.where((s) => s.action == 'seek').length;
    final windowSpeeds = windowSamples.where((s) => s.action == 'speed').length;

    // 计算 delta 统计
    final deltas = windowSamples.map((s) => s.deltaMs).toList();
    deltas.sort();

    final mean = deltas.reduce((a, b) => a + b) / deltas.length;
    final variance =
        deltas.map((d) => pow(d - mean, 2)).reduce((a, b) => a + b) /
        deltas.length;
    final std = sqrt(variance);

    final p50 = _percentile(deltas, 50);
    final p95 = _percentile(deltas, 95);
    final p99 = _percentile(deltas, 99);

    final within30ms = deltas.where((d) => d.abs() <= 30).length;
    final within30msRatio = within30ms / deltas.length;

    return SyncStats(
      sampleCount: deltas.length,
      meanMs: mean,
      stdMs: std,
      p50Ms: p50,
      p95Ms: p95,
      p99Ms: p99,
      within30msRatio: within30msRatio,
      seekCount: windowSeeks,
      speedSetCount: windowSpeeds,
      durationSec: windowMs ~/ 1000,
    );
  }

  int _percentile(List<int> sorted, int p) {
    if (sorted.isEmpty) return 0;
    final index = (sorted.length * p / 100).floor();
    return sorted[index.clamp(0, sorted.length - 1)];
  }

  /// 检查是否需要进入保护模式
  void _checkProtectMode(int nowMs) {
    if (_protectMode == ProtectMode.protect) {
      // 检查是否可以退出保护模式
      if (nowMs - _protectModeEnteredAt > _protectCooldownMs) {
        _exitProtectMode();
      }
      return;
    }

    // 检查触发条件
    final stats30s = getStats30s(nowMs);

    // 条件 1: P95 > 60ms 持续 10s
    if (stats30s.p95Ms > 60) {
      if (_p95ExceededSince == 0) {
        _p95ExceededSince = nowMs;
      } else if (nowMs - _p95ExceededSince > 10000) {
        _enterProtectMode(ProtectTrigger.p95Exceeded, nowMs);
        return;
      }
    } else {
      _p95ExceededSince = 0;
    }

    // 条件 2: seek > 3/min
    final stats60s = _computeStats(nowMs, 60000);
    if (stats60s.seekCount > 3) {
      _enterProtectMode(ProtectTrigger.seekTooFrequent, nowMs);
      return;
    }

    // 条件 3: 连续 5 次 stale drop
    if (_staleDropStreak >= 5) {
      _enterProtectMode(ProtectTrigger.staleDropStreak, nowMs);
      return;
    }
  }

  void _enterProtectMode(ProtectTrigger trigger, int nowMs) {
    _protectMode = ProtectMode.protect;
    _protectTrigger = trigger;
    _protectModeEnteredAt = nowMs;
    _staleDropStreak = 0;
  }

  void _exitProtectMode() {
    _protectMode = ProtectMode.normal;
    _protectTrigger = ProtectTrigger.none;
    _p95ExceededSince = 0;
  }

  /// 当前保护模式
  ProtectMode get protectMode => _protectMode;

  /// 保护模式触发原因
  ProtectTrigger get protectTrigger => _protectTrigger;

  /// Drop 统计
  DropStats get dropStats => _dropStats;

  /// 导出最近 120s 样本为 JSON
  String exportSamplesJson() {
    final data = {
      'samples': _samples.map((s) => s.toJson()).toList(),
      'exportedAt': DateTime.now().toIso8601String(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 重置
  void reset() {
    _samples.clear();
    _dropStats = const DropStats();
    _staleDropStreak = 0;
    _exitProtectMode();
  }
}
