import Flutter
import AVFoundation

class AudioEngineManager: NSObject {
    static let shared = AudioEngineManager()
    
    private var audioPlayer: AVAudioPlayer?
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    // 音频会话配置
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowBluetooth])
            try session.setActive(true)
            
            // 监听音频打断和路由变化
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioSessionInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: session
            )
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            audioPlayer?.pause()
            eventSink?(["event": "interruption_began"])
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    audioPlayer?.play()
                    eventSink?(["event": "interruption_ended", "shouldResume": true])
                }
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        var reasonString = "unknown"
        switch reason {
        case .newDeviceAvailable:
            reasonString = "new_device"
        case .oldDeviceUnavailable:
            reasonString = "device_unavailable"
            audioPlayer?.pause()
        case .categoryChange:
            reasonString = "category_change"
        default:
            break
        }
        
        eventSink?(["event": "route_change", "reason": reasonString])
    }
    
    func setupChannels(binaryMessenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "com.sync_music/audio_engine",
            binaryMessenger: binaryMessenger
        )
        
        methodChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }
        
        eventChannel = FlutterEventChannel(
            name: "com.sync_music/audio_engine/events",
            binaryMessenger: binaryMessenger
        )
        eventChannel?.setStreamHandler(self)
        
        configureAudioSession()
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "load":
            guard let args = call.arguments as? [String: Any],
                  let filePath = args["filePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing filePath", details: nil))
                return
            }
            loadAudio(filePath: filePath, result: result)
            
        case "play":
            playAudio(result: result)
            
        case "pause":
            pauseAudio(result: result)
            
        case "seek":
            guard let args = call.arguments as? [String: Any],
                  let positionMs = args["positionMs"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing positionMs", details: nil))
                return
            }
            seekTo(positionMs: positionMs, result: result)
            
        case "setRate":
            guard let args = call.arguments as? [String: Any],
                  let rate = args["rate"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing rate", details: nil))
                return
            }
            let smooth = args["smooth"] as? Bool ?? true
            setRate(rate: rate, smooth: smooth, result: result)
            
        case "getPosition":
            getPosition(result: result)
            
        case "getDuration":
            getDuration(result: result)
            
        case "isPlaying":
            result(audioPlayer?.isPlaying ?? false)
            
        case "isLoaded":
            result(audioPlayer != nil)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func loadAudio(filePath: String, result: @escaping FlutterResult) {
        do {
            let url = URL(fileURLWithPath: filePath)
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.enableRate = true
            
            // 设置定时器报告播放进度
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                if let player = self?.audioPlayer {
                    self?.eventSink?([
                        "event": "position_update",
                        "positionMs": Int(player.currentTime * 1000),
                        "durationMs": Int(player.duration * 1000),
                        "isPlaying": player.isPlaying
                    ])
                }
            }
            
            result(true)
        } catch {
            result(FlutterError(code: "LOAD_ERROR", message: error.localizedDescription, details: nil))
        }
    }
    
    private func playAudio(result: @escaping FlutterResult) {
        guard let player = audioPlayer else {
            result(FlutterError(code: "NOT_LOADED", message: "No audio loaded", details: nil))
            return
        }
        
        let success = player.play()
        result(success)
    }
    
    private func pauseAudio(result: @escaping FlutterResult) {
        audioPlayer?.pause()
        result(true)
    }
    
    private func seekTo(positionMs: Int, result: @escaping FlutterResult) {
        guard let player = audioPlayer else {
            result(FlutterError(code: "NOT_LOADED", message: "No audio loaded", details: nil))
            return
        }
        
        let positionSec = Double(positionMs) / 1000.0
        player.currentTime = positionSec
        result(true)
    }
    
    private func setRate(rate: Double, smooth: Bool, result: @escaping FlutterResult) {
        guard let player = audioPlayer else {
            result(FlutterError(code: "NOT_LOADED", message: "No audio loaded", details: nil))
            return
        }
        
        // 限制rate范围避免音质问题
        let clampedRate = max(0.5, min(2.0, rate))
        
        if smooth {
            // 平滑过渡：使用渐变动画
            let currentRate = player.rate
            let targetRate = Float(clampedRate)
            let steps = 10
            let stepDuration = 0.05
            
            for i in 0...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stepDuration) {
                    let progress = Double(i) / Double(steps)
                    let newRate = currentRate + (targetRate - currentRate) * Float(progress)
                    player.rate = newRate
                }
            }
        } else {
            player.rate = Float(clampedRate)
        }
        
        result(true)
    }
    
    private func getPosition(result: @escaping FlutterResult) {
        let positionMs = Int((audioPlayer?.currentTime ?? 0) * 1000)
        result(positionMs)
    }
    
    private func getDuration(result: @escaping FlutterResult) {
        let durationMs = Int((audioPlayer?.duration ?? 0) * 1000)
        result(durationMs)
    }
}

// MARK: - FlutterStreamHandler
extension AudioEngineManager: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
