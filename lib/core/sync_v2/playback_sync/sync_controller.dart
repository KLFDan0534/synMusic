import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';

import '../calibration/calibration_service.dart';
import '../diagnostics/sync_log.dart';
import '../diagnostics/sync_diagnostics.dart';
import '../diagnostics/sync_metrics.dart';
import '../diagnostics/throttled_notifier.dart';
import '../room_discovery/mdns_service.dart';
import '../room_discovery/discovered_room.dart';
import '../transport/transport_interface.dart';
import '../transport/websocket_transport.dart';
import '../transport/protocol.dart';
import '../clock/room_clock.dart';
import '../clock/clock_synchronizer.dart';
import '../distributor/audio_distributor.dart';
import '../distributor/audio_cache.dart';
import '../distributor/track_meta.dart';
import '../distributor/http_file_server.dart';
import '../utils/background_executor.dart';
import '../future_start/future_start_controller.dart';
import 'playback_synchronizer.dart';
import 'keep_sync_controller.dart';

/// 同步角色
enum SyncRole { none, host, client }

Future<bool> _writeTextFileIsolate(Map<String, String> args) async {
  final path = args['path'];
  final content = args['content'];
  if (path == null || content == null) return false;
  final file = File(path);
  await file.writeAsString(content);
  return true;
}

/// 同步状态
class SyncV2State {
  final SyncRole role;
  final String? roomId;
  final String? peerId;
  final SyncDiagnosticsData diagnostics;

  const SyncV2State({
    this.role = SyncRole.none,
    this.roomId,
    this.peerId,
    required this.diagnostics,
  });
}

/// 同步控制器
/// 统一管理所有同步模块的 Facade
class SyncV2Controller {
  // 单例
  static final SyncV2Controller _instance = SyncV2Controller._internal();
  factory SyncV2Controller() => _instance;
  SyncV2Controller._internal();

  // 模块实例
  late final MdnsService _mdnsService;
  late final WebSocketTransport _transport;
  late final RoomClock _clock;
  late final ClockSynchronizer _clockSync;
  late final AudioDistributor _distributor;
  late final AudioCache _cache;
  late final HttpFileServer _httpFileServer;
  late final BackgroundExecutor _executor;
  late final FutureStartController _futureStart;
  late final PlaybackSynchronizer _playbackSync;
  late final SyncDiagnostics _diagnostics;
  late final ThrottledDiagnosticsNotifier _throttledNotifier;
  late final ThrottledLogNotifier _logNotifier;
  late final KeepSyncController _keepSync;
  late final SyncMetricsCollector _metrics;
  late final CalibrationService _calibration;

  // 当前角色
  SyncRole _role = SyncRole.none;
  String? _roomId;
  String? _peerId;

  // 曲目状态
  TrackState _trackState = const TrackState();
  final _trackStateController = StreamController<TrackState>.broadcast();

  // 下载进度
  // ignore: unused_field
  StreamSubscription<DownloadProgress>? _downloadProgressSub;

  // 状态订阅
  StreamSubscription<TransportState>? _transportStateSub;
  StreamSubscription<TransportMessage>? _transportMessageSub;

  // 心跳 RTT
  int _lastPingRtt = 0;

  // Client 播放器
  AudioPlayer? _player;
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  // ignore: unused_field
  StreamSubscription<Duration>? _positionSub;
  // ignore: unused_field
  StreamSubscription<PlayerState>? _playerStateSub;

  // seek 后冷却期（跳过 host_state 处理直到 position 更新）
  int _lastSeekAtMs = 0;
  int _lastSeekTargetMs = 0;

  // Host 播放器（播放本地 MP3）
  AudioPlayer? _hostPlayer;

  // FutureStart epoch 管理
  int _epoch = 0;
  int _seq = 0;
  int _leadMs = 1500; // 默认提前量

  // FutureStart 状态
  FutureStartState _futureStartState = FutureStartState.idle;
  int _startAtRoomTimeMs = 0;
  int _actualStartRoomTimeMs = 0;
  int _startErrorMs = 0;

  // Host 状态广播
  Timer? _hostStateTimer;
  int _hostStateSeq = 0;

  // Client 追帧状态
  HostStateMessage? _latestHostState;
  int _catchUpDoneEpoch = -1; // 已追帧的 epoch
  bool _catchUpInFlight = false; // 正在追帧中
  int _lastCatchUpAttemptAtMs = 0; // 上次尝试追帧的时间

  // 追帧条件状态
  bool _hasHostStatePlaying = false; // 收到 isPlaying=true 的 host_state
  bool _trackReadyForCatchUp = false; // 曲目已缓存就绪
  bool _clockLockedForCatchUp = false; // 时钟已锁定

  // 状态流
  final _stateController = StreamController<SyncV2State>.broadcast();

  /// 当前角色
  SyncRole get role => _role;

  /// 当前房间 ID
  String? get roomId => _roomId;

  /// 当前 Peer ID
  String? get peerId => _peerId;

  /// 状态流
  Stream<SyncV2State> get stateStream => _stateController.stream;

  /// 当前状态
  SyncV2State get state => SyncV2State(
    role: _role,
    roomId: _roomId,
    peerId: _peerId,
    diagnostics: _diagnostics.data,
  );

  /// 发现的房间列表
  List<DiscoveredRoom> get discoveredRooms => _mdnsService.rooms;

  /// 房间列表流
  Stream<List<DiscoveredRoom>> get roomsStream => _mdnsService.roomsStream;

  /// 诊断数据（节流后，UI 使用）
  SyncDiagnosticsData get diagnostics => _throttledNotifier.data;

  /// 节流诊断通知器（UI 监听此 notifier）
  ThrottledDiagnosticsNotifier get throttledNotifier => _throttledNotifier;

  /// 节流日志通知器（UI 监听此 notifier）
  ThrottledLogNotifier get logNotifier => _logNotifier;

  /// 指标收集器
  SyncMetricsCollector get metrics => _metrics;

  /// 校准服务
  CalibrationService get calibration => _calibration;

  /// Host 本机 IP（供热点环境手动输入）
  String get hostLocalIp => _httpFileServer.localIp;

  /// 诊断数据流
  Stream<SyncDiagnosticsData> get diagnosticsStream => _diagnostics.stream;

  /// Transport 日志
  List<String> get transportLogs => _transport.transportLogs;

  /// 连接状态
  TransportState get connectionState => _transport.state;

  /// 连接状态流
  Stream<TransportState> get connectionStateStream => _transport.stateStream;

  /// 已连接的 peer 数量
  int get peerCount => _transport.connectedPeers.length;

  // ==================== RoomClock 属性 ====================

  /// 当前房间时间（毫秒）
  int get roomNowMs => _clock.roomNowMs;

  /// 原始偏移（最近一次样本）
  int get offsetRawMs => _clock.offsetRawMs;

  /// EMA 平滑后的偏移
  int get offsetEmaMs => _clock.offsetEmaMs;

  /// 最近一次 RTT
  int get rttMs => _clock.rttMs;

  /// Jitter（网络抖动）
  int get jitterMs => _clock.jitterMs;

  /// 是否已锁定（时钟同步稳定）
  bool get isClockLocked => _clock.isLocked;

  /// 样本计数
  int get clockSampleCount => _clock.sampleCount;

  /// EMA alpha 值
  double get emaAlpha => _clock.emaAlpha;

  // ==================== FutureStart 属性 ====================

  /// FutureStart 状态
  FutureStartState get futureStartState => _futureStartState;

  /// 目标启动时间
  int get startAtRoomTimeMs => _startAtRoomTimeMs;

  /// 实际启动时间
  int get actualStartRoomTimeMs => _actualStartRoomTimeMs;

  /// 启动误差
  int get startErrorMs => _startErrorMs;

  /// 提前量（ms）
  int get leadMs => _leadMs;
  set leadMs(int value) {
    if (value >= 800 && value <= 3000) {
      _leadMs = value;
    }
  }

