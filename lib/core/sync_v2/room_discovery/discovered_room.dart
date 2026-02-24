/// 发现的房间信息
class DiscoveredRoom {
  final String roomId;
  final String roomName;
  final String hostIp;
  final int hostWsPort;
  final int hostHttpPort;
  final String appVersion;
  final String codec;
  final DateTime discoveredAt;
  final DateTime? lastSeenAt;

  const DiscoveredRoom({
    required this.roomId,
    required this.roomName,
    required this.hostIp,
    required this.hostWsPort,
    required this.hostHttpPort,
    required this.appVersion,
    required this.codec,
    required this.discoveredAt,
    this.lastSeenAt,
  });

  /// 从 mDNS TXT 记录解析
  factory DiscoveredRoom.fromTxtRecord({
    required String serviceName,
    required String hostIp,
    required Map<String, String> txtRecord,
  }) {
    return DiscoveredRoom(
      roomId: txtRecord['roomId'] ?? serviceName,
      roomName: txtRecord['roomName'] ?? 'Unknown Room',
      hostIp: hostIp,
      hostWsPort: int.tryParse(txtRecord['hostWsPort'] ?? '8765') ?? 8765,
      hostHttpPort: int.tryParse(txtRecord['hostHttpPort'] ?? '8080') ?? 8080,
      appVersion: txtRecord['appVersion'] ?? '1.0.0',
      codec: txtRecord['codec'] ?? 'mp3',
      discoveredAt: DateTime.now(),
    );
  }

  /// 更新最后发现时间
  DiscoveredRoom withLastSeen() {
    return DiscoveredRoom(
      roomId: roomId,
      roomName: roomName,
      hostIp: hostIp,
      hostWsPort: hostWsPort,
      hostHttpPort: hostHttpPort,
      appVersion: appVersion,
      codec: codec,
      discoveredAt: discoveredAt,
      lastSeenAt: DateTime.now(),
    );
  }

  /// 转换为日志字符串
  String toLogString() {
    return 'DiscoveredRoom(roomId=$roomId, name=$roomName, host=$hostIp:$hostWsPort, version=$appVersion)';
  }

  @override
  String toString() => toLogString();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DiscoveredRoom && other.roomId == roomId;
  }

  @override
  int get hashCode => roomId.hashCode;
}
