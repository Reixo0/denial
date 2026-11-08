import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../launcher/launcher_providers.dart';
import '../launcher/runtime_paths.dart';

/// What uses the microphone, the camera and the location right now, for the
/// status bar's indicator.
///
/// A device service writes it to `$XDG_RUNTIME_DIR/denial/privacy-usage.json`
/// whenever it changes, aside and renamed into place:
///
/// ```json
/// {"inUse": {"microphone": true, "camera": false, "location": false},
///  "microphone": ["firefox"], "camera": [], "location": []}
/// ```
///
/// The lists name the apps as they report themselves, and may be empty while
/// a kind is in use (location doesn't say which app asked). Without the file
/// nothing is in use.
class PrivacyUsage {
  const PrivacyUsage({
    this.microphone = false,
    this.camera = false,
    this.location = false,
    this.microphoneApps = const [],
    this.cameraApps = const [],
    this.locationApps = const [],
  });

  final bool microphone;
  final bool camera;
  final bool location;
  final List<String> microphoneApps;
  final List<String> cameraApps;
  final List<String> locationApps;

  bool get any => microphone || camera || location;

  /// The file's contents, or nothing in use for anything unreadable.
  factory PrivacyUsage.parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return const PrivacyUsage();
    }
    if (decoded is! Map<String, Object?>) return const PrivacyUsage();
    final Map<String, Object?> data = decoded;
    final inUse = data['inUse'];
    bool used(String kind) =>
        inUse is Map<String, Object?> && inUse[kind] == true;
    List<String> apps(String kind) {
      final list = data[kind];
      if (list is! List) return const [];
      return List.unmodifiable(list.whereType<String>());
    }

    return PrivacyUsage(
      microphone: used('microphone'),
      camera: used('camera'),
      location: used('location'),
      microphoneApps: apps('microphone'),
      cameraApps: apps('camera'),
      locationApps: apps('location'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrivacyUsage &&
      other.microphone == microphone &&
      other.camera == camera &&
      other.location == location &&
      _sameList(other.microphoneApps, microphoneApps) &&
      _sameList(other.cameraApps, cameraApps) &&
      _sameList(other.locationApps, locationApps);

  @override
  int get hashCode => Object.hash(
    microphone,
    camera,
    location,
    Object.hashAll(microphoneApps),
    Object.hashAll(cameraApps),
    Object.hashAll(locationApps),
  );

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final privacyUsageProvider =
    NotifierProvider<PrivacyUsageController, PrivacyUsage>(
      PrivacyUsageController.new,
    );

class PrivacyUsageController extends Notifier<PrivacyUsage> {
  static const _name = 'privacy-usage.json';

  File? _file;

  @override
  PrivacyUsage build() {
    final paths = ref.watch(runtimePathsProvider);
    final directory = _directory(paths);
    if (directory == null) return const PrivacyUsage();
    final file = File(p.join(directory.path, _name));
    _file = file;
    try {
      directory.createSync(recursive: true);
    } on FileSystemException {
      return const PrivacyUsage();
    }
    final subscription = directory
        .watch()
        .where(
          (event) =>
              p.basename(event.path) == _name ||
              (event is FileSystemMoveEvent &&
                  p.basename(event.destination ?? '') == _name),
        )
        .listen((_) => _follow(), onError: (Object _) {});
    ref.onDispose(subscription.cancel);
    return _read(file);
  }

  void _follow() {
    final file = _file;
    if (!ref.mounted || file == null) return;
    final next = _read(file);
    if (next != state) state = next;
  }

  static PrivacyUsage _read(File file) {
    try {
      return PrivacyUsage.parse(file.readAsStringSync());
    } on FileSystemException {
      return const PrivacyUsage();
    }
  }

  static Directory? _directory(RuntimePaths paths) {
    final runtime = paths.environment['XDG_RUNTIME_DIR'] ?? '';
    if (runtime.isEmpty) return null;
    return Directory(p.join(runtime, 'denial'));
  }
}