  /// FutureStart 状态流
  Stream<FutureStartState> get futureStartStateStream =>
      _futureStart.stateStream;

  /// 重置时钟
  void resetClock({bool keepHistory = false}) {
    _clockSync.reset(keepHistory: keepHistory);
  }

  /// 设置 EMA alpha 值
  void setEmaAlpha(double alpha) {
    _clockSync.setEmaAlpha(alpha);
  }

  /// 进入后台模式
  void enterBackground() {
    if (_role == SyncRole.client) {
      _clockSync.enterBackground();
    }
  }

  /// 恢复前台模式
  void enterForeground() {
    if (_role == SyncRole.client) {
      _clockSync.enterForeground();
    }
  }

  /// 初始化
  Future<void> init() async {
    _mdnsService = MdnsService();
    _transport = WebSocketTransport();
    _clock = RoomClock();
    _clockSync = ClockSynchronizer(clock: _clock, transport: _transport);
    _distributor = AudioDistributor();
    _cache = AudioCache();
    _httpFileServer = HttpFileServer();
    _executor = BackgroundExecutor();
    _futureStart = FutureStartController(clock: _clock);
    _playbackSync = PlaybackSynchronizer(clock: _clock);
    _diagnostics = SyncDiagnostics();
    _throttledNotifier = ThrottledDiagnosticsNotifier(throttleIntervalMs: 250);
    _logNotifier = ThrottledLogNotifier(throttleIntervalMs: 500);
    _keepSync = KeepSyncController(
      config: Platform.isIOS ? KeepSyncConfig.iosSafe : const KeepSyncConfig(),
    );
    _metrics = SyncMetricsCollector();
    _calibration = CalibrationService();

    // 初始化校准服务
    _calibration.initialize();

    // 监听 Transport 状态变化
    _transportStateSub = _transport.stateStream.listen(
      _onTransportStateChanged,
    );

    // 监听 Transport 消息
    _transportMessageSub = _transport.messageStream.listen(_onTransportMessage);

    // 监听 Transport 日志并转发到节流日志通知器
    _transport.logStream.listen((log) {
      _logNotifier.addLog(log);
    });

    // 监听下载进度
    _downloadProgressSub = _cache.progressStream.listen(_onDownloadProgress);

    SyncLog.i('SyncV2Controller 初始化完成');
  }

  void setKeepSyncConfig(KeepSyncConfig config) {
    _keepSync.updateConfig(config);
    SyncLog.i('[KeepSync] config_updated: $config', role: _role.name);
  }

  void setIosSafeMode(bool enabled) {
    if (!Platform.isIOS) return;
    setKeepSyncConfig(
      enabled ? KeepSyncConfig.iosSafe : const KeepSyncConfig(),
    );
  }

  bool get isIosSafeMode {
    if (!Platform.isIOS) return false;
    final c = _keepSync.config;
    final s = KeepSyncConfig.iosSafe;
    return c.speedIntervalMs == s.speedIntervalMs &&
        c.speedMin == s.speedMin &&
        c.speedMax == s.speedMax &&
        c.maxSpeedStepPerUpdate == s.maxSpeedStepPerUpdate;
  }

  String buildDebugBundleText({int maxLines = 800}) {
    final sb = StringBuffer();
    sb.writeln('=== SyncMusic Debug Bundle ===');
    sb.writeln('exportedAt: ${DateTime.now().toIso8601String()}');
    sb.writeln('role: ${_role.name}');
    sb.writeln('roomId: ${_roomId ?? "-"}');
    sb.writeln('peerId: ${_peerId ?? "-"}');
    sb.writeln('platform: ${Platform.operatingSystem}');
    sb.writeln('');
    sb.writeln('--- Diagnostics ---');
    sb.writeln(_diagnostics.data.toFormattedString());
    sb.writeln('');
    sb.writeln('--- Metrics (samples json, last 120s) ---');
    sb.writeln(_metrics.exportSamplesJson());
    sb.writeln('');
    sb.writeln(
      '--- Transport logs (last ${_transport.transportLogs.length}) ---',
    );
    for (final l in _transport.transportLogs) {
      sb.writeln(l);
    }
    sb.writeln('');
    sb.writeln('--- SyncLog buffer (last $maxLines) ---');
    final lines = SyncLog.bufferedLines;
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    for (final l in lines.sublist(start)) {
      sb.writeln(l);
    }
    return sb.toString();
  }

  Future<String> exportDebugBundleToFile() async {
    final dir = await getTemporaryDirectory();
    final filePath =
        '${dir.path}/sync_debug_${DateTime.now().millisecondsSinceEpoch}.txt';
    final content = buildDebugBundleText();
    await _executor.runCpuTask(_writeTextFileIsolate, {
      'path': filePath,
      'content': content,
    });
    SyncLog.i('[Export] debug_bundle_written: $filePath');
    return filePath;
  }

  void clearDebugLogs() {
    SyncLog.clearBuffer();
    _logNotifier.clear();
    SyncLog.i('[Export] logs_cleared');
  }

  void _onTransportStateChanged(TransportState state) {
    final stateStr = state.toString().split('.').last;
    _throttledNotifier.updatePartial(connectionState: stateStr);

    if (state == TransportState.connected && _role == SyncRole.client) {
      // 连接成功后发送 hello
      _sendHello();
    }

    if (state == TransportState.hosting) {
      _throttledNotifier.updatePartial(connectionState: 'hosting');
    }
  }

  void _onTransportMessage(TransportMessage message) {
    final msg = parseMessage(message.payload);
    if (msg == null) return;

    switch (msg.type) {
      case SyncProtocol.pong:
        final pong = msg as PongMessage;
        final t2ClientMs = DateTime.now().millisecondsSinceEpoch;
        _lastPingRtt = t2ClientMs - pong.t0ClientMs;
        _throttledNotifier.updatePartial(
          lastPingRtt: _lastPingRtt,
          reconnectCount: _transport.reconnectCount,
        );
        break;

      case SyncProtocol.peerJoin:
        // Host 广播的 peer 加入通知
        _throttledNotifier.updatePartial(peerCount: peerCount);

        // 如果是 Host 且有当前曲目，发送 track_announce 给新 Client
        if (_role == SyncRole.host) {
          final joinMsg = msg as PeerJoinMessage;
          SyncLog.i(
            '[Host] 新成员加入: peerId=${joinMsg.peerId}, 有曲目=${_trackState.meta != null}, HTTP服务运行中=${_httpFileServer.isRunning}',
            role: 'host',
          );
          if (_trackState.meta != null) {
            _sendTrackAnnounceToPeer(joinMsg.peerId);
          }
        }
        break;

      case SyncProtocol.peerLeave:
        _throttledNotifier.updatePartial(peerCount: peerCount);
        break;

      case SyncProtocol.trackAnnounce:
        // Client 收到曲目公告，触发下载
        if (_role == SyncRole.client) {
          final announce = msg as TrackAnnounceMessage;
          _onTrackAnnounce(announce);
        }
        break;

      case SyncProtocol.clientReady:
        // Host 收到 Client 就绪通知
        if (_role == SyncRole.host) {
          final ready = msg as ClientReadyMessage;
          SyncLog.i(
            '[Host] Client 就绪: ${ready.peerId}, 已缓存=${ready.cached}',
            role: 'host',
          );
        }
        break;

      case SyncProtocol.clientReadyError:
        // Host 收到 Client 错误通知
        if (_role == SyncRole.host) {
          final error = msg as ClientReadyErrorMessage;
          SyncLog.e(
            '[Host] Client 错误: ${error.peerId}, 错误码=${error.errorCode}',
            role: 'host',
          );
        }
        break;

      case SyncProtocol.startAt:
        // Client 收到同起开播指令
        if (_role == SyncRole.client) {
          final startAt = msg as StartAtMessage;
          _onStartAt(startAt);
        }
        break;

      case SyncProtocol.clientStartReport:
        // Host 收到 Client 启动报告
        if (_role == SyncRole.host) {
          final report = msg as ClientStartReportMessage;
          SyncLog.i(
            '[Host] Client 启动报告: peer=${report.peerId}, 误差=${report.startErrorMs}ms',
            role: 'host',
          );
        }
        break;

      case SyncProtocol.hostState:
        // Client 收到 Host 状态广播
        if (_role == SyncRole.client) {
          final hostState = msg as HostStateMessage;
          _onHostState(hostState);
        }
        break;
    }
  }

