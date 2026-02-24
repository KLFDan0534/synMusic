import 'dart:async';

import '../diagnostics/sync_log.dart';
import '../transport/transport_interface.dart';
import '../transport/protocol.dart';
import 'room_clock.dart';

/// 时钟同步器
/// 负责执行 NTP 风格的时钟同步（通过 ping/pong 实现）
class ClockSynchronizer {
  final RoomClock _clock;
  final Transport _transport;

  // 待处理的 ping 请求（seq -> t0ClientMs）
  final Map<int, int> _pendingPings = {};

  // 是否正在同步
  bool _isSyncing = false;

  ClockSynchronizer({required RoomClock clock, required Transport transport})
    : _clock = clock,
      _transport = transport;

  /// 是否正在同步
  bool get isSyncing => _isSyncing;

  /// 开始定时同步（Client 调用）
  void startSyncing() {
    if (_isSyncing) return;

    _isSyncing = true;

    // 监听 pong 回复
    _transport.messageStream.listen(_onMessage);

    // 启动 RoomClock 定时同步
    _clock.startPeriodicSync(
      onSendPing: (seq, t0ClientMs) {
        _pendingPings[seq] = t0ClientMs;
        final ping = PingMessage(seq: seq, t0ClientMs: t0ClientMs);
        _transport.send(
          TransportMessage.create(SyncProtocol.ping, ping.toJson()),
        );

        SyncLog.d('[ClockSynchronizer] Sent ping seq=$seq', role: 'client');

        // 超时清理
        Future.delayed(const Duration(seconds: 2), () {
          _pendingPings.remove(seq);
        });
      },
    );

    SyncLog.i('[ClockSynchronizer] Started', role: 'client');
  }

  /// 停止同步
  void stopSyncing() {
    _isSyncing = false;
    _clock.stopPeriodicSync();
    _pendingPings.clear();

    SyncLog.i('[ClockSynchronizer] Stopped', role: 'client');
  }

  /// 处理消息
  void _onMessage(TransportMessage message) {
    if (message.type == SyncProtocol.pong) {
      _handlePong(message);
    }
  }

  /// 处理 pong 回复（Client 调用）
  void _handlePong(TransportMessage message) {
    final pong = PongMessage.fromJson(message.payload);

    // 查找对应的 ping 请求
    final t0ClientMs = _pendingPings.remove(pong.seq);
    if (t0ClientMs == null) {
      SyncLog.w(
        '[ClockSynchronizer] Received unknown pong: seq=${pong.seq}',
        role: 'client',
      );
      return;
    }

    // 记录接收时间
    final t2ClientMs = DateTime.now().millisecondsSinceEpoch;

    // 处理时钟同步样本
    _clock.processSample(
      seq: pong.seq,
      t0ClientMs: pong.t0ClientMs,
      t1ServerMs: pong.t1ServerMs,
      t2ClientMs: t2ClientMs,
    );
  }

  /// 进入后台模式
  void enterBackground() {
    _clock.enterBackground(
      onSendPing: (seq, t0ClientMs) {
        _pendingPings[seq] = t0ClientMs;
        final ping = PingMessage(seq: seq, t0ClientMs: t0ClientMs);
        _transport.send(
          TransportMessage.create(SyncProtocol.ping, ping.toJson()),
        );
      },
    );
  }

  /// 恢复前台模式
  void enterForeground() {
    _clock.enterForeground(
      onSendPing: (seq, t0ClientMs) {
        _pendingPings[seq] = t0ClientMs;
        final ping = PingMessage(seq: seq, t0ClientMs: t0ClientMs);
        _transport.send(
          TransportMessage.create(SyncProtocol.ping, ping.toJson()),
        );
      },
    );
  }

  /// 设置 EMA alpha 值
  void setEmaAlpha(double alpha) {
    _clock.setEmaAlpha(alpha);
  }

  /// 重置时钟
  void reset({bool keepHistory = false}) {
    _clock.reset(keepHistory: keepHistory);
    _pendingPings.clear();
  }

  /// 释放资源
  void dispose() {
    stopSyncing();
    _clock.dispose();
  }
}
