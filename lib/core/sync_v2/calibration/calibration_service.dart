import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../diagnostics/sync_log.dart';

/// 校准服务 - 管理耳朵校准偏移值
/// 用于补偿音频输出链路延迟（有线耳机、蓝牙耳机等）
class CalibrationService extends ChangeNotifier {
  static const String _keyCalibrationOffsetMs = 'sync_calibration_offset_ms';
  static const String _keyLatencyCompMs = 'sync_latency_comp_ms';
  static const String _keyDeviceAutoApplied = 'sync_device_auto_applied';

  SharedPreferences? _prefs;
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  // 校准偏移（正值=让本机更晚播放，负值=让本机更早播放）
  int _calibrationOffsetMs = 0;

  // 延迟补偿（网络+音频输出延迟）
  int _latencyCompMs = 100;

  // 是否已初始化
  bool _initialized = false;

  // 当前设备型号
  String _deviceModel = '';

  /// 获取校准偏移值
  int get calibrationOffsetMs => _calibrationOffsetMs;

  /// 获取延迟补偿值
  int get latencyCompMs => _latencyCompMs;

  /// 获取总补偿值（校准偏移 + 延迟补偿）
  int get totalCompensationMs => _calibrationOffsetMs + _latencyCompMs;

  /// 是否已初始化
  bool get initialized => _initialized;

  /// 获取当前设备型号
  String get deviceModel => _deviceModel;

  /// 设备预设配置表
  static const Map<String, DeviceCalibrationPreset> _devicePresets = {
    // MI 8 Lite (platina)
    'platina': DeviceCalibrationPreset(
      modelPattern: 'platina',
      calibrationOffsetMs: 50,
      latencyCompMs: 60,
    ),
    'MI 8 Lite': DeviceCalibrationPreset(
      modelPattern: 'MI 8 Lite',
      calibrationOffsetMs: 50,
      latencyCompMs: 60,
    ),
    // 可添加更多设备预设...
  };

  /// 初始化服务（从 SharedPreferences 加载）
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();

      // 获取设备型号
      await _detectDeviceModel();

      // 检查是否已自动应用过设备预设
      final autoApplied = _prefs?.getBool(_keyDeviceAutoApplied) ?? false;

      if (!autoApplied) {
        // 尝试自动应用设备预设
        await _autoApplyDevicePreset();
      } else {
        // 加载已保存的值
        _calibrationOffsetMs = _prefs?.getInt(_keyCalibrationOffsetMs) ?? 0;
        _latencyCompMs = _prefs?.getInt(_keyLatencyCompMs) ?? 100;
      }

      _initialized = true;

      SyncLog.i(
        '[Calibration] 已加载: device=$_deviceModel offset=$_calibrationOffsetMs ms latencyComp=$_latencyCompMs ms autoApplied=${_prefs?.getBool(_keyDeviceAutoApplied) ?? false}',
      );
    } catch (e) {
      SyncLog.e('[Calibration] 加载失败: $e');
      _initialized = true;
    }

    notifyListeners();
  }

  /// 检测设备型号
  Future<void> _detectDeviceModel() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await _deviceInfo.androidInfo;
        _deviceModel = androidInfo.model;
        SyncLog.i(
          '[Calibration] 检测到 Android 设备: model=${androidInfo.model} device=${androidInfo.device}',
        );
      } else if (Platform.isIOS) {
        final iosInfo = await _deviceInfo.iosInfo;
        _deviceModel = iosInfo.model;
        SyncLog.i('[Calibration] 检测到 iOS 设备: model=${iosInfo.model}');
      }
    } catch (e) {
      SyncLog.e('[Calibration] 设备检测失败: $e');
      _deviceModel = '';
    }
  }

  /// 自动应用设备预设
  Future<void> _autoApplyDevicePreset() async {
    final preset = _findDevicePreset();
    if (preset != null) {
      _calibrationOffsetMs = preset.calibrationOffsetMs;
      _latencyCompMs = preset.latencyCompMs;
    } else if (Platform.isIOS) {
      _calibrationOffsetMs = 150;
      _latencyCompMs = 100;
    } else {
      return;
    }

    await _prefs?.setInt(_keyCalibrationOffsetMs, _calibrationOffsetMs);
    await _prefs?.setInt(_keyLatencyCompMs, _latencyCompMs);
    await _prefs?.setBool(_keyDeviceAutoApplied, true);

    SyncLog.i(
      '[Calibration] 自动应用设备预设: device=$_deviceModel offset=$_calibrationOffsetMs ms latencyComp=$_latencyCompMs ms',
    );
  }

  /// 查找设备预设
  DeviceCalibrationPreset? _findDevicePreset() {
    for (final entry in _devicePresets.entries) {
      if (_deviceModel.toLowerCase().contains(entry.key.toLowerCase())) {
        return entry.value;
      }
    }
    return null;
  }

  /// 设置校准偏移值
  Future<bool> setCalibrationOffset(int offsetMs) async {
    _calibrationOffsetMs = offsetMs.clamp(-300, 300);

    try {
      await _prefs?.setInt(_keyCalibrationOffsetMs, _calibrationOffsetMs);
      SyncLog.i('[Calibration] 已保存校准偏移: $_calibrationOffsetMs ms');
      notifyListeners();
      return true;
    } catch (e) {
      SyncLog.e('[Calibration] 保存失败: $e');
      return false;
    }
  }

  /// 设置延迟补偿值
  Future<bool> setLatencyComp(int latencyMs) async {
    _latencyCompMs = latencyMs.clamp(0, 500);

    try {
      await _prefs?.setInt(_keyLatencyCompMs, _latencyCompMs);
      SyncLog.i('[Calibration] 已保存延迟补偿: $_latencyCompMs ms');
      notifyListeners();
      return true;
    } catch (e) {
      SyncLog.e('[Calibration] 保存失败: $e');
      return false;
    }
  }

  /// 重置所有校准值
  Future<void> reset() async {
    _calibrationOffsetMs = 0;
    _latencyCompMs = 100;

    await _prefs?.remove(_keyCalibrationOffsetMs);
    await _prefs?.setInt(_keyLatencyCompMs, _latencyCompMs);
    await _prefs?.setBool(_keyDeviceAutoApplied, false);

    SyncLog.i('[Calibration] 已重置');
    notifyListeners();
  }

  /// 应用预设值
  Future<void> applyPreset(CalibrationPreset preset) async {
    await setLatencyComp(preset.latencyCompMs);
    await setCalibrationOffset(preset.calibrationOffsetMs);
  }
}

/// 设备校准预设
class DeviceCalibrationPreset {
  final String modelPattern;
  final int calibrationOffsetMs;
  final int latencyCompMs;

  const DeviceCalibrationPreset({
    required this.modelPattern,
    required this.calibrationOffsetMs,
    required this.latencyCompMs,
  });
}

/// 校准预设
enum CalibrationPreset {
  wiredHeadphones('有线耳机', 80, 0),
  bluetoothHeadphones('蓝牙耳机', 150, 0),
  bluetoothDelayed('蓝牙+延迟', 200, 50),
  custom('自定义', 100, 0);

  final String label;
  final int latencyCompMs;
  final int calibrationOffsetMs;

  const CalibrationPreset(
    this.label,
    this.latencyCompMs,
    this.calibrationOffsetMs,
  );
}