  /// Client 收到曲目公告
  Future<void> _onTrackAnnounce(TrackAnnounceMessage announce) async {
    SyncLog.i(
      '[Client] 收到 track_announce: trackId=${announce.trackId}, url=${announce.url}, 大小=${announce.sizeBytes}',
      role: 'client',
    );

    // 检查 URL 是否有效
    if (announce.url.isEmpty) {
      SyncLog.e('[Client] track_announce URL 为空!', role: 'client');
      _trackState = TrackState(
        status: TrackStatus.error,
        error: 'Invalid track URL',
      );
      _trackStateController.add(_trackState);
      return;
    }

    // 检查是否已经是当前曲目且已缓存
    if (_trackState.meta?.trackId == announce.trackId &&
        _trackState.status == TrackStatus.serving &&
        _trackState.meta?.localPath.isNotEmpty == true) {
      SyncLog.i('[Client] 曲目已缓存（当前曲目）: ${announce.trackId}', role: 'client');
      // 重新发送 ready 消息
      final readyMsg = ClientReadyMessage(
        roomId: announce.roomId,
        peerId: _peerId!,
        trackId: announce.trackId,
        cached: true,
        localPath: _trackState.meta!.localPath,
        prepareMs: 0,
      );
      _transport.send(
        TransportMessage.create(readyMsg.type, readyMsg.toJson()),
      );
      return;
    }

    // 检查本地缓存目录中是否已有该曲目
    final cachedTracks = await _cache.getCachedTracks();
    final existingCache = cachedTracks
        .where(
          (t) =>
              t.trackId == announce.trackId ||
              t.localPath.contains(announce.trackId),
        )
        .toList();

    if (existingCache.isNotEmpty) {
      final cached = existingCache.first;
      SyncLog.i(
        '[Client] 曲目已在本地缓存: ${announce.trackId} path=${cached.localPath}',
        role: 'client',
      );

      // 更新曲目状态
      _trackState = TrackState(
        status: TrackStatus.serving,
        meta: TrackMeta(
          trackId: announce.trackId,
          localPath: cached.localPath,
          fileName: announce.fileName,
          sizeBytes: announce.sizeBytes,
          durationMs: announce.durationMs,
          fileHash: announce.fileHash,
          createdAt: DateTime.now(),
        ),
      );
      _trackStateController.add(_trackState);

      // 发送 ready 消息
      final readyMsg = ClientReadyMessage(
        roomId: announce.roomId,
        peerId: _peerId!,
        trackId: announce.trackId,
        cached: true,
        localPath: cached.localPath,
        prepareMs: 0,
      );
      _transport.send(
        TransportMessage.create(readyMsg.type, readyMsg.toJson()),
      );

      SyncLog.i(
        '[Client] 已发送 client_ready（使用缓存）: ${announce.trackId}',
        role: 'client',
      );

      // 曲目就绪，检查是否需要追帧
      _onTrackReadyForCatchUp();
      return;
    }

    // 更新曲目状态
    _trackState = TrackState(
      status: TrackStatus.announcing,
      meta: TrackMeta(
        trackId: announce.trackId,
        localPath: '', // 还未下载
        fileName: announce.fileName,
        sizeBytes: announce.sizeBytes,
        durationMs: announce.durationMs,
        fileHash: announce.fileHash,
        createdAt: DateTime.now(),
      ),
    );
    _trackStateController.add(_trackState);

    // 开始下载
    final result = await _cache.downloadAndCache(
      trackId: announce.trackId,
      url: announce.url,
      expectedHash: announce.fileHash,
      expectedSize: announce.sizeBytes,
    );

    // 发送结果给 Host
    if (result.success) {
      final readyMsg = ClientReadyMessage(
        roomId: announce.roomId,
        peerId: _peerId!,
        trackId: announce.trackId,
        cached: true,
        localPath: result.localPath!,
        prepareMs: result.prepareMs,
      );
      _transport.send(
        TransportMessage.create(readyMsg.type, readyMsg.toJson()),
      );

      SyncLog.i(
        '[Client] 已发送 client_ready: ${announce.trackId}',
        role: 'client',
      );

      _trackState = TrackState(
        status: TrackStatus.serving,
        meta: _trackState.meta!.copyWith(localPath: result.localPath!),
      );
      _trackStateController.add(_trackState);

      // 曲目就绪，检查是否需要追帧
      _onTrackReadyForCatchUp();

      // 预先初始化播放器（减少 start_at 时的准备时间）
      await _preInitPlayer(result.localPath!);
    } else {
      final errorMsg = ClientReadyErrorMessage(
        roomId: announce.roomId,
        peerId: _peerId!,
        trackId: announce.trackId,
        errorCode: result.errorCode ?? 'unknown',
        errorMessage: result.errorMessage ?? 'Unknown error',
      );
      _transport.send(
        TransportMessage.create(errorMsg.type, errorMsg.toJson()),
      );

      SyncLog.e(
        '[Client] 已发送 client_ready_error: ${result.errorCode}',
        role: 'client',
      );

      _trackState = TrackState(
        status: TrackStatus.error,
        error: result.errorMessage,
      );
    }
    _trackStateController.add(_trackState);
  }

  /// 预先初始化播放器（Client 缓存完成后调用）
  Future<void> _preInitPlayer(String localPath) async {
    try {
      if (_player == null) {
        _player = AudioPlayer();
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      }
      await _player!.setFilePath(localPath);
      SyncLog.i('[Client] 播放器预初始化: $localPath', role: 'client');
    } catch (e) {
      SyncLog.w('[Client] 播放器预初始化失败: $e', role: 'client');
    }
  }

  /// Client 收到同起开播指令
  Future<void> _onStartAt(StartAtMessage startAt) async {
    SyncLog.i(
      '[Client] 收到 start_at: epoch=${startAt.epoch} seq=${startAt.seq} T=${startAt.startAtRoomTimeMs} trackId=${startAt.trackId}',
      role: 'client',
    );

    // 检查曲目是否已缓存
    final trackId = startAt.trackId;
    final localPath = _trackState.meta?.localPath;

    if (localPath == null || _trackState.meta?.trackId != trackId) {
      SyncLog.e('[Client] start_at: 曲目未缓存', role: 'client');
      _futureStartState = FutureStartState.failed;
      return;
    }

    _startAtRoomTimeMs = startAt.startAtRoomTimeMs;

    // 使用 FutureStartController 执行两段式等待
    await _futureStart.schedule(
      params: FutureStartParams(
        epoch: startAt.epoch,
        seq: startAt.seq,
        trackId: trackId,
        startAtRoomTimeMs: startAt.startAtRoomTimeMs,
        startPosMs: startAt.startPosMs,
      ),
      onPrepare: (params) async {
        // 准备：播放器已预初始化，只需确认状态
        _futureStartState = FutureStartState.preparing;

        try {
          // 播放器应该已经预初始化了
          if (_player == null) {
            // 兜底：如果未初始化，快速初始化
            _player = AudioPlayer();
            final session = await AudioSession.instance;
            await session.configure(const AudioSessionConfiguration.music());
            await _player!.setFilePath(localPath);
          }
          // 如果已初始化，无需重新加载文件（已在 _preInitPlayer 中加载）

          if (params.startPosMs > 0) {
            await _player!.seek(Duration(milliseconds: params.startPosMs));
          }
          return FutureStartResult(success: true);
        } catch (e) {
          SyncLog.e('[Client] FutureStart 准备失败: $e', role: 'client');
          _futureStartState = FutureStartState.failed;
          return FutureStartResult(success: false, failReason: e.toString());
        }
      },
      onStart: (params) {
        // 执行播放
        _player?.play();

        _actualStartRoomTimeMs = _futureStart.actualStartRoomTimeMs;
        _startErrorMs = _futureStart.startErrorMs;
        _futureStartState = FutureStartState.started;

        SyncLog.i(
          '[Client] FutureStart 已启动: 实际=$_actualStartRoomTimeMs 误差=$_startErrorMs',
          role: 'client',
        );

        // 上报给 Host
        final report = ClientStartReportMessage(
          peerId: _peerId!,
          epoch: params.epoch,
          seq: params.seq,
          actualStartRoomTimeMs: _actualStartRoomTimeMs,
          startErrorMs: _startErrorMs,
        );
        _transport.send(TransportMessage.create(report.type, report.toJson()));
      },
    );
  }

