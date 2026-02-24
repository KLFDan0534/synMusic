import Foundation
import Flutter

/// mDNS/Bonjour 服务管理器
/// 使用 NSNetService 进行服务发布与发现
class MdnsService: NSObject {
    static let shared = MdnsService()
    
    private override init() {
        super.init()
    }
    
    // 服务类型
    private let serviceType = "_syncmusic._tcp."
    
    // 发布的服务
    private var netService: NetService?
    
    // 浏览器
    private var browser: NetServiceBrowser?
    
    // 发现的服务列表
    private var discoveredServices: [NetService] = []
    
    // Flutter 回调
    private var channel: FlutterMethodChannel?
    
    // 当前发布的服务信息
    private var currentRoomId: String?
    private var currentRoomName: String?
    
    // MARK: - Setup
    
    func setupChannel(binaryMessenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.syncmusic/mdns",
            binaryMessenger: binaryMessenger
        )
        
        channel?.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call: call, result: result)
        }
    }
    
    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "publishRoom":
            handlePublishRoom(call: call, result: result)
        case "unpublishRoom":
            handleUnpublishRoom(result: result)
        case "startScanning":
            handleStartScanning(result: result)
        case "stopScanning":
            handleStopScanning(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Publish Room (Host)
    
    private func handlePublishRoom(call: FlutterMethodCall, result: FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let roomId = args["roomId"] as? String,
              let roomName = args["roomName"] as? String,
              let wsPort = args["wsPort"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "缺少必要参数", details: nil))
            return
        }
        
        let httpPort = args["httpPort"] as? Int ?? 8080
        let appVersion = args["appVersion"] as? String ?? "1.0.0"
        let codec = args["codec"] as? String ?? "mp3"
        
        publishRoom(
            roomId: roomId,
            roomName: roomName,
            wsPort: wsPort,
            httpPort: httpPort,
            appVersion: appVersion,
            codec: codec,
            result: result
        )
    }
    
    private func publishRoom(
        roomId: String,
        roomName: String,
        wsPort: Int,
        httpPort: Int,
        appVersion: String,
        codec: String,
        result: FlutterResult
    ) {
        // 停止现有服务
        unpublishRoomInternal()
        
        currentRoomId = roomId
        currentRoomName = roomName
        
        // 创建服务
        netService = NetService(
            domain: "local.",
            type: serviceType,
            name: roomId,
            port: Int16(wsPort)
        )
        
        guard let service = netService else {
            result(FlutterError(code: "CREATE_FAILED", message: "无法创建服务", details: nil))
            return
        }
        
        // 设置 TXT 记录
        var txtDict: [String: Data] = [:]
        txtDict["roomId"] = roomId.data(using: .utf8) ?? Data()
        txtDict["roomName"] = roomName.data(using: .utf8) ?? Data()
        txtDict["hostWsPort"] = String(wsPort).data(using: .utf8) ?? Data()
        txtDict["hostHttpPort"] = String(httpPort).data(using: .utf8) ?? Data()
        txtDict["appVersion"] = appVersion.data(using: .utf8) ?? Data()
        txtDict["codec"] = codec.data(using: .utf8) ?? Data()
        
        let txtData = NetService.data(fromTXTRecord: txtDict)
        service.setTXTRecord(txtData)
        
        service.delegate = self
        
        // 发布服务
        service.publish(options: [.listenForConnections])
        
        NSLog("[MdnsService] 房间已发布: \(roomId) 端口: \(wsPort)")
        result(true)
    }
    
    private func handleUnpublishRoom(result: FlutterResult) {
        unpublishRoomInternal()
        result(nil)
    }
    
    private func unpublishRoomInternal() {
        netService?.stop()
        netService = nil
        currentRoomId = nil
        currentRoomName = nil
        NSLog("[MdnsService] 房间已取消发布")
    }
    
    // MARK: - Scan Rooms (Client)
    
    private func handleStartScanning(result: FlutterResult) {
        startScanning()
        result(nil)
    }
    
    private func handleStopScanning(result: FlutterResult) {
        stopScanning()
        result(nil)
    }
    
    private func startScanning() {
        // 停止现有浏览
        stopScanning()
        
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: serviceType, inDomain: "local.")
        
        NSLog("[MdnsService] 开始扫描房间")
    }
    
    private func stopScanning() {
        browser?.stop()
        browser = nil
        discoveredServices.removeAll()
        
        // 通知 Flutter 清空列表
        channel?.invokeMethod("onRoomsCleared", arguments: nil)
        
        NSLog("[MdnsService] 停止扫描房间")
    }
    
    // MARK: - Helper
    
    private func parseTxtRecord(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        
        // 解析 TXT 记录
        let dict = NetService.dictionary(fromTXTRecord: data)
        for (key, value) in dict {
            result[key] = String(data: value, encoding: .utf8) ?? ""
        }
        
        return result
    }
    
    private func notifyRoomDiscovered(
        service: NetService,
        txtRecord: [String: String]
    ) {
        guard let hostAddress = service.addresses?.first else {
            return
        }
        
        // 获取 IP 地址
        var ipAddress = ""
        if let addressData = hostAddress as? Data {
            // 解析 sockaddr
            let addr = addressData.withUnsafeBytes { ptr -> sockaddr_in? in
                guard let baseAddr = ptr.baseAddress else { return nil }
                return baseAddr.bindMemory(to: sockaddr_in.self, capacity: 1).pointee
            }
            
            if let addr = addr {
                ipAddress = String(cString: inet_ntoa(addr.sin_addr))
            }
        }
        
        let roomData: [String: Any] = [
            "roomId": txtRecord["roomId"] ?? service.name,
            "roomName": txtRecord["roomName"] ?? "Unknown Room",
            "hostIp": ipAddress,
            "hostWsPort": Int(txtRecord["hostWsPort"] ?? "8765") ?? 8765,
            "hostHttpPort": Int(txtRecord["hostHttpPort"] ?? "8080") ?? 8080,
            "appVersion": txtRecord["appVersion"] ?? "1.0.0",
            "codec": txtRecord["codec"] ?? "mp3"
        ]
        
        channel?.invokeMethod("onRoomDiscovered", arguments: roomData)
        
        NSLog("[MdnsService] 发现房间: \(service.name) IP: \(ipAddress)")
    }
}

