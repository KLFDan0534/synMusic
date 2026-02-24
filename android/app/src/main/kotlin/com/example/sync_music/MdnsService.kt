package com.example.sync_music

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.ConcurrentHashMap

/// mDNS/NsdManager 服务管理器
/// Android 原生实现
class MdnsService private constructor(private val context: Context) : MethodChannel.MethodCallHandler {
    
    companion object {
        private const val TAG = "MdnsService"
        private const val SERVICE_TYPE = "_syncmusic._tcp."
        
        @Volatile
        private var instance: MdnsService? = null
        
        fun getInstance(context: Context): MdnsService {
            return instance ?: synchronized(this) {
                instance ?: MdnsService(context.applicationContext).also { instance = it }
            }
        }
    }
    
    private var nsdManager: NsdManager? = null
    private var channel: MethodChannel? = null
    
    // 主线程 Handler
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // 发布的服务
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var currentServiceInfo: NsdServiceInfo? = null
    
    // 发现服务
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val resolveListeners = ConcurrentHashMap<String, NsdManager.ResolveListener>()
    
    // 已发现的服务缓存
    private val discoveredServices = ConcurrentHashMap<String, NsdServiceInfo>()
    
    // MARK: - Setup
    
    fun setupChannel(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "com.syncmusic/mdns")
        channel?.setMethodCallHandler(this)
        
        nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
        