  /// Client 收到 Host 状态广播
  void _onHostState(HostStateMessage hostState) {
    // 更新最新 Host 状态
    _latestHostState = hostState;

    // 更新条件状态
    final wasPlaying = _hasHostStatePlaying;
    _hasHostStatePlaying = hostState.isPlaying;

    SyncLog.i(
      '[Client] 收到 host_state: isPlaying=${hostState.isPlaying} pos=${hostState.hostPosMs}ms epoch=${hostState.epoch}',
      role: 'client',
    );

    // 从暂停恢复播放时，重置追帧 gate，允许重新追帧
    if (!wasPlaying && hostState.isPlaying) {
      _catchUpDoneEpoch = -1;
      SyncLog.i('[CatchUp] 恢复播放，重置追帧 gate', role: 'client');
      _maybeTriggerCatchUp();
    }

    // 执行 KeepSync 持续同步
    _runKeepSync(hostState);
  }

  /// 执行 KeepSync 持续同步
  void _runKeepSync(HostStateMessage hostState) {
    if (_player == null || _trackState.meta == null) return;

    final roomNowMs = _clock.roomNowMs;
    final clientPosMs = _player!.position.inMilliseconds;

    // seek 后冷却期检查（等待 player position 更新）
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final seekCooldownActive = (nowMs - _lastSeekAtMs < 800);
    if (seekCooldownActive && _lastSeekTargetMs > 0) {
      // 检查 player position 是否已更新到目标附近
      final posDelta = (clientPosMs - _lastSeekTargetMs).abs();
      if (posDelta > 300) {
        // position 还没更新，跳过本次处理
        SyncLog.d(
          '[KeepSync] seek 冷却期: pos=$clientPosMs target=$_lastSeekTargetMs delta=$posDelta ms',
          role: 'client',
        );
        return;
      }
      // position 已更新，清除冷却期
      _lastSeekAtMs = 0;
      _lastSeekTargetMs = 0;
    }

    final decision = _keepSync.decide(
      isPlaying: hostState.isPlaying,
      epoch: hostState.epoch,
      trackId: hostState.trackId,
      hostPosMs: hostState.hostPosMs,
      sampledAtRoomTimeMs: hostState.sampledAtRoomTimeMs,
      roomNowMs: roomNowMs,
      clientPosMs: clientPosMs,
      durationMs: _trackState.meta!.durationMs,
      latencyCompMs: _calibration.totalCompensationMs,
      isClockLocked: _clock.isLocked,
      jitterMs: _diagnostics.data.jitterMs,
      rttMs: _diagnostics.data.rttMs,
    );

    // 记录样本到指标收集器
    _metrics.record(
      tsRoomNowMs: roomNowMs,
      deltaMs: decision.deltaMs,
      audiblePosMs: clientPosMs,
      targetPosMs: decision.targetPosMs,
      rttMs: _diagnostics.data.rttMs,
      jitterMs: _diagnostics.data.jitterMs,
      speed: _keepSync.currentSpeed,
      action: decision.action.name,
    );

    // 诊断日志：确认指标记录
    if (decision.action != KeepSyncAction.noop) {
      SyncLog.d(
        '[Metrics] 记录: delta=${decision.deltaMs} pos=$clientPosMs action=${decision.action.name}',
        role: 'client',
      );
    }

    // 记录 drop 原因
    if (decision.reason != null && decision.action == KeepSyncAction.noop) {
      _metrics.recordDrop(decision.reason!);
    }

    // 更新诊断数据
    _diagnostics.updatePartial(
      keepSyncEnabled: _keepSync.enabled,
      keepSyncDeltaMs: decision.deltaMs,
      keepSyncPredictedDeltaMs: decision.predictedDeltaMs,
      keepSyncTargetPosMs: decision.targetPosMs,
      keepSyncClientPosMs: decision.clientPosMs,
      keepSyncSpeed: _keepSync.currentSpeed,
      keepSyncSpeedEma: _keepSync.speedEma,
      keepSyncSpeedCmd: decision.speedCmd,
      keepSyncHoldRemainingMs: decision.holdRemainingMs,
      keepSyncLastAction: decision.action.name,
      keepSyncSeekCount: _keepSync.seekCount,
      keepSyncSpeedSetCount: _keepSync.speedSetCount,
      keepSyncDroppedCount: _keepSync.droppedHostStateCount,
      keepSyncDroppedReason: _keepSync.lastDroppedReason,
      keepSyncReason: decision.reason,
    );

    // 检查保护模式
    final protectMode = _metrics.protectMode;

    // 执行决策（保护模式下限制）
    switch (decision.action) {
      case KeepSyncAction.noop:
        break;
      case KeepSyncAction.speed:
        if (Platform.isIOS) {
          SyncLog.i(
            '[KeepSync] iOS 禁止 speed 调整（避免追快追慢）: speed=${decision.speed} delta=${decision.deltaMs}',
            role: 'client',
          );
          break;
        }
        // 保护模式下检查是否允许速度调整
        if (protectMode == ProtectMode.protect) {
          // 保护模式下使用更保守的速度范围
          final clampedSpeed = decision.speed!.clamp(0.985, 1.015);
          _player!.setSpeed(clampedSpeed);
          SyncLog.i('[KeepSync] 设置速度（保护模式）: $clampedSpeed', role: 'client');
        } else {
          _player!.setSpeed(decision.speed!);
          SyncLog.i('[KeepSync] 设置速度: ${decision.speed}', role: 'client');
        }
      case KeepSyncAction.seek:
        // 保护模式下禁止小偏移 seek（除非 > 2000ms）
        if (protectMode == ProtectMode.protect &&
            decision.deltaMs.abs() < 2000) {
          SyncLog.w(
            '[KeepSync] 保护模式禁止 seek: delta=${decision.deltaMs}ms',
            role: 'client',
          );
        } else {
          // 记录 seek 时间和目标，用于冷却期检查
          _lastSeekAtMs = DateTime.now().millisecondsSinceEpoch;
          _lastSeekTargetMs = decision.seekMs!;
          _player!.seek(Duration(milliseconds: decision.seekMs!));
          SyncLog.i('[KeepSync] 跳转: ${decision.seekMs}ms', role: 'client');
        }
    }
  }

  /// 检查条件并可能触发追帧
  void _maybeTriggerCatchUp() {
    // 更新条件状态
    _trackReadyForCatchUp =
        _trackState.status == TrackStatus.serving &&
        _trackState.meta?.localPath.isNotEmpty == true;
    _clockLockedForCatchUp = _clock.isLocked;

    SyncLog.i(
      '[CatchUp] maybeTrigger: hostPlaying=$_hasHostStatePlaying trackReady=$_trackReadyForCatchUp clockLocked=$_clockLockedForCatchUp',
      role: 'client',
    );

    // 三条件同时满足才触发
    if (_hasHostStatePlaying &&
        _trackReadyForCatchUp &&
        _clockLockedForCatchUp) {
      _tryCatchUp();
    }
  }

