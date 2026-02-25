import 'dart:developer' as developer;

/// 同步系统统一日志工具
/// 所有同步相关日志必须通过此工具输出
class SyncLog {
  static const String _tagName = 'SyncV2';

  static final List<String> _buffer = [];
  static const int _maxBufferLines = 800;

  // 日志级别
  static const int levelVerbose = 0;
  static const int levelDebug = 1;
  static const int levelInfo = 2;
  static const int levelWarning = 3;
  static const int levelError = 4;

  /// 当前日志级别，可动态调整
  static int currentLevel = levelDebug;

  /// 是否开启详细日志（每条 pong 都打印）
  static bool debugVerbose = false;

  // Rate limit 相关
  static final Map<String, int> _lastLogTimeMs = {};

  /// Rate limit 配置：key -> 最小间隔 ms
  static final Map<String, int> _rateLimitConfig = {
    'host_pong': 2000, // Host pong 日志每 2 秒最多 1 条
    'clock_sample': 500, // 时钟采样日志每 500ms 最多 1 条
    'clock_drop': 1000, // 样本丢弃日志每秒最多 1 条
    'ping_sent': 1000, // ping 发送日志每秒最多 1 条
  };

  /// 检查是否应该打印（rate limit）
  static bool _shouldLog(String? key) {
    if (key == null) return true;

    final now = DateTime.now().millisecondsSinceEpoch;
    final lastTime = _lastLogTimeMs[key] ?? 0;
    final minInterval = _rateLimitConfig[key] ?? 0;

    if (now - lastTime >= minInterval) {
      _lastLogTimeMs[key] = now;
      return true;
    }
    return false;
  }

  /// 结构化日志输出
  static void log({
    required String message,
    int level = levelInfo,
    String? role,
    String? roomId,
    String? peerId,
    int? epoch,
    int? seq,
    int? rttMs,
    int? offsetMs,
    int? jitterMs,
    int? hostPosMs,
    int? clientPosMs,
    int? latencyCompMs,
    int? deltaMs,
    double? speedSet,
    bool? seekPerformed,
    String? reason,
    Object? error,
    StackTrace? stackTrace,
    String? rateLimitKey, // 新增：rate limit key
  }) {
    if (level < currentLevel) return;

    // Rate limit 检查
    if (!_shouldLog(rateLimitKey)) return;

    final buffer = StringBuffer();
    buffer.write('[$_tagName] ');

    // 基础字段
    if (role != null) buffer.write('role=$role ');
    if (roomId != null) buffer.write('roomId=$roomId ');
    if (peerId != null) buffer.write('peerId=$peerId ');

    // 时钟同步字段
    if (epoch != null) buffer.write('epoch=$epoch ');
    if (seq != null) buffer.write('seq=$seq ');
    if (rttMs != null) buffer.write('rttMs=$rttMs ');
    if (offsetMs != null) buffer.write('offsetMs=$offsetMs ');
    if (jitterMs != null) buffer.write('jitterMs=$jitterMs ');

    // 播放位置字段
    if (hostPosMs != null) buffer.write('hostPosMs=$hostPosMs ');
    if (clientPosMs != null) buffer.write('clientPosMs=$clientPosMs ');
    if (latencyCompMs != null) buffer.write('latencyCompMs=$latencyCompMs ');

    // 同步控制字段
    if (deltaMs != null) buffer.write('deltaMs=$deltaMs ');
    if (speedSet != null) buffer.write('speedSet=$speedSet ');
    if (seekPerformed != null) buffer.write('seekPerformed=$seekPerformed ');
    if (reason != null) buffer.write('reason=$reason ');

    // 消息
    buffer.write('| $message');

    final levelPrefix = _getLevelPrefix(level);
    final fullMessage = '$levelPrefix${buffer.toString()}';

    final ts = DateTime.now().toIso8601String();
    _pushToBuffer('$ts $fullMessage');

    // 使用 developer.log 以支持结构化日志
    developer.log(
      fullMessage,
      name: _tagName,
      level: _toDeveloperLevel(level),
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _pushToBuffer(String line) {
    _buffer.add(line);
    if (_buffer.length > _maxBufferLines) {
      _buffer.removeRange(0, _buffer.length - _maxBufferLines);
    }
  }

  static List<String> get bufferedLines => List.unmodifiable(_buffer);

  static String exportBufferedText() => _buffer.join('\n');

  static void clearBuffer() {
    _buffer.clear();
  }

  static String _getLevelPrefix(int level) {
    switch (level) {
      case levelVerbose:
        return '[V] ';
      case levelDebug:
        return '[D] ';
      case levelInfo:
        return '[I] ';
      case levelWarning:
        return '[W] ';
      case levelError:
        return '[E] ';
      default:
        return '[?] ';
    }
  }

  static int _toDeveloperLevel(int level) {
    switch (level) {
      case levelVerbose:
      case levelDebug:
        return 500; // FINE
      case levelInfo:
        return 800; // INFO
      case levelWarning:
        return 900; // WARNING
      case levelError:
        return 1000; // SEVERE
      default:
        return 800;
    }
  }

  // 便捷方法
  static void v(
    String message, {
    String? role,
    String? roomId,
    String? peerId,
  }) {
    log(
      message: message,
      level: levelVerbose,
      role: role,
      roomId: roomId,
      peerId: peerId,
    );
  }

  static void d(
    String message, {
    String? role,
    String? roomId,
    String? peerId,
    int? epoch,
    int? seq,
    String? rateLimitKey,
  }) {
    log(
      message: message,
      level: levelDebug,
      role: role,
      roomId: roomId,
      peerId: peerId,
      epoch: epoch,
      seq: seq,
      rateLimitKey: rateLimitKey,
    );
  }

  static void i(
    String message, {
    String? role,
    String? roomId,
    String? peerId,
    int? rttMs,
    int? offsetMs,
    String? rateLimitKey,
  }) {
    log(
      message: message,
      level: levelInfo,
      role: role,
      roomId: roomId,
      peerId: peerId,
      rttMs: rttMs,
      offsetMs: offsetMs,
      rateLimitKey: rateLimitKey,
    );
  }

  static void w(
    String message, {
    String? role,
    String? roomId,
    String? reason,
    String? rateLimitKey,
  }) {
    log(
      message: message,
      level: levelWarning,
      role: role,
      roomId: roomId,
      reason: reason,
      rateLimitKey: rateLimitKey,
    );
  }

  static void e(
    String message, {
    String? role,
    String? roomId,
    Object? error,
    StackTrace? stackTrace,
  }) {
    log(
      message: message,
      level: levelError,
      role: role,
      roomId: roomId,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 同步状态快照日志
  static void syncSnapshot({
    required String role,
    required String roomId,
    String? peerId,
    required int epoch,
    required int seq,
    required int rttMs,
    required int offsetMs,
    required int jitterMs,
    required int hostPosMs,
    required int clientPosMs,
    required int latencyCompMs,
    required int deltaMs,
    required double speedSet,
    required bool seekPerformed,
    String? reason,
  }) {
    log(
      message: 'SYNC_SNAPSHOT',
      level: levelInfo,
      role: role,
      roomId: roomId,
      peerId: peerId,
      epoch: epoch,
      seq: seq,
      rttMs: rttMs,
      offsetMs: offsetMs,
      jitterMs: jitterMs,
      hostPosMs: hostPosMs,
      clientPosMs: clientPosMs,
      latencyCompMs: latencyCompMs,
      deltaMs: deltaMs,
      speedSet: speedSet,
      seekPerformed: seekPerformed,
      reason: reason,
    );
  }
}
