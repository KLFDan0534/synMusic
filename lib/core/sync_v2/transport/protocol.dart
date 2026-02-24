/// 同步协议定义
/// 定义设备间通信的消息类型和格式

/// 协议版本
const int kProtoVer = 1;

/// 消息类型常量
class SyncProtocol {
  // 连接握手
  static const String hello = 'hello';
  static const String welcome = 'welcome';

  // 心跳
  static const String ping = 'ping';
  static const String pong = 'pong';

  // 房间管理
  static const String peerJoin = 'peer_join';
  static const String peerLeave = 'peer_leave';

  // 时钟同步
  static const String clockSync = 'clock_sync';
  static const String clockSyncReply = 'clock_sync_reply';

  // 音源分发
  static const String audioSource = 'audio_source';
  static const String audioSourceReady = 'audio_source_ready';
  static const String trackAnnounce = 'track_announce';
  static const String clientReady = 'client_ready';
  static const String clientReadyError = 'client_ready_error';

  // FutureStart 同起开播
  static const String startAt = 'start_at';
  static const String clientStartReport = 'client_start_report';

  // Host 状态广播（用于 Client 追帧）
  static const String hostState = 'host_state';

  // 播放控制
  static const String playCommand = 'play_command';
  static const String pauseCommand = 'pause_command';
  static const String seekCommand = 'seek_command';
  static const String playbackState = 'playback_state';

  // 同步控制
  static const String syncStart = 'sync_start';
  static const String syncTick = 'sync_tick';
  static const String syncCorrection = 'sync_correction';
}

/// 基础消息接口
abstract class SyncMessage {
  String get type;
  Map<String, dynamic> toJson();
}

/// Hello 握手消息
class HelloMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.hello;
  final int protoVer;
  final String roomId;
  final String peerId;
  final String role;
  final String deviceInfo;

  HelloMessage({
    required this.protoVer,
    required this.roomId,
    required this.peerId,
    required this.role,
    required this.deviceInfo,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'protoVer': protoVer,
    'roomId': roomId,
    'peerId': peerId,
    'role': role,
    'deviceInfo': deviceInfo,
  };

  factory HelloMessage.fromJson(Map<String, dynamic> json) {
    return HelloMessage(
      protoVer: json['protoVer'] as int? ?? 1,
      roomId: json['roomId'] as String,
      peerId: json['peerId'] as String,
      role: json['role'] as String,
      deviceInfo: json['deviceInfo'] as String? ?? 'unknown',
    );
  }
}

/// Welcome 握手响应消息
class WelcomeMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.welcome;
  final String sessionId;
  final int serverNowMs;

  WelcomeMessage({required this.sessionId, required this.serverNowMs});

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'sessionId': sessionId,
    'serverNowMs': serverNowMs,
  };

  factory WelcomeMessage.fromJson(Map<String, dynamic> json) {
    return WelcomeMessage(
      sessionId: json['sessionId'] as String,
      serverNowMs: json['serverNowMs'] as int,
    );
  }
}

/// Ping 心跳请求消息（NTP-like 时钟同步）
class PingMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.ping;
  final int seq; // 序列号
  final int t0ClientMs; // 客户端发送时间戳

  PingMessage({required this.seq, required this.t0ClientMs});

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'seq': seq,
    't0ClientMs': t0ClientMs,
  };

  factory PingMessage.fromJson(Map<String, dynamic> json) {
    return PingMessage(
      seq: json['seq'] as int? ?? 0,
      t0ClientMs: json['t0ClientMs'] as int? ?? json['t0'] as int? ?? 0,
    );
  }
}

/// Pong 心跳响应消息（NTP-like 时钟同步）
class PongMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.pong;
  final int seq; // 序列号
  final int t0ClientMs; // 原始 t0（客户端发送时间）
  final int t1ServerMs; // 服务器收到并回复的时间

  PongMessage({
    required this.seq,
    required this.t0ClientMs,
    required this.t1ServerMs,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'seq': seq,
    't0ClientMs': t0ClientMs,
    't1ServerMs': t1ServerMs,
  };

  factory PongMessage.fromJson(Map<String, dynamic> json) {
    return PongMessage(
      seq: json['seq'] as int? ?? 0,
      t0ClientMs: json['t0ClientMs'] as int? ?? json['t0'] as int? ?? 0,
      t1ServerMs:
          json['t1ServerMs'] as int? ?? json['t1ServerNowMs'] as int? ?? 0,
    );
  }
}

