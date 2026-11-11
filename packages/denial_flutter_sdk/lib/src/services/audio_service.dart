import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audio.dart';
import '../platform/denial_bridge.dart';
import '../platform/denial_bridge_provider.dart';

export '../models/audio.dart';

final audioServiceProvider = Provider<AudioService>((ref) {
  return AudioService(ref.watch(denialBridgeProvider));
});

/// Controls the default output through deniald's persistent native audio
/// bridge. The embedded Dart runtime must never spawn a CLI for this path.
class AudioService {
  const AudioService(this._bridge);

  final DenialBridge _bridge;

  /// Reads the current default-sink volume as a normalized value.
  Future<double?> readLevel() => _bridge.readAudioLevel();

  Stream<AudioLevelState> get states => _bridge.audioStates;

  Stream<List<AppAudioStream>> get appStreamStates => _bridge.audioStreamStates;

  Stream<List<AudioOutputDevice>> get outputDeviceStates =>
      _bridge.audioDeviceStates;

  /// A volume per kind of sound; empty when the system has none.
  Stream<List<AudioRoleLevel>> get roleStates => _bridge.audioRoleStates;

  void apply(int percent, {required int requestSerial}) {
    _bridge.setAudioLevel(percent, requestSerial: requestSerial);
  }

  void requestAppStreams() => _bridge.requestAudioStreams();

  void requestOutputDevices() => _bridge.requestAudioDevices();

  void applyAppStream(int streamId, int percent) {
    _bridge.setAudioStreamLevel(streamId, percent);
  }

  void selectOutputDevice(String name) => _bridge.setAudioDevice(name);

  void requestRoles() => _bridge.requestAudioRoles();

  void applyRole(AudioRole role, int percent) {
    _bridge.setAudioRoleLevel(role, percent);
  }
}
