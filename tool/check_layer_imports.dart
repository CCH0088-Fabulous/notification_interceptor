// 分层依赖校验：把 structure.md 的架构约束变成可执行检查。
// 用法：dart run tool/check_layer_imports.dart

import 'dart:io';

const _rules = <String, String>{
  'L1': 'core 不得依赖任何 feature',
  'L2': 'domain 不得依赖 Flutter、channel 或 data',
  'L3': 'presentation 不得依赖本 feature 的 data，也不得跨 feature 依赖 data/presentation',
  'L4': '只有 data 层与 core/channel 可以创建 MethodChannel / EventChannel',
  'L5': '原生 domain 包不得 import android.*',
};

final _violations = <String>[];

void main() {
  final libRoot = Directory('lib/src');
  if (libRoot.existsSync()) {
    for (final file in libRoot.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart')) _checkDart(file);
    }
  }

  final kotlinRoot = Directory('android/app/src/main/kotlin');
  if (kotlinRoot.existsSync()) {
    for (final file in kotlinRoot.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.kt')) _checkKotlinDomain(file);
    }
  }

  if (_violations.isEmpty) {
    stdout.writeln('分层依赖检查通过：共 ${_rules.length} 条规则。');
    exit(0);
  }

  stderr.writeln('分层依赖检查失败：');
  for (final violation in _violations) {
    stderr.writeln('  - $violation');
  }
  exit(1);
}

void _checkDart(File file) {
  final normalized = file.path.replaceAll(r'\', '/');
  final lines = file.readAsStringSync().split('\n');
  final feature = RegExp(r'lib/src/features/([^/]+)/').firstMatch(normalized)?.group(1);
  final inCore = normalized.contains('lib/src/core/');
  final inDomain = feature != null && normalized.contains('/domain/');
  final inPresentation = feature != null && normalized.contains('/presentation/');
  final inChannel = normalized.contains('lib/src/core/channel/');
  final inData = normalized.contains('/data/');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimLeft();

    if (line.startsWith('import ')) {
      final target = _importTarget(line)?.replaceAll(r'\', '/');
      if (target == null) continue;

      if (inCore && target.contains('/features/')) {
        _add(file, i, 'L1', 'core 引用了 feature：$target');
      }
      if (inDomain && (target.startsWith('package:flutter/') || target.contains('/core/channel'))) {
        _add(file, i, 'L2', 'domain 引用了 Flutter 或 channel：$target');
      }
      if (inDomain && target.contains('/data/')) {
        _add(file, i, 'L2', 'domain 引用了 data 层：$target');
      }
      if (inPresentation && target.contains('/data/')) {
        _add(file, i, 'L3', 'presentation 直接引用了 data 层：$target');
      }
      if (inPresentation) {
        final other = RegExp(r'/features/([^/]+)/(data|presentation)/').firstMatch(target);
        if (other != null && other.group(1) != feature) {
          _add(file, i, 'L3', '跨 feature 依赖：$target');
        }
      }
    }

    if (!inChannel && !inData &&
        (line.contains('MethodChannel(') || line.contains('EventChannel('))) {
      _add(file, i, 'L4', '在 data 层之外创建通道');
    }
  }
}

void _checkKotlinDomain(File file) {
  final normalized = file.path.replaceAll(r'\', '/');
  if (!normalized.contains('/domain/')) return;
  final lines = file.readAsStringSync().split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('import android.')) {
      _add(file, i, 'L5', '原生 domain 引用了 Android 框架类');
    }
  }
}

String? _importTarget(String line) {
  final match = RegExp(r"""import\s+['"]([^'"]+)['"]""").firstMatch(line);
  return match?.group(1);
}

void _add(File file, int index, String rule, String message) {
  _violations.add('${file.path}:${index + 1} [$rule] $message');
}