  /// 尝试追帧（三重 gate）
  void _tryCatchUp() {
    if (_latestHostState == null) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final epoch = _latestHostState!.epoch;

    // Gate 1: 已在追帧中
    if (_catchUpInFlight) {
      SyncLog.d('[CatchUp] Gate 阻止: 正在追帧', role: 'client');
      return;
    }

    // Gate 2: 同一 epoch 已追帧
    if (_catchUpDoneEpoch == epoch) {
      SyncLog.d('[CatchUp] Gate 阻止: epoch $epoch 已追帧', role: 'client');
      return;
    }

    // Gate 3: 1.5 秒内已尝试过
    if (nowMs - _lastCatchUpAttemptAtMs < 1500) {
      SyncLog.d('[CatchUp] Gate 阻止: 太频繁', role: 'client');
      return;
    }

    // 通过 gate，标记尝试时间
    _lastCatchUpAttemptAtMs = nowMs;

    // 立即标记 in-flight 和 done（防止并发）
    _catchUpInFlight = true;
    _catchUpDoneEpoch = epoch;

    // 异步执行追帧
    _performCatchUp(_latestHostState!).whenComplete(() {
      _catchUpInFlight = false;
    });
  }

  /// 曲目缓存完成时检查是否需要追帧
  void _onTrackReadyForCatchUp() {
    _trackReadyForCatchUp = true;
    _maybeTriggerCatchUp();
  }

  /// 时钟锁定时检查是否需要追帧
  void _onClockLockedForCatchUp() {
    _clockLockedForCatchUp = true;
    _maybeTriggerCatchUp();
  }

  /// 执行追帧（使用未来时刻精确播放）
  Future<void> _performCatchUp(HostStateMessage hostState) async {
    final localPath = _trackState.meta!.localPath;
    final durationMs = _trackState.meta!.durationMs;
    final latencyCompMs = _calibration.totalCompensationMs;

    // 计算未来播放时刻（当前时间 + 准备时间）
    const prepareMs = 300; // 预留 300ms 准备时间
    final targetRoomTimeMs = _clock.roomNowMs + prepareMs;

    // 计算在该时刻 Host 将会到达的位置
    // hostPosMs + (targetRoomTimeMs - sampledAtRoomTimeMs) - latencyCompMs
    final hostFuturePosMs =
        hostState.hostPosMs +
        (targetRoomTimeMs - hostState.sampledAtRoomTimeMs) -
        latencyCompMs;
    final clampedPosMs = hostFuturePosMs.clamp(0, durationMs);

    SyncLog.i(
      '[CatchUp] hostPosMs=${hostState.hostPosMs} 采样时间=${hostState.sampledAtRoomTimeMs} 目标房间时间=$targetRoomTimeMs hostFuturePosMs=$hostFuturePosMs 延迟补偿=$latencyCompMs',
    );

    try {
      // 确保播放器已初始化
      if (_player == null) {
        _player = AudioPlayer();
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      }

      // 预加载并 seek 到目标位置
      await _player!.setFilePath(localPath);
      await _player!.seek(Duration(milliseconds: clampedPosMs));

      // 等待到目标时刻再播放
      final nowRoomMs = _clock.roomNowMs;
      final waitMs = targetRoomTimeMs - nowRoomMs;

      if (waitMs > 0) {
        SyncLog.i('[CatchUp] 等待 ${waitMs}ms 后在房间时间=$targetRoomTimeMs 播放');
        await Future.delayed(Duration(milliseconds: waitMs));
      }

      _player!.play();

      if (Platform.isIOS) {
        await _player!.setSpeed(1.0);
      }

      // 标记追帧完成
      _catchUpDoneEpoch = hostState.epoch;

      final actualStartRoomMs = _clock.roomNowMs;
      final startErrorMs = actualStartRoomMs - targetRoomTimeMs;

      // 更新诊断数据
      _diagnostics.updatePartial(
        lastHostStateAtRoomTimeMs: hostState.sampledAtRoomTimeMs,
        lastHostPosMs: hostState.hostPosMs,
        computedTargetPosMs: clampedPosMs,
        catchUpPerformed: true,
        catchUpDeltaMs: startErrorMs,
      );

      SyncLog.i(
        '[CatchUp] 成功: seekMs=$clampedPosMs 启动误差=$startErrorMs latencyComp=$latencyCompMs',
        role: 'client',
      );
    } catch (e) {
      SyncLog.e('[CatchUp] 失败: $e', role: 'client');
    }
  }

  /// 手动触发追帧（用于测试）
  Future<bool> manualCatchUp() async {
    if (_latestHostState == null) {
      SyncLog.w('[CatchUp] 尚未收到 host_state', role: 'client');
      return false;
    }

    // 检查条件
    _trackReadyForCatchUp =
        _trackState.status == TrackStatus.serving &&
        _trackState.meta?.localPath.isNotEmpty == true;
    _clockLockedForCatchUp = _clock.isLocked;

    if (!_trackReadyForCatchUp) {
      SyncLog.w('[CatchUp] 无法追帧: 曲目未就绪', role: 'client');
      return false;
    }
    if (!_clockLockedForCatchUp) {
      SyncLog.w('[CatchUp] 无法追帧: 时钟未锁定', role: 'client');
      return false;
    }

    // 临时重置 epoch 以允许手动触发
    _catchUpDoneEpoch = -1;
    _catchUpInFlight = false;

    await _performCatchUp(_latestHostState!);
    return true;
  }

  void _sendHello() {
    if (_roomId == null || _peerId == null) return;

    _transport.sendHello(
      roomId: _roomId!,
      peerId: _peerId!,
      deviceInfo: 'Flutter Client',
    );

    SyncLog.i('已发送 hello', role: 'client', roomId: _roomId);
  }

  void _onDownloadProgress(DownloadProgress progress) {
    _trackStateController.add(_trackState);
  }

  // ==================== Host 曲目管理 ====================

  /// 曲目状态流
  Stream<TrackState> get trackStateStream => _trackStateController.stream;

  /// 当前曲目状态
  TrackState get trackState => _trackState;

  /// 选择 MP3 文件（Host）
  Future<bool> selectMp3File(String filePath) async {
    if (_role != SyncRole.host) return false;

    _trackState = const TrackState(status: TrackStatus.selecting);
    _trackStateController.add(_trackState);

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _trackState = TrackState(
          status: TrackStatus.error,
          error: 'File not found: $filePath',
        );
        _trackStateController.add(_trackState);
        return false;
      }

      // 获取文件大小
      final sizeBytes = await file.length();

      // 计算 hash（在 isolate 中）
      _trackState = const TrackState(status: TrackStatus.hashing);
      _trackStateController.add(_trackState);

      final fileHash = await _executor.computeFileSha1(filePath);

      // 生成 trackId
      final trackId = TrackMeta.generateTrackId(fileHash);

      // 使用 AudioPlayer 获取音频时长
      int durationMs = 0;
      try {
        final tempPlayer = AudioPlayer();
        await tempPlayer.setFilePath(filePath);
        durationMs = tempPlayer.duration?.inMilliseconds ?? 0;
        await tempPlayer.dispose();
        SyncLog.i('[Host] Got audio duration: ${durationMs}ms', role: 'host');
      } catch (e) {
        SyncLog.w('[Host] Failed to get audio duration: $e', role: 'host');
      }

      // 创建曲目元数据
      final trackMeta = TrackMeta(
        trackId: trackId,
        localPath: filePath,
        fileName: filePath.split('/').last,
        sizeBytes: sizeBytes,
        durationMs: durationMs,
        fileHash: fileHash,
        createdAt: DateTime.now(),
      );

      _trackState = TrackState(status: TrackStatus.ready, meta: trackMeta);
      _trackStateController.add(_trackState);

