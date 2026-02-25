import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/sync_v2/playback_sync/sync_controller.dart';
import '../../core/sync_v2/room_discovery/discovered_room.dart';
import '../../core/sync_v2/transport/transport_interface.dart';
import '../../core/sync_v2/distributor/track_meta.dart';
import '../../core/sync_v2/distributor/audio_cache.dart';
import '../../core/sync_v2/future_start/future_start_controller.dart';
import '../../core/sync_v2/diagnostics/sync_diagnostics.dart';
import '../../core/sync_v2/diagnostics/sync_metrics.dart';

/// 延迟元素（用于延迟分解面板）
class _LatencyItem {
  final String name;
  final int valueMs;
  final String impact; // high, medium, low, info
  final String description;

  const _LatencyItem({
    required this.name,
    required this.valueMs,
    required this.impact,
    required this.description,
  });
}

/// Sync Lab 页面 - 同步实验室
/// 提供完整的同步测试和诊断功能
class SyncLabPage extends StatefulWidget {
  const SyncLabPage({super.key});

  @override
  State<SyncLabPage> createState() => _SyncLabPageState();
}

class _SyncLabPageState extends State<SyncLabPage> {
  final SyncV2Controller _controller = SyncV2Controller();

  String? _lastExportPath;

  // 手动输入 IP 控制器
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '8765');

  // 延迟校准控制器
  final _latencyController = TextEditingController(text: '0');

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
    _latencyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Lab / 同步实验室'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 连接状态区块
          _buildConnectionSection(),
          const Divider(),

          // 角色选择
          _buildRoleSection(),
          const Divider(),

          // 房间控制
          _buildRoomControlSection(),
          const Divider(),

          // 房间列表（Client）
          if (_controller.role == SyncRole.none ||
              _controller.role == SyncRole.client)
            _buildRoomListSection(),
          const Divider(),

          // 音源控制（Host）
          if (_controller.role == SyncRole.host) _buildAudioSourceSection(),
          const Divider(),

          // Client 曲目卡片
          if (_controller.role == SyncRole.client) _buildClientTrackSection(),
          const Divider(),

          // 播放控制
          _buildPlaybackControlSection(),
          const Divider(),

          // 同步控制
          _buildSyncControlSection(),
          const Divider(),

          // 校准按钮
          _buildCalibrationSection(),
          const Divider(),

          // FutureStart 同起开播
          _buildFutureStartSection(),
          const Divider(),

          // Catch-up 追帧（Client）
          if (_controller.role == SyncRole.client) _buildCatchUpSection(),
          const Divider(),

          // KeepSync 持续同步（Client）
          if (_controller.role == SyncRole.client) _buildKeepSyncSection(),
          const Divider(),

          // 延迟分解面板（Client）
          if (_controller.role == SyncRole.client)
            _buildLatencyBreakdownSection(),
          const Divider(),

          // 指标面板（Client）
          if (_controller.role == SyncRole.client) _buildMetricsSection(),
          const Divider(),

          // Clock 区块
          _buildClockSection(),
          const Divider(),

          // 诊断面板
          _buildDiagnosticsPanel(),
        ],
      ),
    );
  }

  /// 连接状态区块
  Widget _buildConnectionSection() {
    final connState = _controller.connectionState;
    final connStateStr = _connectionStateToString(connState);
    final peerCount = _controller.peerCount;
    final diag = _controller.diagnostics;

    // 根据状态选择颜色
    Color stateColor;
    switch (connState) {
      case TransportState.connected:
        stateColor = Colors.green;
        break;
      case TransportState.hosting:
        stateColor = Colors.blue;
        break;
      case TransportState.connecting:
        stateColor = Colors.orange;
        break;
      case TransportState.error:
        stateColor = Colors.red;
        break;
      default:
        stateColor = Colors.grey;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '连接状态',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: stateColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '状态: $connStateStr',
                  style: TextStyle(
                    fontSize: 16,
                    color: stateColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            Text('已连接 Peer 数量: $peerCount'),
            Text('心跳 RTT: ${diag.lastPingRtt}ms'),
            Text('重连次数: ${diag.reconnectCount}'),

            // Host 显示本机 IP（热点环境手动输入用）
            if (_controller.role == SyncRole.host) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '本机 IP: ${_controller.hostLocalIp}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '端口: 8765',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Text(
                      '热点环境请告知 Client 手动输入此 IP',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // 断开/重连按钮
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed:
                      _controller.role == SyncRole.client &&
                          connState == TransportState.connected
                      ? () => _disconnect()
                      : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开连接'),
                ),
                ElevatedButton.icon(
                  onPressed:
                      _controller.role == SyncRole.client &&
                          connState == TransportState.disconnected
                      ? () => _triggerReconnect()
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新连接'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _connectionStateToString(TransportState state) {
    switch (state) {
      case TransportState.disconnected:
        return 'disconnected';
      case TransportState.connecting:
        return 'connecting';
      case TransportState.connected:
        return 'connected';
      case TransportState.hosting:
        return 'hosting';
      case TransportState.error:
        return 'error';
    }
  }

  /// 角色选择区块
  Widget _buildRoleSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '角色选择',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _controller.role == SyncRole.none
                        ? () => _createRoom()
                        : null,
                    icon: const Icon(Icons.router),
                    label: const Text('Host'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _controller.role == SyncRole.none
                        ? () => _startScanning()
                        : null,
                    icon: const Icon(Icons.devices),
                    label: const Text('Client'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('当前角色: ${_controller.role.name}'),
          ],
        ),
      ),
    );
  }

  /// 房间控制区块
  Widget _buildRoomControlSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '房间控制',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (_controller.role == SyncRole.host) ...[
              Text('房间 ID: ${_controller.roomId ?? "未创建"}'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => _closeRoom(),
                child: const Text('关闭房间'),
              ),
            ],
            if (_controller.role == SyncRole.client) ...[
              Text('已加入房间: ${_controller.roomId ?? "未加入"}'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => _leaveRoom(),
                child: const Text('离开房间'),
              ),
            ],
            if (_controller.role == SyncRole.none) ...[const Text('请先选择角色')],
          ],
        ),
      ),
    );
  }

  /// 房间列表区块
  Widget _buildRoomListSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '发现的房间',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '提示: 热点环境下 mDNS 可能无法发现，请使用手动输入 IP',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),

            // 扫描按钮
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _startScanning(),
                  icon: const Icon(Icons.search),
                  label: const Text('扫描房间'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _stopScanning(),
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 房间列表
            StreamBuilder<List<DiscoveredRoom>>(
              stream: _controller.roomsStream,
              builder: (context, snapshot) {
                final rooms = snapshot.data ?? _controller.discoveredRooms;
                if (rooms.isEmpty) {
                  return const Text('未发现房间');
                }
                return Column(
                  children: rooms
                      .map(
                        (room) => ListTile(
                          title: Text(room.roomName),
                          subtitle: Text('${room.hostIp}:${room.hostWsPort}'),
                          trailing: ElevatedButton(
                            onPressed: () => _joinRoom(room),
                            child: const Text('加入'),
                          ),
                        ),
                      )
                      .toList(),
                );
              },
            ),

            const SizedBox(height: 16),
            const Divider(),
            const Text('手动输入 IP 加入（Fallback）'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _ipController,
                    decoration: const InputDecoration(
                      labelText: 'Host IP',
                      hintText: '192.168.1.100',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: '端口',
                      hintText: '8765',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _joinByIp(),
                  child: const Text('加入'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 音源控制区块（Host）
  Widget _buildAudioSourceSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '音源控制（Host）',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // 选择 MP3 按钮
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _selectMp3File(),
                  icon: const Icon(Icons.audio_file),
                  label: const Text('选择 MP3 文件'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _useDemoAudio(),
                  icon: const Icon(Icons.music_note),
                  label: const Text('使用 Demo 音频'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 曲目状态
            StreamBuilder<TrackState>(
              stream: _controller.trackStateStream,
              initialData: _controller.trackState,
              builder: (context, snapshot) {
                final state = snapshot.data!;
                return _buildTrackStateUI(state);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 构建曲目状态 UI
  Widget _buildTrackStateUI(TrackState state) {
    switch (state.status) {
      case TrackStatus.idle:
        return const Text('当前音源: 未选择');

      case TrackStatus.selecting:
        return const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('选择中...'),
          ],
        );

      case TrackStatus.hashing:
        return const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('计算 Hash 中...'),
          ],
        );

      case TrackStatus.ready:
        final meta = state.meta!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('曲目已就绪:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('trackId: ${meta.trackId}'),
            Text('文件名: ${meta.fileName ?? "未知"}'),
            Text('大小: ${meta.formattedSize}'),
            Text('时长: ${meta.formattedDuration}'),
            Text('Hash: ${meta.fileHash.substring(0, 16)}...'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => _startServingTrack(),
              icon: const Icon(Icons.cloud_upload),
              label: const Text('开始分发'),
            ),
          ],
        );

      case TrackStatus.serving:
        final meta = state.meta!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '正在分发:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 8),
            Text('trackId: ${meta.trackId}'),
            Text('HTTP 端口: 8787'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => _stopServingTrack(),
              icon: const Icon(Icons.stop),
              label: const Text('停止分发'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
          ],
        );

      case TrackStatus.error:
        return Text('错误: ${state.error}', style: TextStyle(color: Colors.red));

      default:
        return const Text('未知状态');
    }
  }

  /// Client 曲目卡片区块
  Widget _buildClientTrackSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '曲目缓存（Client）',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // 曲目状态
            StreamBuilder<TrackState>(
              stream: _controller.trackStateStream,
              initialData: _controller.trackState,
              builder: (context, snapshot) {
                final state = snapshot.data!;
                return _buildClientTrackStateUI(state);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 构建 Client 曲目状态 UI
  Widget _buildClientTrackStateUI(TrackState state) {
    switch (state.status) {
      case TrackStatus.idle:
        return const Text('等待曲目公告...');

      case TrackStatus.announcing:
        final meta = state.meta;
        if (meta == null) return const Text('收到公告，准备下载...');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('收到曲目: ${meta.trackId}'),
            Text('大小: ${meta.formattedSize}'),
            const SizedBox(height: 8),
            const Text('准备下载...'),
          ],
        );

      case TrackStatus.selecting:
      case TrackStatus.hashing:
        // Client 端下载中显示进度
        return _buildDownloadProgressUI();

      case TrackStatus.serving:
        // 下载完成，可以播放
        final meta = state.meta!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '缓存完成',
              style: TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text('trackId: ${meta.trackId}'),
            Text('本地路径: ${meta.localPath}'),
            const SizedBox(height: 12),

            // 播放控制
            _buildPlayerControls(),

            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => _clearCache(meta.trackId),
              icon: const Icon(Icons.delete),
              label: const Text('清除缓存'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
          ],
        );

      case TrackStatus.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('错误: ${state.error}', style: TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => _retryDownload(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        );

      default:
        return Text('状态: ${state.status}');
    }
  }

  /// 构建下载进度 UI
  Widget _buildDownloadProgressUI() {
    final progress = _controller.downloadProgress;
    if (progress.status == DownloadStatus.idle) {
      return const Text('下载中...');
    }

    final percent = progress.totalBytes > 0
        ? (progress.progress * 100).toStringAsFixed(1)
        : '0.0';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('下载中: $percent%'),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: progress.totalBytes > 0 ? progress.progress : null,
        ),
        const SizedBox(height: 8),
        Text(progress.formattedProgress),
        if (progress.status == DownloadStatus.verifying)
          const Text('正在校验 Hash...', style: TextStyle(color: Colors.orange)),
      ],
    );
  }

  /// 构建播放控制 UI
  Widget _buildPlayerControls() {
    final playerState = _controller.playerState;
    final isPlaying = playerState?.playing ?? false;
    final position = _controller.position ?? Duration.zero;
    final duration = _controller.duration ?? Duration.zero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 播放/暂停按钮
        Row(
          children: [
            ElevatedButton.icon(
              onPressed: isPlaying
                  ? () => _pausePlayer()
                  : () => _resumePlayer(),
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
              label: Text(isPlaying ? '暂停' : '播放'),
            ),
            const SizedBox(width: 8),
            if (!isPlaying && duration == Duration.zero)
              ElevatedButton.icon(
                onPressed: () {
                  final meta = _controller.trackState.meta;
                  if (meta != null) {
                    _playCachedFile(meta.localPath);
                  }
                },
                icon: const Icon(Icons.play_circle),
                label: const Text('开始播放'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // 播放进度
        if (duration > Duration.zero)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: duration.inMilliseconds > 0
                    ? position.inMilliseconds / duration.inMilliseconds
                    : 0,
              ),
              const SizedBox(height: 4),
              Text(
                '${_formatDuration(position)} / ${_formatDuration(duration)}',
              ),
            ],
          ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _playCachedFile(String localPath) async {
    final success = await _controller.playCachedTrack(localPath);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success ? '正在播放' : '播放失败')));
    setState(() {});
  }

  void _pausePlayer() async {
    await _controller.pausePlayer();
    if (mounted) setState(() {});
  }

  void _resumePlayer() async {
    await _controller.resumePlayer();
    if (mounted) setState(() {});
  }

  void _clearCache(String trackId) {
    _controller.clearTrackCache(trackId);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已清除缓存: $trackId')));
  }

  void _retryDownload() {
    // TODO: 重新触发下载
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('重试功能待实现')));
  }

  /// 播放控制区块
  Widget _buildPlaybackControlSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '播放控制',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _play(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _pause(),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                ElevatedButton.icon(
                  onPressed: () => _seek(),
                  icon: const Icon(Icons.fast_forward),
                  label: const Text('Seek +500ms'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// FutureStart 同起开播区块
  Widget _buildFutureStartSection() {
    return StreamBuilder<TrackState>(
      stream: _controller.trackStateStream,
      initialData: _controller.trackState,
      builder: (context, snapshot) {
        final trackState = snapshot.data!;
        final isHost = _controller.role == SyncRole.host;
        final state = _controller.futureStartState;
        final stateStr = state.toString().split('.').last;
        final canStart = _canStartAtFuture(trackState);

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FutureStart 同起开播',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                // leadMs 调节（Host）
                if (isHost) ...[
                  Row(
                    children: [
                      const Text('提前量: '),
                      Expanded(
                        child: Slider(
                          value: _controller.leadMs.toDouble(),
                          min: 800,
                          max: 3000,
                          divisions: 22,
                          label: '${_controller.leadMs}ms',
                          onChanged: (value) {
                            _controller.leadMs = value.toInt();
                            setState(() {});
                          },
                        ),
                      ),
                      Text('${_controller.leadMs}ms'),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],

                // 状态显示
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('状态: $stateStr'),
                    Text('T: ${_controller.startAtRoomTimeMs}'),
                    Text('roomNow: ${_controller.roomNowMs}'),
                    if (state == FutureStartState.waiting)
                      Text(
                        '剩余: ${_controller.startAtRoomTimeMs - _controller.roomNowMs}ms',
                      ),
                    if (state == FutureStartState.started)
                      Text('误差: ${_controller.startErrorMs}ms'),
                    Text(
                      'trackStatus: ${trackState.status.toString().split('.').last}',
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 同起按钮（Host）
                if (isHost)
                  Opacity(
                    opacity: canStart ? 1.0 : 0.5,
                    child: ElevatedButton.icon(
                      onPressed: canStart ? _startAtFuture : null,
                      icon: const Icon(Icons.sync),
                      label: const Text('同起开播'),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _canStartAtFuture(TrackState trackState) {
    final role = _controller.role;
    final trackStatus = trackState.status;
    // 调试日志
    debugPrint(
      '[SyncLab] _canStartAtFuture: role=$role, trackStatus=$trackStatus',
    );
    if (role != SyncRole.host) return false;
    if (trackStatus != TrackStatus.serving) return false;
    // Host 作为时钟源，不需要检查 isClockLocked
    return true;
  }

  void _startAtFuture() async {
    debugPrint('[SyncLab]    called');
    final success = await _controller.startAtFuture();
    debugPrint('[SyncLab] startAtFuture result: $success');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success ? '同起开播已发送' : '同起开播失败')));
    setState(() {});
  }

  /// Catch-up 追帧区块（Client）
  Widget _buildCatchUpSection() {
    return StreamBuilder<SyncDiagnosticsData>(
      stream: _controller.diagnosticsStream,
      initialData: _controller.diagnostics,
      builder: (context, snapshot) {
        final diag = snapshot.data!;
        final isClient = _controller.role == SyncRole.client;
        final isClockLocked = _controller.isClockLocked;
        final trackState = _controller.trackState;
        final hasCache =
            trackState.status == TrackStatus.serving &&
            trackState.meta?.localPath.isNotEmpty == true;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Catch-up 追帧',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                // 状态显示
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('Host pos: ${diag.lastHostPosMs}ms'),
                    Text('采样时间: ${diag.lastHostStateAtRoomTimeMs}'),
                    Text('目标位置: ${diag.computedTargetPosMs}ms'),
                    Text('追帧差: ${diag.catchUpDeltaMs}ms'),
                    Text('已追帧: ${diag.catchUpPerformed}'),
                    Text('时钟锁定: $isClockLocked'),
                    Text('已缓存: $hasCache'),
                  ],
                ),
                const SizedBox(height: 12),

                // 手动追帧按钮
                if (isClient)
                  Opacity(
                    opacity: (isClockLocked && hasCache) ? 1.0 : 0.5,
                    child: ElevatedButton.icon(
                      onPressed: (isClockLocked && hasCache)
                          ? () => _manualCatchUp()
                          : null,
                      icon: const Icon(Icons.fast_forward),
                      label: const Text('立即追帧'),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _manualCatchUp() async {
    final success = await _controller.manualCatchUp();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success ? '追帧成功' : '追帧失败')));
  }

  /// KeepSync 持续同步区块（Client）
  Widget _buildKeepSyncSection() {
    return StreamBuilder<SyncDiagnosticsData>(
      stream: _controller.diagnosticsStream,
      builder: (context, snapshot) {
        final diag = snapshot.data ?? _controller.diagnostics;
        final isEnabled = diag.keepSyncEnabled;
        final deltaMs = diag.keepSyncDeltaMs;
        final predictedDeltaMs = diag.keepSyncPredictedDeltaMs;
        final speed = diag.keepSyncSpeed;
        final speedEma = diag.keepSyncSpeedEma;
        final speedCmd = diag.keepSyncSpeedCmd;
        final holdRemainingMs = diag.keepSyncHoldRemainingMs;
        final lastAction = diag.keepSyncLastAction;
        final seekCount = diag.keepSyncSeekCount;
        final speedSetCount = diag.keepSyncSpeedSetCount;
        final droppedCount = diag.keepSyncDroppedCount;
        final reason = diag.keepSyncReason ?? '-';
        final latencyCompMs = diag.latencyCompMs;

        // 计算实际听感延迟（Delta + 延迟补偿）
        // 注意：deltaMs 已经减去了 latencyCompMs，所以实际听感延迟 = deltaMs + latencyCompMs
        // 但如果同步正确，deltaMs 应该接近 0，实际听感延迟主要是 latencyCompMs
        // 更准确的计算：实际听感延迟 = |deltaMs| + latencyCompMs（如果 delta 为正表示落后）
        final audibleLatencyMs = deltaMs + latencyCompMs;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'KeepSync 持续同步',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: isEnabled,
                      onChanged: (v) => _toggleKeepSync(v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('Delta: ${deltaMs}ms'),
                    Text(
                      '听感延迟: ${audibleLatencyMs}ms',
                      style: TextStyle(
                        color: audibleLatencyMs.abs() > 150
                            ? Colors.red
                            : audibleLatencyMs.abs() > 80
                            ? Colors.orange
                            : Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text('补偿: ${latencyCompMs}ms'),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('Pred: ${predictedDeltaMs}ms'),
                    Text('Speed: ${speed.toStringAsFixed(3)}'),
                    Text('EMA: ${speedEma.toStringAsFixed(3)}'),
                    Text('Cmd: ${speedCmd.toStringAsFixed(3)}'),
                    if (holdRemainingMs > 0)
                      Text(
                        'HOLD: ${holdRemainingMs}ms',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('Action: $lastAction'),
                    Text('Seeks: $seekCount'),
                    Text('SpeedSets: $speedSetCount'),
                    Text('Dropped: $droppedCount'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Reason: $reason',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 12),
                // Delta 指示器（使用预测 delta）
                LinearProgressIndicator(
                  value: (predictedDeltaMs.abs() / 500).clamp(0.0, 1.0),
                  backgroundColor: Colors.grey[300],
                  valueColor: AlwaysStoppedAnimation(
                    predictedDeltaMs.abs() <= 30
                        ? Colors.green
                        : predictedDeltaMs.abs() <= 500
                        ? Colors.orange
                        : Colors.red,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '预测 Delta: |${predictedDeltaMs}ms| ${predictedDeltaMs.abs() <= 30
                      ? "✓ 在死区内"
                      : predictedDeltaMs.abs() <= 500
                      ? "→ 速度调整中"
                      : "⚠ 偏差较大"}',
                  style: TextStyle(
                    color: predictedDeltaMs.abs() <= 30
                        ? Colors.green
                        : predictedDeltaMs.abs() <= 500
                        ? Colors.orange
                        : Colors.red,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleKeepSync(bool enabled) {
    _controller.setKeepSyncEnabled(enabled);
    setState(() {});
  }

  /// 延迟分解面板（Client）- 按影响程度排序
  Widget _buildLatencyBreakdownSection() {
    return StreamBuilder<SyncDiagnosticsData>(
      stream: _controller.diagnosticsStream,
      builder: (context, snapshot) {
        final diag = snapshot.data ?? _controller.diagnostics;

        // 延迟元素（按影响程度排序）
        final latencyItems = <_LatencyItem>[
          _LatencyItem(
            name: 'RTT (网络往返)',
            valueMs: diag.rttMs,
            impact: diag.rttMs > 100
                ? 'high'
                : diag.rttMs > 50
                ? 'medium'
                : 'low',
            description: '网络延迟，影响时钟同步精度',
          ),
          _LatencyItem(
            name: 'Jitter (抖动)',
            valueMs: diag.jitterMs,
            impact: diag.jitterMs > 40
                ? 'high'
                : diag.jitterMs > 20
                ? 'medium'
                : 'low',
            description: '网络不稳定，影响同步稳定性',
          ),
          _LatencyItem(
            name: 'Clock Offset',
            valueMs: diag.offsetEmaMs.abs(),
            impact: diag.offsetEmaMs.abs() > 100
                ? 'high'
                : diag.offsetEmaMs.abs() > 50
                ? 'medium'
                : 'low',
            description: '时钟偏移，影响位置计算',
          ),
          _LatencyItem(
            name: 'Delta (播放偏差)',
            valueMs: diag.keepSyncDeltaMs.abs(),
            impact: diag.keepSyncDeltaMs.abs() > 100
                ? 'high'
                : diag.keepSyncDeltaMs.abs() > 30
                ? 'medium'
                : 'low',
            description: '当前播放位置偏差',
          ),
          _LatencyItem(
            name: 'Predicted Delta',
            valueMs: diag.keepSyncPredictedDeltaMs.abs(),
            impact: diag.keepSyncPredictedDeltaMs.abs() > 100
                ? 'high'
                : diag.keepSyncPredictedDeltaMs.abs() > 30
                ? 'medium'
                : 'low',
            description: '预测的未来偏差',
          ),
          _LatencyItem(
            name: 'Latency Comp',
            valueMs: diag.latencyCompMs,
            impact: 'info',
            description: '手动校准的延迟补偿',
          ),
        ];

        // 按影响程度排序：high > medium > low > info
        final impactOrder = {'high': 0, 'medium': 1, 'low': 2, 'info': 3};
        latencyItems.sort(
          (a, b) => impactOrder[a.impact]!.compareTo(impactOrder[b.impact]!),
        );

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '延迟分解（按影响排序）',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ...latencyItems.map((item) => _buildLatencyItemRow(item)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLatencyItemRow(_LatencyItem item) {
    Color valueColor;
    switch (item.impact) {
      case 'high':
        valueColor = Colors.red;
        break;
      case 'medium':
        valueColor = Colors.orange;
        break;
      case 'low':
        valueColor = Colors.green;
        break;
      default:
        valueColor = Colors.grey;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              item.name,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Container(
            width: 60,
            alignment: Alignment.centerRight,
            child: Text(
              '${item.valueMs}ms',
              style: TextStyle(color: valueColor, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.description,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  /// 指标面板区块（Client）
  Widget _buildMetricsSection() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final stats30s = _controller.metrics.getStats30s(nowMs);
    final stats120s = _controller.metrics.getStats120s(nowMs);
    final dropStats = _controller.metrics.dropStats;
    final protectMode = _controller.metrics.protectMode;
    final protectTrigger = _controller.metrics.protectTrigger;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '指标面板',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                // 保护模式指示器
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: protectMode == ProtectMode.protect
                        ? Colors.orange
                        : Colors.green,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    protectMode == ProtectMode.protect
                        ? '保护模式: ${protectTrigger.name}'
                        : '正常',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 30s 统计
            Text('最近 30s:', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _metricItem('样本', '${stats30s.sampleCount}'),
                _metricItem('均值', '${stats30s.meanMs.toStringAsFixed(1)}ms'),
                _metricItem('P50', '${stats30s.p50Ms}ms'),
                _metricItem('P95', '${stats30s.p95Ms}ms'),
                _metricItem('P99', '${stats30s.p99Ms}ms'),
                _metricItem(
                  '≤30ms',
                  '${(stats30s.within30msRatio * 100).toStringAsFixed(1)}%',
                  stats30s.within30msRatio > 0.9 ? Colors.green : Colors.orange,
                ),
                _metricItem('seek/min', '${stats30s.seekCount}'),
                _metricItem('speed/min', '${stats30s.speedSetCount}'),
              ],
            ),
            const SizedBox(height: 12),

            // 120s 统计
            Text('最近 120s:', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _metricItem('样本', '${stats120s.sampleCount}'),
                _metricItem('均值', '${stats120s.meanMs.toStringAsFixed(1)}ms'),
                _metricItem('P50', '${stats120s.p50Ms}ms'),
                _metricItem('P95', '${stats120s.p95Ms}ms'),
                _metricItem('P99', '${stats120s.p99Ms}ms'),
                _metricItem(
                  '≤30ms',
                  '${(stats120s.within30msRatio * 100).toStringAsFixed(1)}%',
                  stats120s.within30msRatio > 0.9
                      ? Colors.green
                      : Colors.orange,
                ),
                _metricItem('seek/min', '${stats120s.seekCount}'),
                _metricItem('speed/min', '${stats120s.speedSetCount}'),
              ],
            ),
            const SizedBox(height: 12),

            // Drop 统计
            Text('Drop 统计:', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _metricItem('stale', '${dropStats.staleCount}'),
                _metricItem('clockUnlocked', '${dropStats.clockUnlockedCount}'),
                _metricItem('notReady', '${dropStats.notReadyCount}'),
                _metricItem('总计', '${dropStats.total}'),
              ],
            ),
            const SizedBox(height: 12),

            // 导出按钮
            ElevatedButton.icon(
              onPressed: () {
                final json = _controller.metrics.exportSamplesJson();
                Clipboard.setData(ClipboardData(text: json));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制 120s 样本到剪贴板')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('导出 120s 样本'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricItem(String label, String value, [Color? color]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  /// 同步控制区块
  Widget _buildSyncControlSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '同步控制',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _startSync(),
                  icon: const Icon(Icons.sync),
                  label: const Text('开始同步'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _stopSync(),
                  icon: const Icon(Icons.sync_disabled),
                  label: const Text('停止同步'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '当前速度: ${_controller.diagnostics.speedSet.toStringAsFixed(2)}x',
            ),
          ],
        ),
      ),
    );
  }

  /// 校准区块
  Widget _buildCalibrationSection() {
    final calibration = _controller.calibration;
    final calibrationOffset = calibration.calibrationOffsetMs;
    final latencyComp = calibration.latencyCompMs;
    final totalComp = calibration.totalCompensationMs;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '耳朵校准',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '调整滑条直到耳朵听到的同步为止',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),

            if (Platform.isIOS) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [_buildPresetButton('iOS 默认(150/100)', 100, 150)],
              ),
              const SizedBox(height: 12),
            ],

            // 校准偏移滑条 + 精细调节
            Row(
              children: [
                const Text('偏移: '),
                // 减少 10ms
                IconButton(
                  icon: const Icon(Icons.fast_rewind),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setCalibrationOffset(
                      calibrationOffset - 10,
                    );
                    setState(() {});
                  },
                ),
                // 减少 1ms
                IconButton(
                  icon: const Icon(Icons.remove),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setCalibrationOffset(
                      calibrationOffset - 1,
                    );
                    setState(() {});
                  },
                ),
                Expanded(
                  child: Slider(
                    value: calibrationOffset.toDouble(),
                    min: -300,
                    max: 300,
                    divisions: 600,
                    label: '${calibrationOffset}ms',
                    onChanged: (value) {
                      _controller.calibration.setCalibrationOffset(
                        value.round(),
                      );
                      setState(() {});
                    },
                  ),
                ),
                // 增加 1ms
                IconButton(
                  icon: const Icon(Icons.add),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setCalibrationOffset(
                      calibrationOffset + 1,
                    );
                    setState(() {});
                  },
                ),
                // 增加 10ms
                IconButton(
                  icon: const Icon(Icons.fast_forward),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setCalibrationOffset(
                      calibrationOffset + 10,
                    );
                    setState(() {});
                  },
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '${calibrationOffset}ms',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '正值=让本机更晚播放，负值=让本机更早播放',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            const SizedBox(height: 12),

            // 延迟补偿滑条 + 精细调节
            Row(
              children: [
                const Text('补偿: '),
                // 减少 10ms
                IconButton(
                  icon: const Icon(Icons.fast_rewind),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setLatencyComp(latencyComp - 10);
                    setState(() {});
                  },
                ),
                // 减少 1ms
                IconButton(
                  icon: const Icon(Icons.remove),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setLatencyComp(latencyComp - 1);
                    setState(() {});
                  },
                ),
                Expanded(
                  child: Slider(
                    value: latencyComp.toDouble(),
                    min: 0,
                    max: 500,
                    divisions: 500,
                    label: '${latencyComp}ms',
                    onChanged: (value) {
                      _controller.calibration.setLatencyComp(value.round());
                      setState(() {});
                    },
                  ),
                ),
                // 增加 1ms
                IconButton(
                  icon: const Icon(Icons.add),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setLatencyComp(latencyComp + 1);
                    setState(() {});
                  },
                ),
                // 增加 10ms
                IconButton(
                  icon: const Icon(Icons.fast_forward),
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    _controller.calibration.setLatencyComp(latencyComp + 10);
                    setState(() {});
                  },
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    '${latencyComp}ms',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 预设值按钮
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildPresetButton('有线耳机', 80, 0),
                _buildPresetButton('蓝牙耳机', 150, 0),
                _buildPresetButton('蓝牙+延迟', 200, 50),
              ],
            ),
            const SizedBox(height: 12),

            // 总补偿值
            Row(
              children: [
                Text('总补偿: ${totalComp}ms'),
                const SizedBox(width: 16),
                TextButton(
                  onPressed: () {
                    _controller.calibration.reset();
                    setState(() {});
                  },
                  child: const Text('重置'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetButton(
    String label,
    int latencyCompMs,
    int calibrationOffsetMs,
  ) {
    return OutlinedButton(
      onPressed: () {
        _controller.calibration.setLatencyComp(latencyCompMs);
        _controller.calibration.setCalibrationOffset(calibrationOffsetMs);
        setState(() {});
      },
      child: Text(label),
    );
  }

  /// Clock 区块 - 使用 AnimatedBuilder 监听节流通知器
  Widget _buildClockSection() {
    return AnimatedBuilder(
      animation: _controller.throttledNotifier,
      builder: (context, child) {
        final isLocked = _controller.isClockLocked;
        final lockColor = isLocked ? Colors.green : Colors.orange;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '🕐 时钟同步状态',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: lockColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isLocked ? '已锁定 ✓' : '未锁定',
                        style: TextStyle(
                          color: lockColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 时钟数据 - 中文说明
                _buildDiagRowWithTooltip(
                  '往返延迟 (RTT)',
                  '${_controller.rttMs} ms',
                  'ping 消息从 Client 到 Host 再返回的总时间',
                ),
                _buildDiagRowWithTooltip(
                  '原始偏移',
                  '${_controller.offsetRawMs} ms',
                  '单次测量得到的客户端与服务器时间差',
                ),
                _buildDiagRowWithTooltip(
                  '平滑偏移 (EMA)',
                  '${_controller.offsetEmaMs} ms',
                  '使用指数移动平均平滑后的时间偏移，更稳定',
                ),
                _buildDiagRowWithTooltip(
                  '网络抖动 (Jitter)',
                  '${_controller.jitterMs} ms',
                  'RTT 的变化幅度，反映网络稳定性',
                ),
                _buildDiagRowWithTooltip(
                  '采样次数',
                  '${_controller.clockSampleCount}',
                  '已收集的有效时钟同步样本数量',
                ),

                const Divider(),
                const Text(
                  '样本过滤统计',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),

                _buildDiagRowWithTooltip(
                  '丢弃样本数',
                  '${_controller.diagnostics.droppedSamplesCount}',
                  '因 RTT 过高或 offset 跳跃过大而被丢弃的样本数',
                ),
                _buildDiagRowWithTooltip(
                  '最近丢弃原因',
                  _controller.diagnostics.lastDroppedReason ?? '-',
                  '最近一次样本被丢弃的原因',
                ),
                _buildDiagRowWithTooltip(
                  '最近合格 RTT',
                  '${_controller.diagnostics.lastGoodRttMs} ms',
                  '最近通过过滤的样本的 RTT 值',
                ),

                const Divider(),
                const Text(
                  'EMA 平滑系数调整',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                const Text(
                  'α 越小越平滑（响应慢），越大越灵敏（噪声多）',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),

                // Alpha 滑条
                Row(
                  children: [
                    const Text('0.05'),
                    Expanded(
                      child: Slider(
                        value: _controller.emaAlpha.clamp(0.05, 0.3),
                        min: 0.05,
                        max: 0.3,
                        divisions: 25,
                        label: _controller.emaAlpha.toStringAsFixed(2),
                        onChanged: (value) {
                          _controller.setEmaAlpha(value);
                        },
                      ),
                    ),
                    const Text('0.30'),
                  ],
                ),
                Text('当前 α = ${_controller.emaAlpha.toStringAsFixed(2)}'),

                const SizedBox(height: 12),

                // 重置按钮
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _resetClock(keepHistory: false),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重置时钟'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _resetClock(keepHistory: true),
                      icon: const Icon(Icons.history),
                      label: const Text('保留历史重置'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建带说明的诊断行
  Widget _buildDiagRowWithTooltip(String label, String value, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14)),
            Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  void _resetClock({required bool keepHistory}) {
    _controller.resetClock(keepHistory: keepHistory);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Clock 已重置 (keepHistory=$keepHistory)')),
      );
      setState(() {});
    }
  }

  /// 诊断面板 - 使用 AnimatedBuilder 监听节流通知器
  Widget _buildDiagnosticsPanel() {
    return AnimatedBuilder(
      animation: _controller.throttledNotifier,
      builder: (context, child) {
        final diag = _controller.diagnostics;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '📊 诊断面板',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _copyDebugBundle(),
                      icon: const Icon(Icons.copy),
                      label: const Text('复制日志'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _exportDebugBundle(),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('导出日志'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _clearDebugLogs(),
                      icon: const Icon(Icons.delete),
                      label: const Text('清空日志'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    if (Platform.isIOS)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('iOS 安全模式'),
                          Switch(
                            value: _controller.isIosSafeMode,
                            onChanged: (v) {
                              _controller.setIosSafeMode(v);
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                  ],
                ),

                if (_lastExportPath != null) ...[
                  const SizedBox(height: 8),
                  _buildDiagRowWithTooltip(
                    '导出路径',
                    _lastExportPath!,
                    'debug bundle 已写入临时目录，可复制路径从设备取出',
                  ),
                ],

                // 状态信息
                _buildDiagRowWithTooltip('状态', diag.state, '当前同步状态机状态'),
                _buildDiagRowWithTooltip(
                  '角色',
                  diag.role,
                  '当前设备角色 (host/client/none)',
                ),
                _buildDiagRowWithTooltip(
                  '房间 ID',
                  diag.roomId ?? '-',
                  '当前所在房间标识',
                ),
                _buildDiagRowWithTooltip(
                  '设备 ID',
                  diag.peerId ?? '-',
                  '本设备在网络中的唯一标识',
                ),

                const Divider(),
                const Text(
                  '🕐 时钟同步',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                _buildDiagRowWithTooltip(
                  '房间时间',
                  '${diag.roomNowMs} ms',
                  '同步后的房间统一时间戳',
                ),
                _buildDiagRowWithTooltip('往返延迟', '${diag.rttMs} ms', '网络往返时间'),
                _buildDiagRowWithTooltip(
                  '时间偏移',
                  '${diag.offsetEmaMs} ms',
                  '客户端与服务器的时间差',
                ),
                _buildDiagRowWithTooltip(
                  '网络抖动',
                  '${diag.jitterMs} ms',
                  '延迟变化幅度',
                ),

                const Divider(),
                const Text(
                  '🎵 播放位置',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                _buildDiagRowWithTooltip(
                  'Host 位置',
                  '${diag.hostPosMs} ms',
                  'Host 当前播放位置',
                ),
                _buildDiagRowWithTooltip(
                  'Client 位置',
                  '${diag.clientPosMs} ms',
                  'Client 当前播放位置',
                ),
                _buildDiagRowWithTooltip(
                  '延迟补偿',
                  '${diag.latencyCompMs} ms',
                  '人为设置的延迟补偿值',
                ),

                const Divider(),
                const Text(
                  '⚙️ 同步控制',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                _buildDiagRowWithTooltip(
                  '位置差',
                  '${diag.deltaMs} ms',
                  'Client 与 Host 的播放位置差距',
                ),
                _buildDiagRowWithTooltip(
                  '播放速度',
                  diag.speedSet.toStringAsFixed(3),
                  '为追赶/等待而调整的播放速度',
                ),
                _buildDiagRowWithTooltip(
                  '是否 Seek',
                  diag.seekPerformed.toString(),
                  '是否执行了跳转操作',
                ),
                _buildDiagRowWithTooltip(
                  '上次 Seek',
                  diag.lastSeekAt?.toString() ?? '-',
                  '最近一次跳转的时间',
                ),

                if (diag.errorMessage != null) ...[
                  const Divider(),
                  Text(
                    '❌ 错误: ${diag.errorMessage}',
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  // ========== 操作方法 ==========

  Future<void> _createRoom() async {
    final success = await _controller.createRoom(roomName: 'Test Room');
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success ? '房间已创建' : '创建房间失败')));
      setState(() {});
    }
  }

  Future<void> _closeRoom() async {
    await _controller.closeRoom();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _startScanning() async {
    await _controller.startScanning();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _stopScanning() async {
    await _controller.stopScanning();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _joinRoom(DiscoveredRoom room) async {
    final success = await _controller.joinRoom(room);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success ? '已加入房间' : '加入房间失败')));
      setState(() {});
    }
  }

  Future<void> _joinByIp() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text) ?? 8765;

    if (ip.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入 Host IP')));
      return;
    }

    final success = await _controller.joinByIp(ip, port);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success ? '已加入房间' : '加入房间失败')));
      setState(() {});
    }
  }

  Future<void> _leaveRoom() async {
    await _controller.leaveRoom();
    if (mounted) {
      setState(() {});
    }
  }

  /// 选择 MP3 文件（使用 file_picker）
  Future<void> _selectMp3File() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3'],
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.path != null) {
          final success = await _controller.selectMp3File(file.path!);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(success ? '已选择: ${file.name}' : '选择失败')),
            );
            setState(() {});
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件失败: $e')));
      }
    }
  }

  /// 使用 Demo 音频（assets 兜底）
  Future<void> _useDemoAudio() async {
    // TODO: 从 assets 复制 demo.mp3 到临时目录
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demo 音频功能待实现（需要 assets/demo.mp3）')),
      );
    }
  }

  /// 开始分发曲目
  Future<void> _startServingTrack() async {
    final success = await _controller.startServingTrack();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success ? '已开始分发曲目' : '分发失败')));
      setState(() {});
    }
  }

  /// 停止分发曲目
  Future<void> _stopServingTrack() async {
    await _controller.stopServingTrack();
    if (mounted) {
      setState(() {});
    }
  }

  void _play() async {
    final success = await _controller.play();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success ? '正在播放' : '播放失败')));
    setState(() {});
  }

  void _pause() async {
    await _controller.pause();
    if (mounted) setState(() {});
  }

  void _seek() async {
    // seek +500ms（模拟偏移）
    await _controller.seek(500);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已跳转 +500ms（模拟偏移）')));
      setState(() {});
    }
  }

  void _startSync() {
    _controller.startPlaybackSync();
    if (mounted) {
      setState(() {});
    }
  }

  void _stopSync() {
    _controller.stopPlaybackSync();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _disconnect() async {
    await _controller.disconnect();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已断开连接')));
      setState(() {});
    }
  }

  Future<void> _triggerReconnect() async {
    try {
      await _controller.triggerReconnect();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('正在重新连接...')));
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重连失败: $e')));
      }
    }
  }

  Future<void> _copyDebugBundle() async {
    try {
      final text = _controller.buildDebugBundleText();
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已复制日志到剪贴板')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('复制失败: $e')));
    }
  }

  Future<void> _exportDebugBundle() async {
    try {
      final path = await _controller.exportDebugBundleToFile();
      if (!mounted) return;
      setState(() {
        _lastExportPath = path;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出: $path')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
  }

  void _clearDebugLogs() {
    _controller.clearDebugLogs();
    if (mounted) {
      setState(() {
        _lastExportPath = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('日志已清空')));
    }
  }
}