/// Peer 加入通知消息
class PeerJoinMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.peerJoin;
  final String peerId;
  final String role;
  final String deviceInfo;

  PeerJoinMessage({
    required this.peerId,
    required this.role,
    required this.deviceInfo,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'peerId': peerId,
    'role': role,
    'deviceInfo': deviceInfo,
  };

  factory PeerJoinMessage.fromJson(Map<String, dynamic> json) {
    return PeerJoinMessage(
      peerId: json['peerId'] as String,
      role: json['role'] as String,
      deviceInfo: json['deviceInfo'] as String? ?? 'unknown',
    );
  }
}

/// Peer 离开通知消息
class PeerLeaveMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.peerLeave;
  final String peerId;
  final String reason;

  PeerLeaveMessage({required this.peerId, this.reason = 'disconnect'});

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'peerId': peerId,
    'reason': reason,
  };

  factory PeerLeaveMessage.fromJson(Map<String, dynamic> json) {
    return PeerLeaveMessage(
      peerId: json['peerId'] as String,
      reason: json['reason'] as String? ?? 'disconnect',
    );
  }
}

/// 时钟同步消息
class ClockSyncMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.clockSync;
  final int epoch;
  final int seq;
  final int clientSendMs;
  int? clientRecvMs;
  int? serverRecvMs;
  int? serverSendMs;

  ClockSyncMessage({
    required this.epoch,
    required this.seq,
    required this.clientSendMs,
    this.clientRecvMs,
    this.serverRecvMs,
    this.serverSendMs,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'epoch': epoch,
    'seq': seq,
    'clientSendMs': clientSendMs,
    'clientRecvMs': clientRecvMs,
    'serverRecvMs': serverRecvMs,
    'serverSendMs': serverSendMs,
  };

  factory ClockSyncMessage.fromJson(Map<String, dynamic> json) {
    return ClockSyncMessage(
      epoch: json['epoch'] as int,
      seq: json['seq'] as int,
      clientSendMs: json['clientSendMs'] as int,
      clientRecvMs: json['clientRecvMs'] as int?,
      serverRecvMs: json['serverRecvMs'] as int?,
      serverSendMs: json['serverSendMs'] as int?,
    );
  }

  /// 计算 RTT（往返时间）
  int calculateRtt() {
    if (clientRecvMs == null || clientSendMs == 0) return 0;
    return clientRecvMs! - clientSendMs;
  }

  /// 计算时钟偏移
  int calculateOffset() {
    if (serverRecvMs == null || serverSendMs == null || clientRecvMs == null) {
      return 0;
    }
    final rtt = calculateRtt();
    return serverSendMs! - (clientSendMs + rtt ~/ 2);
  }
}

/// 播放状态消息
class PlaybackStateMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.playbackState;
  final String roomId;
  final String state; // 'playing' | 'paused' | 'stopped'
  final int positionMs;
  final double speed;
  final int timestampMs;

  const PlaybackStateMessage({
    required this.roomId,
    required this.state,
    required this.positionMs,
    required this.speed,
    required this.timestampMs,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'roomId': roomId,
    'state': state,
    'positionMs': positionMs,
    'speed': speed,
    'timestampMs': timestampMs,
  };

  factory PlaybackStateMessage.fromJson(Map<String, dynamic> json) {
    return PlaybackStateMessage(
      roomId: json['roomId'] as String,
      state: json['state'] as String,
      positionMs: json['positionMs'] as int,
      speed: (json['speed'] as num).toDouble(),
      timestampMs: json['timestampMs'] as int,
    );
  }
}

/// 从 JSON 中提取消息类型（支持多种封装结构）
/// 支持: {type}, {data:{type}}, {payload:{type}}
String? extractType(Map<String, dynamic> json) {
  // 直接顶层 type
  if (json['type'] is String) {
    return json['type'] as String;
  }
  // 嵌套在 data 中
  if (json['data'] is Map<String, dynamic>) {
    final data = json['data'] as Map<String, dynamic>;
    if (data['type'] is String) {
      return data['type'] as String;
    }
  }
  // 嵌套在 payload 中
  if (json['payload'] is Map<String, dynamic>) {
    final payload = json['payload'] as Map<String, dynamic>;
    if (payload['type'] is String) {
      return payload['type'] as String;
    }
  }
  return null;
}