      SyncLog.i(
        '[Host] MP3 selected: $trackId, size=$sizeBytes, hash=$fileHash',
        role: 'host',
      );

      // 自动开始分发曲目
      final serving = await startServingTrack();
      if (!serving) {
        SyncLog.w('[Host] 自动分发曲目失败', role: 'host');
      }

      return true;
    } catch (e) {
      _trackState = TrackState(status: TrackStatus.error, error: e.toString());
      _trackStateController.add(_trackState);
      return false;
    }
  }

  /// 启动 HTTP 文件服务并广播曲目（Host）
  Future<bool> startServingTrack() async {
    if (_role != SyncRole.host || _trackState.meta == null) {
      SyncLog.e(
        '[Host] startServingTrack: role=$_role, meta=${_trackState.meta}',
      );
      return false;
    }

    final meta = _trackState.meta!;
    SyncLog.i(
      '[Host] startServingTrack: trackId=${meta.trackId}, localPath=${meta.localPath}, size=${meta.sizeBytes}',
      role: 'host',
    );

    // 启动 HTTP 文件服务器
    final started = await _httpFileServer.start(track: meta);
    if (!started) {
      _trackState = TrackState(
        status: TrackStatus.error,
        meta: meta,
        error: 'Failed to start HTTP server',
      );
      _trackStateController.add(_trackState);
      return false;
    }

    // 获取 serviceUrl 并检查
    final serviceUrl = _httpFileServer.serviceUrl;
    SyncLog.i(
      '[Host] HTTP server started, serviceUrl=$serviceUrl',
      role: 'host',
    );

    if (serviceUrl.isEmpty) {
      SyncLog.e(
        '[Host] serviceUrl is empty after HTTP server started!',
        role: 'host',
      );
      _trackState = TrackState(
        status: TrackStatus.error,
        meta: meta,
        error: 'serviceUrl is empty',
      );
      _trackStateController.add(_trackState);
      return false;
    }

    _trackState = TrackState(status: TrackStatus.serving, meta: meta);
    _trackStateController.add(_trackState);

    // 广播曲目公告
    final announce = TrackAnnounceMessage(
      roomId: _roomId!,
      hostPeerId: _peerId!,
      trackId: meta.trackId,
      url: serviceUrl,
      fileHash: meta.fileHash,
      sizeBytes: meta.sizeBytes,
      durationMs: meta.durationMs,
      fileName: meta.fileName,
    );

    SyncLog.i(
      '[Host] Broadcasting track_announce: trackId=${announce.trackId}, url=${announce.url}, size=${announce.sizeBytes}',
      role: 'host',
    );

    _transport.broadcast(
      TransportMessage.create(announce.type, announce.toJson()),
    );

    return true;
  }

  /// 向指定 Client 发送曲目公告（新 Client 加入时调用）
  void _sendTrackAnnounceToPeer(String clientPeerId) {
    if (_trackState.meta == null) return;

    final meta = _trackState.meta!;
    final serviceUrl = _httpFileServer.serviceUrl;
    if (serviceUrl.isEmpty) return;

    final announce = TrackAnnounceMessage(
      roomId: _roomId!,
      hostPeerId: _peerId!,
      trackId: meta.trackId,
      url: serviceUrl,
      fileHash: meta.fileHash,
      sizeBytes: meta.sizeBytes,
      durationMs: meta.durationMs,
      fileName: meta.fileName,
    );

    SyncLog.i(
      '[Host] Sending track_announce to new client: $clientPeerId, trackId=${announce.trackId}',
      role: 'host',
    );

    _transport.sendToPeer(
      clientPeerId,
      TransportMessage.create(announce.type, announce.toJson()),
    );
  }

  /// 停止曲目服务（Host）
  Future<void> stopServingTrack() async {
    await _httpFileServer.stop();
    _trackState = const TrackState();
    _trackStateController.add(_trackState);
  }

  // ==================== FutureStart 同起开播 ====================

  /// Host 发起 FutureStart 同起开播
  /// 条件：已选择 track、HTTP server running
  Future<bool> startAtFuture() async {
    SyncLog.i('[Host] startAtFuture called, role=$_role', role: 'host');

    if (_role != SyncRole.host) {
      SyncLog.e('[Host] startAtFuture: not host role');
      return false;
    }

    if (_trackState.meta == null) {
      SyncLog.e(
        '[Host] startAtFuture: no track selected, status=${_trackState.status}',
      );
      return false;
    }

    SyncLog.i(
      '[Host] startAtFuture: trackId=${_trackState.meta!.trackId}, httpRunning=${_httpFileServer.isRunning}',
    );

    if (!_httpFileServer.isRunning) {
      SyncLog.e('[Host] startAtFuture: HTTP server not running');
      return false;
    }

    // Host 作为时钟源，不需要检查 isClockLocked

    // 递增 epoch 和 seq
    _epoch++;
    _seq = 0;

    final trackId = _trackState.meta!.trackId;
    final startAtRoomTimeMs = _clock.roomNowMs + _leadMs;
    const startPosMs = 0;

    _startAtRoomTimeMs = startAtRoomTimeMs;
    _futureStartState = FutureStartState.waiting;

    SyncLog.i(
      '[Host] FutureStart: epoch=$_epoch seq=$_seq T=$startAtRoomTimeMs leadMs=$_leadMs',
      role: 'host',
    );

    // 广播 start_at 消息
    final message = StartAtMessage(
      epoch: _epoch,
      seq: _seq,
      trackId: trackId,
      startAtRoomTimeMs: startAtRoomTimeMs,
      startPosMs: startPosMs,
    );

    _transport.broadcast(
      TransportMessage.create(message.type, message.toJson()),
    );

    // Host 自己也执行 FutureStart
    await _executeHostFutureStart(
      trackId: trackId,
      startAtRoomTimeMs: startAtRoomTimeMs,
      startPosMs: startPosMs,
    );

    return true;
  }

  /// Host 执行 FutureStart（播放本地 MP3）
  Future<void> _executeHostFutureStart({
    required String trackId,
    required int startAtRoomTimeMs,
    required int startPosMs,
  }) async {
    // 准备：初始化并加载播放器
    _futureStartState = FutureStartState.preparing;

    final localPath = _trackState.meta!.localPath;
    try {
      // 初始化播放器（如果尚未初始化）
      if (_hostPlayer == null) {
        _hostPlayer = AudioPlayer();
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      }

      await _hostPlayer!.setFilePath(localPath);
      if (startPosMs > 0) {
        await _hostPlayer!.seek(Duration(milliseconds: startPosMs));
      }
    } catch (e) {
      SyncLog.e('[Host] FutureStart prepare failed: $e', role: 'host');
      _futureStartState = FutureStartState.failed;
      return;
    }

    SyncLog.i('[Host] FutureStart prepared: $trackId', role: 'host');

    // 两段式等待 - 重新计算剩余时间
    _futureStartState = FutureStartState.waiting;
    const fineWaitMs = 80;
    final nowAfterPrepareMs = _clock.roomNowMs;
    final remainingWaitMs = startAtRoomTimeMs - nowAfterPrepareMs;

    if (remainingWaitMs <= 0) {
      // 时间已过，立即启动
      SyncLog.w(
        '[Host] FutureStart target time passed during prepare',
        role: 'host',
      );
      _actualStartRoomTimeMs = _clock.roomNowMs;
      _startErrorMs = _actualStartRoomTimeMs - startAtRoomTimeMs;
      _futureStartState = FutureStartState.started;
      _hostPlayer?.play();
      return;
    }

    final coarseWaitMs = remainingWaitMs - fineWaitMs;

    Timer? coarseTimer;
    Timer? fineTimer;

    void executeStart() {
      coarseTimer?.cancel();
      fineTimer?.cancel();

      _actualStartRoomTimeMs = _clock.roomNowMs;
      _startErrorMs = _actualStartRoomTimeMs - startAtRoomTimeMs;
      _futureStartState = FutureStartState.started;

      SyncLog.i(
        '[Host] FutureStart started: actual=$_actualStartRoomTimeMs errorMs=$_startErrorMs',
        role: 'host',
      );

      _hostPlayer?.play();

      // 启动 Host 状态广播
      _startHostStateBroadcast();

      // 短暂延迟后回到 idle
      Timer(const Duration(seconds: 2), () {
        _futureStartState = FutureStartState.idle;
      });
    }

    void enterFineWait() {
      fineTimer = Timer.periodic(const Duration(milliseconds: 2), (timer) {
        final remainingMs = startAtRoomTimeMs - _clock.roomNowMs;
        if (remainingMs <= 0) {
          timer.cancel();
          executeStart();
        }
      });
    }

    if (coarseWaitMs > 0) {
      coarseTimer = Timer(Duration(milliseconds: coarseWaitMs), enterFineWait);
    } else {
      enterFineWait();
    }
  }

  // ==================== Client 下载管理 ====================

  /// 启动 Host 状态广播（每 200ms）
  void _startHostStateBroadcast() {
    _hostStateTimer?.cancel();
    _hostStateSeq = 0;

    _hostStateTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _broadcastHostState();
    });

    SyncLog.i('[Host] Started host_state broadcast', role: 'host');
  }

  /// 停止 Host 状态广播
  void _stopHostStateBroadcast() {
    _hostStateTimer?.cancel();
    _hostStateTimer = null;
    SyncLog.i('[Host] Stopped host_state broadcast', role: 'host');
  }

  /// 广播 Host 状态
  void _broadcastHostState() {
    if (_role != SyncRole.host || _hostPlayer == null) return;

    final isPlaying = _hostPlayer!.playing;
    final hostPosMs = _hostPlayer!.position.inMilliseconds;
    final sampledAtRoomTimeMs = _clock.roomNowMs;

    final message = HostStateMessage(
      roomId: _roomId ?? '',
      trackId: _trackState.meta?.trackId ?? '',
      isPlaying: isPlaying,
      hostPosMs: hostPosMs,
      sampledAtRoomTimeMs: sampledAtRoomTimeMs,
      epoch: _epoch,
      seq: _hostStateSeq++,
    );

    _transport.broadcast(
      TransportMessage.create(message.type, message.toJson()),
    );

    SyncLog.d(
      '[Host] Broadcast host_state: isPlaying=$isPlaying pos=$hostPosMs sampledAt=$sampledAtRoomTimeMs',
      role: 'host',
    );
  }

  // ==================== Client 下载管理 ====================

  /// 下载并缓存曲目（Client）
  Future<DownloadResult> downloadTrack({
    required String trackId,
    required String url,
    required String expectedHash,
    required int expectedSize,
  }) async {
    return await _cache.downloadAndCache(
      trackId: trackId,
      url: url,
      expectedHash: expectedHash,
      expectedSize: expectedSize,
    );
  }

  /// 获取下载进度
  DownloadProgress get downloadProgress => _cache.currentProgress;

  /// 获取下载进度流
  Stream<DownloadProgress> get cacheProgressStream => _cache.progressStream;

  /// 清除曲目缓存
  Future<void> clearTrackCache(String trackId) async {
    await _cache.clearCache();
    await _stopPlayer();
    _trackState = const TrackState();
    _trackStateController.add(_trackState);
  }

  /// 获取已缓存的曲目列表
  Future<List<CachedTrack>> getCachedTracks() async {
    return await _cache.getCachedTracks();
  }

  // ==================== Client 播放器 ====================

  /// 播放缓存文件
  Future<bool> playCachedTrack(String localPath) async {
    if (_role != SyncRole.client) {
      SyncLog.w('[Client] playCachedTrack: not client role');
      return false;
    }

    try {
      // 初始化播放器
      if (_player == null) {
        _player = AudioPlayer();

        // 配置 audio session
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());

        // 监听 position
        _positionSub = _player!.positionStream.listen((position) {
          _positionController.add(position);
        });

        // 监听 player state
        _playerStateSub = _player!.playerStateStream.listen((state) {
          _playerStateController.add(state);
        });
      }

      // 停止当前播放
      await _player!.stop();

      // 设置文件路径并播放
      final duration = await _player!.setFilePath(localPath);
      SyncLog.i(
        '[Client] Playing cached track: $localPath, duration: $duration',
      );
      await _player!.play();
      return true;
    } catch (e, s) {
      SyncLog.e(
        '[Client] playCachedTrack failed: $localPath',
        error: e,
        stackTrace: s,
      );
      return false;
    }
  }

  /// 暂停播放
  Future<void> pausePlayer() async {
    await _player?.pause();
  }

  /// 继续播放
  Future<void> resumePlayer() async {
    await _player?.play();
  }

  /// 停止播放
  Future<void> _stopPlayer() async {
    await _player?.stop();
  }

  /// 播放状态流
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  /// 播放位置流
  Stream<Duration> get positionStream => _positionController.stream;

  /// 当前播放状态
  PlayerState? get playerState => _player?.playerState;

  /// 当前播放位置
  Duration? get position => _player?.position;

  /// 当前播放时长
  Duration? get duration => _player?.duration ?? _hostPlayer?.duration;

  // ==================== 统一播放控制 ====================

  /// 播放（Host 播放本地 MP3，Client 播放缓存文件）
  Future<bool> play() async {
    if (_role == SyncRole.host) {
      return await _hostPlay();
    } else if (_role == SyncRole.client) {
      await resumePlayer();
      return _player?.playing ?? false;
    }
    return false;
  }

  /// 暂停
  Future<void> pause() async {
    if (_role == SyncRole.host) {
      await _hostPlayer?.pause();
    } else if (_role == SyncRole.client) {
      await _player?.pause();
    }
  }

  /// Seek 到指定位置（用于模拟偏移测试）
  /// [deltaMs] 偏移量，正数向前跳，负数向后跳
  Future<void> seek(int deltaMs) async {
    final player = _role == SyncRole.host ? _hostPlayer : _player;
    if (player == null) {
      SyncLog.w('[Seek] No player available', role: _role.name);
      return;
    }

    final currentPos = player.position.inMilliseconds;
    final duration = player.duration?.inMilliseconds ?? 0;
    final targetPos = (currentPos + deltaMs).clamp(0, duration);

    SyncLog.i(
      '[Seek] delta=$deltaMs ms, current=$currentPos ms -> target=$targetPos ms',
      role: _role.name,
    );

    await player.seek(Duration(milliseconds: targetPos));

    // 记录 seek 时间（用于 Client 冷却期检查）
    if (_role == SyncRole.client) {
      _lastSeekAtMs = DateTime.now().millisecondsSinceEpoch;
      _lastSeekTargetMs = targetPos;
    }
  }

  /// Host 播放本地 MP3
  Future<bool> _hostPlay() async {
    if (_role != SyncRole.host) return false;

    final meta = _trackState.meta;
    if (meta == null) {
      SyncLog.w('[Host] No track selected');
      return false;
    }

    try {
      // 初始化播放器
      if (_hostPlayer == null) {
        _hostPlayer = AudioPlayer();

        // 配置 audio session
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      }

      // 如果正在播放，继续播放
      if (_hostPlayer!.playing) {
        return true;
      }

      // 如果已加载文件，继续播放
      if (_hostPlayer!.duration != null) {
        await _hostPlayer!.play();
        return true;
      }

      // 加载文件并播放
      final duration = await _hostPlayer!.setFilePath(meta.localPath);
      SyncLog.i(
        '[Host] Playing local track: ${meta.localPath}, duration: $duration',
      );
      await _hostPlayer!.play();
      return true;
    } catch (e, s) {
      SyncLog.e('[Host] _hostPlay failed', error: e, stackTrace: s);
      return false;
    }
  }

  /// 是否正在播放
  bool get isPlaying {
    if (_role == SyncRole.host) {
      return _hostPlayer?.playing ?? false;
    } else if (_role == SyncRole.client) {
      return _player?.playing ?? false;
    }
    return false;
  }

  // ==================== Host 操作 ====================

  /// 创建房间（Host）
  Future<bool> createRoom({
    required String roomName,
    int wsPort = 8765,
    int httpPort = 8080,
    bool autoSelectTrack = true, // 自动选择最近曲目
  }) async {
    if (_role != SyncRole.none) {
      SyncLog.w('Already in a room', role: 'host');
      return false;
    }

    _roomId = 'room_${DateTime.now().millisecondsSinceEpoch}';
    _peerId = 'host_${DateTime.now().millisecondsSinceEpoch}';
    _role = SyncRole.host;

    // 发布 mDNS 服务
    final published = await _mdnsService.publishRoom(
      roomId: _roomId!,
      roomName: roomName,
      wsPort: wsPort,
      httpPort: httpPort,
      appVersion: '1.0.0',
    );

    if (!published) {
      _role = SyncRole.none;
      _roomId = null;
      _peerId = null;
      return false;
    }

    // 启动 WebSocket 服务器
    await _transport.startServer(wsPort);

    // 启动 HTTP 分发服务
    await _distributor.start(port: httpPort);

    // 初始化时钟 epoch
    _clock.newEpoch();

    _updateState();

    SyncLog.i('Room created', role: 'host', roomId: _roomId);

    _throttledNotifier.updatePartial(
      role: 'host',
      roomId: _roomId,
      peerId: _peerId,
      state: 'hosting',
      connectionState: 'hosting',
    );

    // 自动选择最近曲目
    if (autoSelectTrack) {
      await _autoSelectRecentTrack();
    }

    return true;
  }

  /// 自动选择最近曲目（Host 创建房间后）
  Future<bool> _autoSelectRecentTrack() async {
    try {
      final cachedTracks = await _cache.getCachedTracks();
      if (cachedTracks.isNotEmpty) {
        final recent = cachedTracks.first; // 已按时间排序
        SyncLog.i(
          '[Host] 自动选择最近曲目: ${recent.trackId} path=${recent.localPath}',
          role: 'host',
        );
        return await selectMp3File(recent.localPath);
      }
    } catch (e) {
      SyncLog.w('[Host] 自动选择曲目失败: $e', role: 'host');
    }
    return false;
  }

  /// 关闭房间（Host）
  Future<void> closeRoom() async {
    if (_role != SyncRole.host) return;

    await _mdnsService.unpublishRoom();
    await _transport.stopServer();
    await _distributor.stop();

    _role = SyncRole.none;
    _roomId = null;
    _peerId = null;

    _updateState();
    _throttledNotifier.reset();

    SyncLog.i('Room closed', role: 'host');
  }

  /// 设置音源（Host）
  Future<bool> setAudioSource(String filePath) async {
    if (_role != SyncRole.host) return false;

    final info = await _distributor.registerSource(
      sourceId: 'main',
      filePath: filePath,
    );

    return info != null;
  }

  // ==================== Client 操作 ====================

  /// 开始扫描房间
  Future<void> startScanning() async {
    await _mdnsService.startScanning();
    _throttledNotifier.updatePartial(state: 'discovering');
  }

  /// 停止扫描房间
  Future<void> stopScanning() async {
    await _mdnsService.stopScanning();
    if (_role == SyncRole.none) {
      _throttledNotifier.updatePartial(state: 'idle');
    }
  }

  /// 加入房间（Client）
  Future<bool> joinRoom(DiscoveredRoom room) async {
    if (_role != SyncRole.none) {
      SyncLog.w('Already in a room', role: 'client');
      return false;
    }

    _roomId = room.roomId;
    _peerId = 'client_${DateTime.now().millisecondsSinceEpoch}';
    _role = SyncRole.client;

    _throttledNotifier.updatePartial(
      role: 'client',
      roomId: _roomId,
      peerId: _peerId,
      state: 'joining',
      connectionState: 'connecting',
    );

    // 连接到 Host
    try {
      await _transport.connect(room.hostIp, room.hostWsPort);
      // hello 消息会在连接成功后自动发送
    } catch (e, s) {
      SyncLog.e('Failed to join room', role: 'client', error: e, stackTrace: s);
      _role = SyncRole.none;
      _roomId = null;
      _peerId = null;
      _throttledNotifier.updatePartial(
        state: 'error',
        errorMessage: e.toString(),
      );
      return false;
    }

    // 开始时钟同步
    _clockSync.startSyncing();

    // 监听时钟锁定事件
    _clock.lockStream.listen((isLocked) {
      if (isLocked) {
        _onClockLockedForCatchUp();
      }
    });

    _updateState();

    SyncLog.i('Joined room', role: 'client', roomId: _roomId);

    _throttledNotifier.updatePartial(state: 'syncing');

    return true;
  }

  /// 离开房间（Client）
  Future<void> leaveRoom() async {
    if (_role != SyncRole.client) return;

    _clockSync.stopSyncing();
    _playbackSync.stopSync();
    await _transport.disconnect();

    _role = SyncRole.none;
    _roomId = null;
    _peerId = null;

    _updateState();
    _throttledNotifier.reset();

    SyncLog.i('Left room', role: 'client');
  }

  /// 手动断开连接
  Future<void> disconnect() async {
    if (_role == SyncRole.client) {
      await _transport.disconnect();
    }
  }

  /// 手动触发重连
  Future<void> triggerReconnect() async {
    await _transport.triggerReconnect();
  }

  /// 手动输入 Host IP 加入（fallback 方案）
  Future<bool> joinByIp(String hostIp, int wsPort) async {
    // 创建临时房间信息
    final tempRoom = DiscoveredRoom(
      roomId: 'manual_${DateTime.now().millisecondsSinceEpoch}',
      roomName: 'Manual Join',
      hostIp: hostIp,
      hostWsPort: wsPort,
      hostHttpPort: 8080,
      appVersion: '1.0.0',
      codec: 'mp3',
      discoveredAt: DateTime.now(),
    );

    return joinRoom(tempRoom);
  }

  // ==================== 播放同步操作 ====================

  /// 开始播放同步
  void startPlaybackSync({
    void Function(int positionMs)? onSeek,
    void Function(double speed)? onSpeedChange,
    int Function()? onGetPosition,
  }) {
    if (_role != SyncRole.client) return;

    _playbackSync.setCallbacks(
      onSeek: onSeek,
      onSpeedChange: onSpeedChange,
      onGetPosition: onGetPosition,
    );
    _playbackSync.startSync();
  }

  /// 停止播放同步
  void stopPlaybackSync() {
    _playbackSync.stopSync();
  }

  /// 校准延迟
  void calibrateLatency(int latencyMs) {
    _playbackSync.calibrateLatency(latencyMs);
  }

  // ==================== 诊断操作 ====================

  /// 获取诊断数据字符串
  String getDiagnosticsString() {
    return _diagnostics.data.toFormattedString();
  }

  void _updateState() {
    _stateController.add(state);
  }

  /// 释放资源
  void dispose() {
    _transportStateSub?.cancel();
    _transportMessageSub?.cancel();
    _stopHostStateBroadcast();
    closeRoom();
    leaveRoom();
    _mdnsService.dispose();
    _transport.dispose();
    _clockSync.dispose();
    _futureStart.dispose();
    _playbackSync.dispose();
    _keepSync.dispose();
    _diagnostics.dispose();
    _stateController.close();
  }

  // ==================== KeepSync 控制 ====================

  /// 设置 KeepSync 启用状态
  void setKeepSyncEnabled(bool enabled) {
    _keepSync.setEnabled(enabled);
    SyncLog.i('[KeepSync] ${enabled ? "Enabled" : "Disabled"}', role: 'client');
  }

  /// KeepSync 是否启用
  bool get keepSyncEnabled => _keepSync.enabled;
}
