import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The rear flash as a torch: the `*:flash-*` LEDs (group video may write
/// them, see the image's 70-nx809j-leds.rules). The level follows the
/// slider's Flashlight strength in `~/.config/denial/slider.json`, as
/// nx809j-slider and Phone Settings map it.
final flashlightProvider =
    NotifierProvider<FlashlightController, FlashlightState>(
      FlashlightController.new,
    );

class FlashlightState {
  const FlashlightState({this.available = false, this.on = false});

  final bool available;
  final bool on;
}

class FlashlightController extends Notifier<FlashlightState> {
  static final Directory _leds = Directory('/sys/class/leds');

  /// The torch level at full strength, of each LED's 255 (nx809j-slider's
  /// TORCH_MAX); the strength is 0.4 unless set.
  static const int _maxLevel = 150;
  static const double _defaultStrength = 0.4;

  @override
  FlashlightState build() => _read();

  /// Reads the LEDs again (the slider may have changed them).
  void refresh() {
    final next = _read();
    if (next.on != state.on || next.available != state.available) {
      state = next;
    }
  }

  Future<void> toggle() async {
    final level = state.on ? 0 : _level();
    for (final file in _files()) {
      try {
        await file.writeAsString('$level');
      } on FileSystemException {
        // A LED the user may not write: the state read below shows it.
      }
    }
    state = _read();
  }

  List<File> _files() {
    try {
      return <File>[
        for (final entry in _leds.listSync())
          if (entry.path.split('/').last.contains(':flash-'))
            File('${entry.path}/brightness'),
      ];
    } on FileSystemException {
      return const <File>[];
    }
  }

  FlashlightState _read() {
    final files = _files();
    if (files.isEmpty) return const FlashlightState();
    var on = false;
    for (final file in files) {
      try {
        if ((int.tryParse(file.readAsStringSync().trim()) ?? 0) > 0) on = true;
      } on FileSystemException {
        // Unreadable: count it as off.
      }
    }
    return FlashlightState(available: true, on: on);
  }

  int _level() {
    var strength = _defaultStrength;
    final home = Platform.environment['HOME'];
    if (home != null) {
      try {
        final settings = jsonDecode(
          File('$home/.config/denial/slider.json').readAsStringSync(),
        );
        final value = settings is Map ? settings['strength'] : null;
        if (value is num) strength = value.toDouble();
      } on Object {
        // No slider settings: the default strength.
      }
    }
    return (1 + strength.clamp(0.0, 1.0) * (_maxLevel - 1)).round();
  }
}
