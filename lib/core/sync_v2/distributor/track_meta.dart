/// 曲目元数据
class TrackMeta {
  final String trackId;
  final String localPath;
  final String? fileName;
  final int sizeBytes;
  final int durationMs;
  final String fileHash;
  final DateTime createdAt;

  const TrackMeta({
    required this.trackId,
    required this.localPath,
    this.fileName,
    required this.sizeBytes,
    required this.durationMs,
    required this.fileHash,
    required this.createdAt,
  });

  /// 生成 trackId（时间戳 + hash 前缀）
  static String generateTrackId(String fileHash) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final hashPrefix = fileHash.length >= 8
        ? fileHash.substring(0, 8)
        : fileHash;
    return '${timestamp}_$hashPrefix';
  }

  /// 格式化文件大小
  String get formattedSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    } else if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  /// 格式化时长
  String get formattedDuration {
    final minutes = durationMs ~/ 60000;
    final seconds = (durationMs % 60000) ~/ 1000;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'localPath': localPath,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'durationMs': durationMs,
    'fileHash': fileHash,
    'createdAt': createdAt.toIso8601String(),
  };

  TrackMeta copyWith({
    String? trackId,
    String? localPath,
    String? fileName,
    int? sizeBytes,
    int? durationMs,
    String? fileHash,
    DateTime? createdAt,
  }) {
    return TrackMeta(
      trackId: trackId ?? this.trackId,
      localPath: localPath ?? this.localPath,
      fileName: fileName ?? this.fileName,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      durationMs: durationMs ?? this.durationMs,
      fileHash: fileHash ?? this.fileHash,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory TrackMeta.fromJson(Map<String, dynamic> json) {
    return TrackMeta(
      trackId: json['trackId'] as String,
      localPath: json['localPath'] as String,
      fileName: json['fileName'] as String?,
      sizeBytes: json['sizeBytes'] as int,
      durationMs: json['durationMs'] as int,
      fileHash: json['fileHash'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

/// 曲目状态（用于 UI 显示）
enum TrackStatus {
  idle, // 未选择
  selecting, // 选择中
  hashing, // 计算 hash 中
  ready, // 准备就绪
  announcing, // 广播中
  serving, // 服务中
  error, // 错误
}

/// 曲目状态数据（用于 UI）
class TrackState {
  final TrackStatus status;
  final TrackMeta? meta;
  final String? error;
  final double hashProgress; // 0.0 - 1.0

  const TrackState({
    this.status = TrackStatus.idle,
    this.meta,
    this.error,
    this.hashProgress = 0.0,
  });

  TrackState copyWith({
    TrackStatus? status,
    TrackMeta? meta,
    String? error,
    double? hashProgress,
    bool clearMeta = false,
    bool clearError = false,
  }) {
    return TrackState(
      status: status ?? this.status,
      meta: clearMeta ? null : (meta ?? this.meta),
      error: clearError ? null : (error ?? this.error),
      hashProgress: hashProgress ?? this.hashProgress,
    );
  }
}
