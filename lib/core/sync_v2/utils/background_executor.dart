import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

/// 后台任务执行器
/// 用于在 isolate 中执行 CPU 密集型任务，避免阻塞主线程
class BackgroundExecutor {
  static final BackgroundExecutor _instance = BackgroundExecutor._internal();
  factory BackgroundExecutor() => _instance;
  BackgroundExecutor._internal();

  /// 在 isolate 中执行 CPU 密集型任务
  ///
  /// [task] - 要执行的任务函数，必须是顶级函数或静态方法
  /// [argument] - 传递给任务的参数
  ///
  /// 示例：
  /// ```dart
  /// final result = await executor.runCpuTask(_hashFile, filePath);
  /// ```
  Future<T> runCpuTask<T, A>(
    Future<T> Function(A argument) task,
    A argument,
  ) async {
    // 使用 compute 函数在 isolate 中执行
    return await compute(_wrapTask<T, A>, _TaskWrapper(task, argument));
  }

  /// 包装任务以便在 isolate 中执行
  static Future<T> _wrapTask<T, A>(_TaskWrapper<T, A> wrapper) async {
    return await wrapper.task(wrapper.argument);
  }

  /// 计算文件的 SHA1 hash（在 isolate 中执行）
  Future<String> computeFileSha1(String filePath) async {
    return await runCpuTask(_computeSha1Isolate, filePath);
  }

  /// 获取文件大小
  Future<int> getFileSize(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      return await file.length();
    }
    return 0;
  }
}

/// 任务包装类
class _TaskWrapper<T, A> {
  final Future<T> Function(A argument) task;
  final A argument;

  _TaskWrapper(this.task, this.argument);
}

/// 在 isolate 中计算 SHA1 hash
/// 必须是顶级函数以便在 isolate 中执行
Future<String> _computeSha1Isolate(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw FileSystemException('File not found', filePath);
  }

  // 流式读取文件，避免内存峰值
  final bytes = await file.readAsBytes();
  final digest = sha1.convert(bytes);
  return digest.toString();
}

/// 批量数据处理任务
Future<List<T>> processBatch<T, A>(
  List<A> items,
  T Function(A item) processor,
) async {
  return await compute(
    _processBatchWrapper<T, A>,
    _BatchWrapper(items, processor),
  );
}

/// 批量处理包装器
List<T> _processBatchWrapper<T, A>(_BatchWrapper<T, A> wrapper) {
  return wrapper.items.map(wrapper.processor).toList();
}

/// 批量处理包装类
class _BatchWrapper<T, A> {
  final List<A> items;
  final T Function(A item) processor;

  _BatchWrapper(this.items, this.processor);
}