/// 解析任意消息类型（强韧化版本）
SyncMessage? parseMessage(Map<String, dynamic> json) {
  final type = extractType(json);
  if (type == null) {
    return null; // 无法识别类型，返回 null 而不抛异常
  }

  try {
    switch (type) {
      case SyncProtocol.hello:
        return HelloMessage.fromJson(json);
      case SyncProtocol.welcome:
        return WelcomeMessage.fromJson(json);
      case SyncProtocol.ping:
        return PingMessage.fromJson(json);
      case SyncProtocol.pong:
        return PongMessage.fromJson(json);
      case SyncProtocol.peerJoin:
        return PeerJoinMessage.fromJson(json);
      case SyncProtocol.peerLeave:
        return PeerLeaveMessage.fromJson(json);
      case SyncProtocol.clockSync:
        return ClockSyncMessage.fromJson(json);
      case SyncProtocol.playbackState:
        return PlaybackStateMessage.fromJson(json);
      case SyncProtocol.trackAnnounce:
        return TrackAnnounceMessage.fromJson(json);
      case SyncProtocol.clientReady:
        return ClientReadyMessage.fromJson(json);
      case SyncProtocol.clientReadyError:
        return ClientReadyErrorMessage.fromJson(json);
      case SyncProtocol.startAt:
        return StartAtMessage.fromJson(json);
      case SyncProtocol.clientStartReport:
        return ClientStartReportMessage.fromJson(json);
      case SyncProtocol.hostState:
        return HostStateMessage.fromJson(json);
      default:
        return null;
    }
  } catch (e) {
    // 解析失败不崩溃，返回 null
    return null;
  }
}

/// 曲目公告消息（Host → Client）
class TrackAnnounceMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.trackAnnounce;
  final String roomId;
  final String hostPeerId;
  final String trackId;
  final String url; // http://{hostIp}:{httpPort}/track/{trackId}
  final String fileHash; // SHA1 或 xxhash
  final int sizeBytes;
  final int durationMs;
  final String? fileName;

  TrackAnnounceMessage({
    required this.roomId,
    required this.hostPeerId,
    required this.trackId,
    required this.url,
    required this.fileHash,
    required this.sizeBytes,
    required this.durationMs,
    this.fileName,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'roomId': roomId,
    'hostPeerId': hostPeerId,
    'trackId': trackId,
    'url': url,
    'fileHash': fileHash,
    'sizeBytes': sizeBytes,
    'durationMs': durationMs,
    if (fileName != null) 'fileName': fileName,
  };

  factory TrackAnnounceMessage.fromJson(Map<String, dynamic> json) {
    return TrackAnnounceMessage(
      roomId: json['roomId'] as String? ?? '',
      hostPeerId: json['hostPeerId'] as String? ?? '',
      trackId: json['trackId'] as String? ?? '',
      url: json['url'] as String? ?? '',
      fileHash: json['fileHash'] as String? ?? '',
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      durationMs: json['durationMs'] as int? ?? 0,
      fileName: json['fileName'] as String?,
    );
  }
}

/// Client 就绪消息（Client → Host）
class ClientReadyMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.clientReady;
  final String roomId;
  final String peerId;
  final String trackId;
  final bool cached;
  final String localPath;
  final int prepareMs; // 从收到公告到缓存完成的时间

  ClientReadyMessage({
    required this.roomId,
    required this.peerId,
    required this.trackId,
    required this.cached,
    required this.localPath,
    required this.prepareMs,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'roomId': roomId,
    'peerId': peerId,
    'trackId': trackId,
    'cached': cached,
    'localPath': localPath,
    'prepareMs': prepareMs,
  };

  factory ClientReadyMessage.fromJson(Map<String, dynamic> json) {
    return ClientReadyMessage(
      roomId: json['roomId'] as String,
      peerId: json['peerId'] as String,
      trackId: json['trackId'] as String,
      cached: json['cached'] as bool? ?? false,
      localPath: json['localPath'] as String,
      prepareMs: json['prepareMs'] as int? ?? 0,
    );
  }
}