// MARK: - NetServiceDelegate

extension MdnsService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[MdnsService] 服务发布成功: \(sender.name)")
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("[MdnsService] 服务发布失败: \(errorDict)")
        channel?.invokeMethod("onPublishError", arguments: [
            "error": "服务发布失败",
            "details": errorDict.description
        ])
    }
    
    func netServiceDidStop(_ sender: NetService) {
        NSLog("[MdnsService] 服务已停止")
    }
}

// MARK: - NetServiceBrowserDelegate

extension MdnsService: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("[MdnsService] 发现服务: \(service.name)")
        
        // 添加到列表并解析
        discoveredServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        NSLog("[MdnsService] 服务移除: \(service.name)")
        
        // 从列表移除
        discoveredServices.removeAll { $0.name == service.name }
        
        // 通知 Flutter
        channel?.invokeMethod("onRoomLost", arguments: ["roomId": service.name])
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("[MdnsService] 扫描失败: \(errorDict)")
        channel?.invokeMethod("onScanError", arguments: [
            "error": "扫描失败",
            "details": errorDict.description
        ])
    }
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        NSLog("[MdnsService] 服务解析成功: \(sender.name)")
        
        // 获取 TXT 记录
        let txtData = sender.txtRecordData()
        let txtRecord = txtData != nil ? parseTxtRecord(txtData!) : [:]
        
        notifyRoomDiscovered(service: sender, txtRecord: txtRecord)
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("[MdnsService] 服务解析失败: \(sender.name) - \(errorDict)")
    }
}
