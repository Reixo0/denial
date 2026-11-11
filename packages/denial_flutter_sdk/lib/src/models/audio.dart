class AudioLevelState {
  const AudioLevelState({
    required this.level,
    required this.requestSerial,
    this.muted = false,
    this.limitReached = false,
    this.completesRead = false,
  });

  final double level;
  final int requestSerial;
  final bool muted;
  final bool limitReached;

  /// Whether this update satisfied an explicit state read from Dart.
  ///
  /// Reconciliation reads update controls but should not look like a fresh
  /// hardware-key interaction to transient shell surfaces.
  final bool completesRead;
}

class AppAudioStream {
  const AppAudioStream({
    required this.id,
    required this.name,
    required this.level,
    required this.muted,
  });

  final int id;
  final String name;
  final double level;
  final bool muted;

  AppAudioStream copyWith({double? level, bool? muted}) {
    if ((level == null || level == this.level) &&
        (muted == null || muted == this.muted)) {
      return this;
    }
    return AppAudioStream(
      id: id,
      name: name,
      level: level ?? this.level,
      muted: muted ?? this.muted,
    );
  }
}

class AudioOutputDevice {
  const AudioOutputDevice({
    required this.name,
    required this.description,
    required this.active,
    required this.available,
  });

  final String name;
  final String description;
  final bool active;
  final bool available;
}

/// A kind of sound with a volume of its own, as on Android. The values are
/// deniald's role numbers.
enum AudioRole { media, notification, ringtone, alarm, call }

class AudioRoleLevel {
  const AudioRoleLevel({
    required this.role,
    required this.level,
    required this.muted,
    required this.active,
  });

  final AudioRole role;
  final double level;
  final bool muted;

  /// The main level (volume keys, the level slider) sets this role now: the
  /// call during a call, a sounding alarm or ringtone, else media.
  final bool active;

  AudioRoleLevel copyWith({double? level}) => AudioRoleLevel(
    role: role,
    level: level ?? this.level,
    muted: muted,
    active: active,
  );
}
