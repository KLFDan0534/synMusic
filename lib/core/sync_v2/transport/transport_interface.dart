import 'dart:async';

/// Transport 传输层接口
/// 定义设备间通信的抽象接口
abstract class Transport {
  /// 连接状态流
  Stream<TransportState> get stateStream;

  /// 当前连接状态
  TransportState get state;

  /// 接收消息流
  Stream<TransportMessage> get messageStream;

  /// 连接到远程服务端（Client 调用）
  Future<void> connect(String host, int port);

  /// 启动服务端监听（Host 调用）
  Future<void> startServer(int port);

  /// 发送消息
  Future<void> send(TransportMessage message);

  /// 广播消息给所有连接的客户端（Host 调用）
  Future<void> broadcast(TransportMessage message);

  /// 发送消息给指定客户端（Host 调用）
  Future<void> sendToPeer(String peerId, TransportMessage message);

  /// 断开连接
  Future<void> disconnect();

  /// 关闭服务端
  Future<void> stopServer();

  /// 获取连接的客户端列表（Host 调用）
  List<String> get connectedPeers;
}

/// Transport 连接状态
enum TransportState { disconnected, connecting, connected, hosting, error }

/// Transport 消息封装
class TransportMessage {
  final String type;
  final Map<String, dynamic> payload;
  final DateTime timestamp;
  final String? senderId;

  const TransportMessage({
    required this.type,
    required this.payload,
    required this.timestamp,
    this.senderId,
  });

  /// 创建消息
  factory TransportMessage.create(String type, Map<String, dynamic> payload) {
    return TransportMessage(
      type: type,
      payload: payload,
      timestamp: DateTime.now(),
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'payload': payload,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'senderId': senderId,
    };
  }

  /// 从 JSON 解析
  factory TransportMessage.fromJson(Map<String, dynamic> json) {
    return TransportMessage(
      type: json['type'] as String,
      payload: json['payload'] as Map<String, dynamic>,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      senderId: json['senderId'] as String?,
    );
  }
}
