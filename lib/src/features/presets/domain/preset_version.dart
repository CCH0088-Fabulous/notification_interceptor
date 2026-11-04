import 'filter_preset.dart';

/// A saved library definition, not a snapshot of the live rule engine.
class PresetVersion {
  const PresetVersion({
    required this.id,
    required this.createdAt,
    required this.label,
    required this.preset,
  });

  final String id;
  final int createdAt;
  final String label;
  final FilterPreset preset;

  factory PresetVersion.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final createdAt = json['createdAt'];
    final label = json['label'];
    final rawPreset = json['preset'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(id) ||
        createdAt is! int ||
        createdAt <= 0 ||
        createdAt > 8640000000000000 ||
        label is! String ||
        label.trim().isEmpty ||
        label != label.trim() ||
        label.length > 60 ||
        rawPreset is! Map ||
        rawPreset.keys.any((key) => key is! String)) {
      throw const FormatException('预设版本记录格式错误');
    }
    final preset = FilterPreset.fromJson(Map<String, dynamic>.from(rawPreset));
    return PresetVersion(
      id: id,
      createdAt: createdAt,
      label: label,
      preset: preset.copyWith(
        quietHours: preset.quietHours?.copyWith(
          days: Set.unmodifiable(preset.quietHours!.days),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt,
    'label': label,
    'preset': preset.toJson(),
  };
}
