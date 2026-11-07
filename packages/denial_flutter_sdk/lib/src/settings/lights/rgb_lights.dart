import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../launcher/runtime_paths.dart';

/// RGB lights exposed as multicolor LEDs named `rgb:<name>`, such as the
/// NX809J's logo, "game mode" light, shoulder trigger lights and fan zones.
/// Phone Settings (denial-apps) sets them and keeps the choice in
/// `rgb-lights.json`; the shell puts it back when it starts.

const _ledClass = '/sys/class/leds';
const _prefix = 'rgb:';
const _fan = 'fan';

enum RgbLightEffect { solid, breathe, blink }

class RgbLightSetting {
  const RgbLightSetting({
    this.on = false,
    this.color = 0xff0000,
    this.brightness = 1,
    this.effect = RgbLightEffect.solid,
    this.speed = 0.5,
  });

  final bool on;

  /// 0xRRGGBB.
  final int color;

  /// 0 to 1.
  final double brightness;
  final RgbLightEffect effect;

  /// How fast breathing and blinking go: 0 slowest to 1 fastest.
  final double speed;

  static RgbLightSetting fromJson(Object? json) {
    if (json is! Map) {
      return const RgbLightSetting();
    }
    final color = json['color'];
    final brightness = json['brightness'];
    final speed = json['speed'];
    return RgbLightSetting(
      on: json['on'] == true,
      color: color is int ? color & 0xffffff : 0xff0000,
      brightness: brightness is num ? brightness.toDouble().clamp(0.0, 1.0) : 1,
      effect: RgbLightEffect.values.firstWhere(
        (effect) => effect.name == json['effect'],
        orElse: () => RgbLightEffect.solid,
      ),
      speed: speed is num ? speed.toDouble().clamp(0.0, 1.0) : 0.5,
    );
  }
}

class RgbLightsSettings {
  const RgbLightsSettings({
    this.lights = const {},
    this.fanZonesSeparate = false,
  });

  /// By light: logo, gamemode, trigger-left, trigger-right, fan (all its
  /// zones together) and fan-1 to fan-4 (zones on their own).
  final Map<String, RgbLightSetting> lights;
  final bool fanZonesSeparate;

  /// What `led` shows: a fan zone takes the fan's setting unless the zones
  /// are set on their own.
  RgbLightSetting forLed(String led) {
    final light = led.startsWith('$_fan-') && !fanZonesSeparate ? _fan : led;
    return lights[light] ?? const RgbLightSetting();
  }

  static RgbLightsSettings fromJson(Object? json) {
    if (json is! Map) {
      return const RgbLightsSettings();
    }
    final lights = json['lights'];
    return RgbLightsSettings(
      fanZonesSeparate: json['fanZonesSeparate'] == true,
      lights: lights is Map
          ? {
              for (final entry in lights.entries)
                if (entry.key is String)
                  entry.key as String: RgbLightSetting.fromJson(entry.value),
            }
          : const {},
    );
  }
}

class RgbLights {
  RgbLights({Map<String, String>? environment})
    : _paths = RuntimePaths(environment: environment ?? Platform.environment);

  final RuntimePaths _paths;

  File get _file =>
      File(p.join(_paths.configHome, 'denial', 'rgb-lights.json'));

  /// The LEDs present, without the `rgb:` prefix (logo, fan-1, ...).
  Future<List<String>> leds() async {
    final dir = Directory(_ledClass);
    if (!await dir.exists()) {
      return const [];
    }
    final names = <String>[];
    await for (final entry in dir.list()) {
      final name = p.basename(entry.path);
      if (name.startsWith(_prefix)) {
        names.add(name.substring(_prefix.length));
      }
    }
    return names..sort();
  }

  Future<RgbLightsSettings> load() async {
    try {
      return RgbLightsSettings.fromJson(jsonDecode(await _file.readAsString()));
    } on Object {
      return const RgbLightsSettings();
    }
  }

  /// Show settings on every LED present.
  Future<void> applyAll(RgbLightsSettings settings) async {
    for (final led in await leds()) {
      await apply(led, settings.forLed(led));
    }
  }

  /// Show setting on one LED, as Phone Settings does: the colour at full
  /// intensity and the brightness in the LED's brightness; breathing and
  /// blinking as a hardware pattern on the chip.
  Future<void> apply(String led, RgbLightSetting setting) async {
    final dir = p.join(_ledClass, '$_prefix$led');
    final patterned = (await File(
      p.join(dir, 'trigger'),
    ).readAsString()).contains('[pattern]');
    final level = (setting.brightness * 255).round().clamp(1, 255);
    final rgb =
        '${setting.color >> 16 & 0xff} ${setting.color >> 8 & 0xff} '
        '${setting.color & 0xff}';
    if (!setting.on) {
      if (patterned) {
        await _write(dir, 'trigger', 'none');
      }
      await _write(dir, 'brightness', '0');
      return;
    }
    switch (setting.effect) {
      case RgbLightEffect.solid:
        if (patterned) {
          await _write(dir, 'trigger', 'none');
        }
        await _write(dir, 'multi_intensity', rgb);
        await _write(dir, 'brightness', '$level');
      case RgbLightEffect.breathe:
        final ms = _halfPeriod(setting.speed, 3000, 300);
        await _pattern(dir, rgb, '0 $ms $level $ms');
      case RgbLightEffect.blink:
        final ms = _halfPeriod(setting.speed, 1200, 100);
        await _pattern(dir, rgb, '$level $ms $level 1 0 $ms 0 1');
    }
  }

  /// Half an effect's cycle in ms at speed, as Phone Settings has it.
  static int _halfPeriod(double speed, double slowest, double fastest) =>
      (slowest + (fastest - slowest) * speed.clamp(0.0, 1.0)).round();

  Future<void> _pattern(String dir, String rgb, String steps) async {
    await _write(dir, 'multi_intensity', rgb);
    await _write(dir, 'trigger', 'pattern');
    // hw_pattern comes with the trigger; udev opens it to us just after
    for (var attempt = 0; ; attempt++) {
      try {
        await _write(dir, 'hw_pattern', steps);
        return;
      } on FileSystemException {
        if (attempt >= 20) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  Future<void> _write(String dir, String attribute, String value) =>
      File(p.join(dir, attribute)).writeAsString(value, flush: true);
}

final rgbLightsProvider = Provider<RgbLights>((ref) => RgbLights());
