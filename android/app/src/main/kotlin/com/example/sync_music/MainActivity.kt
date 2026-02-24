package com.example.sync_music

import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  private var multicastLock: WifiManager.MulticastLock? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    
    // 注册音频引擎
    AudioEngineManager.getInstance(context).registerChannels(flutterEngine)
    
    // 注册 mDNS 服务
    MdnsService.getInstance(context).setupChannel(flutterEngine.dartExecutor.binaryMessenger)
    
    // 获取 WiFi 多播锁
    acquireMulticastLock()
  }

  private fun acquireMulticastLock() {
    val wifiManager = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager?
    wifiManager?.let {
      multicastLock = it.createMulticastLock("sync_music_multicast")
      multicastLock?.setReferenceCounted(true)
      multicastLock?.acquire()
      android.util.Log.d("MainActivity", "WiFi 多播锁已获取")
    }
  }

  override fun onDestroy() {
    multicastLock?.release()
    MdnsService.getInstance(context).dispose()
    super.onDestroy()
  }
}