        Log.d(TAG, "mDNS 服务已初始化")
    }
    
    // MARK: - MethodChannel Handler
    
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "publishRoom" -> handlePublishRoom(call, result)
            "unpublishRoom" -> handleUnpublishRoom(result)
            "startScanning" -> handleStartScanning(result)
            "stopScanning" -> handleStopScanning(result)
            else -> result.notImplemented()
        }
    }
    
    // MARK: - Publish Room (Host)
    
    private fun handlePublishRoom(call: MethodCall, result: MethodChannel.Result) {
        val roomId = call.argument<String>("roomId")
        val roomName = call.argument<String>("roomName")
        val wsPort = call.argument<Int>("wsPort")
        val httpPort = call.argument<Int>("httpPort") ?: 8080
        val appVersion = call.argument<String>("appVersion") ?: "1.0.0"
        val codec = call.argument<String>("codec") ?: "mp3"
        
        if (roomId == null || roomName == null || wsPort == null) {
            result.error("INVALID_ARGS", "缺少必要参数", null)
            return
        }
        
        publishRoom(
            roomId = roomId,
            roomName = roomName,
            wsPort = wsPort,
            httpPort = httpPort,
            appVersion = appVersion,
            codec = codec,
            result = result
        )
    }
    
    private fun publishRoom(
        roomId: String,
        roomName: String,
        wsPort: Int,
        httpPort: Int,
        appVersion: String,
        codec: String,
        result: MethodChannel.Result
    ) {
        // 取消现有发布
        unpublishRoomInternal()
        
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = roomId
            serviceType = SERVICE_TYPE
            port = wsPort
            
            // 设置 TXT 记录属性
            setAttribute("roomId", roomId)
            setAttribute("roomName", roomName)
            setAttribute("hostWsPort", wsPort.toString())
            setAttribute("hostHttpPort", httpPort.toString())
            setAttribute("appVersion", appVersion)
            setAttribute("codec", codec)
        }
        
        currentServiceInfo = serviceInfo
        
        registrationListener = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                Log.e(TAG, "服务注册失败: $errorCode")
                mainHandler.post {
                    channel?.invokeMethod("onPublishError", mapOf(
                        "error" to "服务注册失败",
                        "errorCode" to errorCode
                    ))
                }
            }
            
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                Log.e(TAG, "服务取消注册失败: $errorCode")
            }
            
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo?) {
                Log.d(TAG, "服务已注册: ${serviceInfo?.serviceName}")
            }
            
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo?) {
                Log.d(TAG, "服务已取消注册")
            }
        }
        
        try {
            nsdManager?.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
            Log.d(TAG, "房间已发布: $roomId 端口: $wsPort")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "发布房间失败", e)
            result.error("PUBLISH_FAILED", e.message, null)
        }
    }
    
    private fun handleUnpublishRoom(result: MethodChannel.Result) {
        unpublishRoomInternal()
        result.success(null)
    }
    
    private fun unpublishRoomInternal() {
        registrationListener?.let {
            try {
                nsdManager?.unregisterService(it)
            } catch (e: Exception) {
                Log.e(TAG, "取消注册失败", e)
            }
        }
        registrationListener = null
        currentServiceInfo = null
        Log.d(TAG, "房间已取消发布")
    }
    
    // MARK: - Scan Rooms (Client)
    
    private fun handleStartScanning(result: MethodChannel.Result) {
        startScanning()
        result.success(null)
    }
    
    private fun handleStopScanning(result: MethodChannel.Result) {
        stopScanning()
        result.success(null)
    }
    
    private fun startScanning() {
        // 停止现有扫描
        stopScanning()
        
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.e(TAG, "开始发现失败: $errorCode")
                mainHandler.post {
                    channel?.invokeMethod("onScanError", mapOf(
                        "error" to "开始发现失败",
                        "errorCode" to errorCode
                    ))
                }
            }
            
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {
                Log.e(TAG, "停止发现失败: $errorCode")
            }
            
            override fun onDiscoveryStarted(serviceType: String?) {
                Log.d(TAG, "开始扫描房间")
            }
            
            override fun onDiscoveryStopped(serviceType: String?) {
                Log.d(TAG, "停止扫描房间")
            }
            
            override fun onServiceFound(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let {
                    Log.d(TAG, "发现服务: ${it.serviceName}")
                    resolveService(it)
                }
            }
            
            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {
                serviceInfo?.let {
                    Log.d(TAG, "服务丢失: ${it.serviceName}")
                    discoveredServices.remove(it.serviceName)
                    mainHandler.post {
                        channel?.invokeMethod("onRoomLost", mapOf(
                            "roomId" to it.serviceName
                        ))
                    }
                }
            }
        }
        
        try {
            nsdManager?.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            Log.e(TAG, "开始扫描失败", e)
            mainHandler.post {
                channel?.invokeMethod("onScanError", mapOf(
                    "error" to "开始扫描失败: ${e.message}"
                ))
            }
        }
    }
    
    private fun stopScanning() {
        discoveryListener?.let {
            try {
                nsdManager?.stopServiceDiscovery(it)
            } catch (e: Exception) {
                Log.e(TAG, "停止扫描失败", e)
            }
        }
        discoveryListener = null
        
        // 清理解析监听器
        resolveListeners.clear()
        discoveredServices.clear()
        
        // 通知 Flutter 清空列表
        mainHandler.post {
            channel?.invokeMethod("onRoomsCleared", null)
        }
        
        Log.d(TAG, "停止扫描房间")
    }
    
    private fun resolveService(serviceInfo: NsdServiceInfo) {
        val serviceName = serviceInfo.serviceName
        
        // 避免重复解析
        if (resolveListeners.containsKey(serviceName)) {
            return
        }
        
        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo?, errorCode: Int) {
                Log.e(TAG, "解析服务失败: $serviceName - $errorCode")
                resolveListeners.remove(serviceName)
            }
            
            override fun onServiceResolved(resolvedInfo: NsdServiceInfo?) {
                resolvedInfo?.let {
                    Log.d(TAG, "服务解析成功: ${it.serviceName}")
                    discoveredServices[serviceName] = it
                    notifyRoomDiscovered(it)
                }
                resolveListeners.remove(serviceName)
            }
        }
        
        resolveListeners[serviceName] = resolveListener
        
        try {
            nsdManager?.resolveService(serviceInfo, resolveListener)
        } catch (e: Exception) {
            Log.e(TAG, "解析服务异常", e)
            resolveListeners.remove(serviceName)
        }
    }
    
    private fun notifyRoomDiscovered(serviceInfo: NsdServiceInfo) {
        val hostIp = serviceInfo.host?.hostAddress ?: ""
        
        // 从属性中获取 TXT 记录
        val txtRecord = mutableMapOf<String, String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            serviceInfo.attributes.forEach { (key, value) ->
                val strValue = value?.let { String(it) } ?: ""
                txtRecord[key] = strValue
            }
        }
        
        val roomData = mapOf(
            "roomId" to (txtRecord["roomId"] ?: serviceInfo.serviceName),
            "roomName" to (txtRecord["roomName"] ?: "Unknown Room"),
            "hostIp" to hostIp,
            "hostWsPort" to (txtRecord["hostWsPort"]?.toIntOrNull() ?: serviceInfo.port),
            "hostHttpPort" to (txtRecord["hostHttpPort"]?.toIntOrNull() ?: 8080),
            "appVersion" to (txtRecord["appVersion"] ?: "1.0.0"),
            "codec" to (txtRecord["codec"] ?: "mp3")
        )
        
        // 必须在主线程调用 MethodChannel
        mainHandler.post {
            channel?.invokeMethod("onRoomDiscovered", roomData)
        }
        
        Log.d(TAG, "发现房间: ${serviceInfo.serviceName} IP: $hostIp")
    }
    
    // MARK: - Cleanup
    
    fun dispose() {
        unpublishRoomInternal()
        stopScanning()
        channel?.setMethodCallHandler(null)
        channel = null
        Log.d(TAG, "mDNS 服务已释放")
    }
}
