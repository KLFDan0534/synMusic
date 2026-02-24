import 'dart:async';

import '../diagnostics/sync_log.dart';
import '../clock/room_clock.dart';

/// 未来启动状态
enum FutureStartState {
  idle, // 空闲
  preparing, // 准备中（加载播放器）
  waiting, // 等待到达目标时间
  started, // 已启动
  failed, // 失败
}

/// 未来启动参数
class FutureStartParams {
  final int epoch;
  final int seq;
  final String trackId;
  final int startAtRoomTimeMs;
  final int startPosMs;

  const FutureStartParams({
    required this.epoch,
    required this.seq,
    required this.trackId,
    required this.startAtRoomTimeMs,
    required this.startPosMs,
  });
}

/// 未来启动结果
class FutureStartResult {
  final bool success;
  final int? actualStartRoomTimeMs;
  final int? startErrorMs;
  final String? failReason;

  const FutureStartResult({
    required this.success,
    this.actualStartRoomTimeMs,
    this.startErrorMs,
    this.failReason,
  });
}

/// 未来启动控制器
/// 在指定的房间时间点精确启动播放（两段式等待，不阻塞 UI）
class FutureStartController {
  final RoomClock _clock;

  // 定时器
  Timer? _coarseTimer;
  Timer? _fineTimer;

  // 当前调度参数（用于幂等检查）
  int _currentEpoch = -1;
  int _currentSeq = -1;
  FutureStartParams? _scheduledParams;

  // 状态
  FutureStartState _state = FutureStartState.idle;
  final _stateController = StreamController<FutureStartState>.broadcast();

  // 诊断信息
  int _startAtRoomTimeMs = 0;
  int _actualStartRoomTimeMs = 0;
  int _startErrorMs = 0;
  int _remainingWaitMs = 0;

  // 启动回调
  void Function(FutureStartParams params)? _onStart;

  FutureStartController({required RoomClock clock}) : _clock = clock;

  /// 当前状态
  FutureStartState get state => _state;

  /// 状态流
  Stream<FutureStartState> get stateStream => _stateController.stream;

  /// 诊断信息
  int get startAtRoomTimeMs => _startAtRoomTimeMs;
  int get actualStartRoomTimeMs => _actualStartRoomTimeMs;
  int get startErrorMs => _startErrorMs;
  int get remainingWaitMs => _remainingWaitMs;
  FutureStartParams? get scheduledParams => _scheduledParams;

  /// 是否可以调度（幂等检查）
  bool canSchedule(int epoch, int seq) {
    // 相同 epoch+seq 不可重复调度
    if (epoch == _currentEpoch && seq == _currentSeq) {
      SyncLog.w(
        '[FutureStart] Duplicate schedule ignored: epoch=$epoch, seq=$seq',
      );
      return false;
    }
    // 更小的 epoch 被忽略
    if (epoch < _currentEpoch) {
      SyncLog.w(
        '[FutureStart] Stale epoch ignored: epoch=$epoch < current=$_currentEpoch',
      );
      return false;
    }
    return true;
  }