/// Client 就绪错误消息（Client → Host）
class ClientReadyErrorMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.clientReadyError;
  final String roomId;
  final String peerId;
  final String trackId;
  final String
  errorCode; // download_failed / hash_mismatch / http_404 / timeout
  final String errorMessage;

  ClientReadyErrorMessage({
    required this.roomId,
    required this.peerId,
    required this.trackId,
    required this.errorCode,
    required this.errorMessage,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'roomId': roomId,
    'peerId': peerId,
    'trackId': trackId,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
  };

  factory ClientReadyErrorMessage.fromJson(Map<String, dynamic> json) {
    return ClientReadyErrorMessage(
      roomId: json['roomId'] as String? ?? '',
      peerId: json['peerId'] as String? ?? '',
      trackId: json['trackId'] as String? ?? '',
      errorCode: json['errorCode'] as String? ?? 'unknown',
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }
}

/// StartAt 消息（Host → All Clients）
/// 同起开播指令
class StartAtMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.startAt;
  final int epoch; // 版本号，每次 start 递增
  final int seq; // 序列号，同一 epoch 内递增
  final String trackId;
  final int startAtRoomTimeMs; // 目标启动时间（房间时间）
  final int startPosMs; // 起始播放位置

  StartAtMessage({
    required this.epoch,
    required this.seq,
    required this.trackId,
    required this.startAtRoomTimeMs,
    required this.startPosMs,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'epoch': epoch,
    'seq': seq,
    'trackId': trackId,
    'startAtRoomTimeMs': startAtRoomTimeMs,
    'startPosMs': startPosMs,
  };

  factory StartAtMessage.fromJson(Map<String, dynamic> json) {
    return StartAtMessage(
      epoch: json['epoch'] as int? ?? 0,
      seq: json['seq'] as int? ?? 0,
      trackId: json['trackId'] as String? ?? '',
      startAtRoomTimeMs: json['startAtRoomTimeMs'] as int? ?? 0,
      startPosMs: json['startPosMs'] as int? ?? 0,
    );
  }
}

/// ClientStartReport 消息（Client → Host）
/// 上报实际启动时间
class ClientStartReportMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.clientStartReport;
  final String peerId;
  final int epoch;
  final int seq;
  final int actualStartRoomTimeMs;
  final int startErrorMs; // actual - target，正数表示晚了

  ClientStartReportMessage({
    required this.peerId,
    required this.epoch,
    required this.seq,
    required this.actualStartRoomTimeMs,
    required this.startErrorMs,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'peerId': peerId,
    'epoch': epoch,
    'seq': seq,
    'actualStartRoomTimeMs': actualStartRoomTimeMs,
    'startErrorMs': startErrorMs,
  };

  factory ClientStartReportMessage.fromJson(Map<String, dynamic> json) {
    return ClientStartReportMessage(
      peerId: json['peerId'] as String? ?? '',
      epoch: json['epoch'] as int? ?? 0,
      seq: json['seq'] as int? ?? 0,
      actualStartRoomTimeMs: json['actualStartRoomTimeMs'] as int? ?? 0,
      startErrorMs: json['startErrorMs'] as int? ?? 0,
    );
  }
}

/// HostState 消息（Host → All Clients）
/// 广播 Host 当前播放状态，用于 Client 追帧
class HostStateMessage implements SyncMessage {
  @override
  final String type = SyncProtocol.hostState;
  final String roomId;
  final String trackId;
  final bool isPlaying;
  final int hostPosMs; // Host 当前播放位置
  final int sampledAtRoomTimeMs; // 采样时的房间时间
  final int epoch;
  final int seq;

  HostStateMessage({
    required this.roomId,
    required this.trackId,
    required this.isPlaying,
    required this.hostPosMs,
    required this.sampledAtRoomTimeMs,
    required this.epoch,
    required this.seq,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'roomId': roomId,
    'trackId': trackId,
    'isPlaying': isPlaying,
    'hostPosMs': hostPosMs,
    'sampledAtRoomTimeMs': sampledAtRoomTimeMs,
    'epoch': epoch,
    'seq': seq,
  };

  factory HostStateMessage.fromJson(Map<String, dynamic> json) {
    return HostStateMessage(
      roomId: json['roomId'] as String? ?? '',
      trackId: json['trackId'] as String? ?? '',
      isPlaying: json['isPlaying'] as bool? ?? false,
      hostPosMs: json['hostPosMs'] as int? ?? 0,
      sampledAtRoomTimeMs: json['sampledAtRoomTimeMs'] as int? ?? 0,
      epoch: json['epoch'] as int? ?? 0,
      seq: json['seq'] as int? ?? 0,
    );
  }
}