  /// 调度未来启动（两段式等待）
  /// [params] 启动参数
  /// [onPrepare] 准备回调（加载播放器）
  /// [onStart] 启动回调（调用 play）
  Future<void> schedule({
    required FutureStartParams params,
    required Future<FutureStartResult> Function(FutureStartParams params)
    onPrepare,
    required void Function(FutureStartParams params) onStart,
  }) async {
    // 幂等检查
    if (!canSchedule(params.epoch, params.seq)) {
      return;
    }

    // 取消之前的调度
    cancel();

    _currentEpoch = params.epoch;
    _currentSeq = params.seq;
    _scheduledParams = params;
    _startAtRoomTimeMs = params.startAtRoomTimeMs;
    _onStart = onStart;

    final nowMs = _clock.roomNowMs;
    final totalWaitMs = params.startAtRoomTimeMs - nowMs;

    if (totalWaitMs <= 0) {
      SyncLog.w(
        '[FutureStart] Target time already passed: T=${params.startAtRoomTimeMs}, now=$nowMs',
      );
      _updateState(FutureStartState.failed);
      return;
    }

    SyncLog.i(
      '[FutureStart] Scheduled epoch=${params.epoch} seq=${params.seq} T=${params.startAtRoomTimeMs} waitMs=$totalWaitMs',
    );

    // ==================== 阶段 1：准备 ====================
    _updateState(FutureStartState.preparing);

    final prepareResult = await onPrepare(params);
    if (!prepareResult.success) {
      SyncLog.e('[FutureStart] Prepare failed: ${prepareResult.failReason}');
      _updateState(FutureStartState.failed);
      return;
    }

    SyncLog.i('[FutureStart] Prepared trackId=${params.trackId}');

    // ==================== 阶段 2：两段式等待 ====================
    _updateState(FutureStartState.waiting);

    // 重新计算剩余等待时间（准备操作消耗了时间）
    final nowAfterPrepareMs = _clock.roomNowMs;
    final remainingWaitMs = params.startAtRoomTimeMs - nowAfterPrepareMs;

    if (remainingWaitMs <= 0) {
      // 时间已过，立即启动
      SyncLog.w(
        '[FutureStart] Target time passed during prepare: remaining=$remainingWaitMs',
      );
      _executeStart();
      return;
    }

    const fineWaitMs = 80; // 细等时间
    final coarseWaitMs = remainingWaitMs - fineWaitMs;

    if (coarseWaitMs > 0) {
      // 粗等：Future.delayed 到 (T - 80ms)
      _coarseTimer = Timer(Duration(milliseconds: coarseWaitMs), () {
        _enterFineWait();
      });
      SyncLog.d('[FutureStart] Coarse wait: ${coarseWaitMs}ms');
    } else {
      // 已经很接近，直接进入细等
      _enterFineWait();
    }
  }

  /// 进入细等阶段（高频 Timer，不阻塞 UI）
  void _enterFineWait() {
    const fineIntervalMs = 2; // 每 2ms 检查一次

    _fineTimer = Timer.periodic(const Duration(milliseconds: fineIntervalMs), (
      timer,
    ) {
      final nowMs = _clock.roomNowMs;
      final remainingMs = _startAtRoomTimeMs - nowMs;
      _remainingWaitMs = remainingMs > 0 ? remainingMs : 0;

      if (remainingMs <= 0) {
        timer.cancel();
        _executeStart();
      }
    });

    SyncLog.d('[FutureStart] Fine wait started (interval=${fineIntervalMs}ms)');
  }

  /// 执行启动
  void _executeStart() {
    _fineTimer?.cancel();
    _fineTimer = null;
    _coarseTimer?.cancel();
    _coarseTimer = null;

    // 记录实际启动时间
    _actualStartRoomTimeMs = _clock.roomNowMs;
    _startErrorMs = _actualStartRoomTimeMs - _startAtRoomTimeMs;

    _updateState(FutureStartState.started);

    SyncLog.i(
      '[FutureStart] Started actual=$_actualStartRoomTimeMs errorMs=$_startErrorMs',
    );

    _onStart?.call(_scheduledParams!);

    // 短暂延迟后回到 idle 状态
    Timer(const Duration(seconds: 2), () {
      _updateState(FutureStartState.idle);
    });
  }

  /// 取消未来启动
  void cancel() {
    _coarseTimer?.cancel();
    _coarseTimer = null;
    _fineTimer?.cancel();
    _fineTimer = null;
    _onStart = null;
    _scheduledParams = null;
    _updateState(FutureStartState.idle);

    SyncLog.i('[FutureStart] Cancelled');
  }

  void _updateState(FutureStartState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(_state);
    }
  }

  /// 释放资源
  void dispose() {
    cancel();
    _stateController.close();
  }
}
