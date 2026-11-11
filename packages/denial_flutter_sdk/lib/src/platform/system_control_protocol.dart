import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../models/audio.dart' show AudioRole;
import 'denial_bridge_models.dart';

/// Decodes native system-control messages independently of transport and state.
/// Records contain only wire data; the bridge determines which reads complete.
abstract final class SystemControlProtocol {
  /// `quiet`: the level is another sound's now (a ringtone started or
  /// stopped), not a change anyone made.
  static ({
    double level,
    int requestSerial,
    bool muted,
    bool limitReached,
    bool quiet,
  })?
  decodeAudioState(ByteData? data) {
    if (data == null || data.lengthInBytes < 1) return null;
    return (
      level: _percent(data, 0),
      requestSerial: data.lengthInBytes >= 5
          ? data.getUint32(1, Endian.little)
          : 0,
      muted: data.lengthInBytes >= 6 && data.getUint8(5) != 0,
      limitReached: data.lengthInBytes >= 7 && data.getUint8(6) != 0,
      quiet: data.lengthInBytes >= 8 && data.getUint8(7) != 0,
    );
  }

  static List<DenialAudioStream>? decodeAudioStreams(ByteData? data) {
    if (data == null || data.lengthInBytes < 4) return null;
    final count = data.getUint32(0, Endian.little);
    // Even empty names require a complete fixed header per entry. Reject an
    // impossible count before allocating models or decoding any strings.
    if (count > (data.lengthInBytes - 4) ~/ 8) return null;
    if (count == 0) return const [];
    final streams = <DenialAudioStream>[];
    final bytes = Uint8List.sublistView(data);
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 8 > data.lengthInBytes) return null;
      final id = data.getUint32(offset, Endian.little);
      final level = _percent(data, offset + 4);
      final muted = data.getUint8(offset + 5) != 0;
      final nameLength = data.getUint16(offset + 6, Endian.little);
      offset += 8;
      if (offset + nameLength > data.lengthInBytes) return null;
      streams.add(
        DenialAudioStream(
          id: id,
          name: _text(bytes, offset, nameLength),
          level: level,
          muted: muted,
        ),
      );
      offset += nameLength;
    }
    return UnmodifiableListView(streams);
  }

  static List<DenialAudioDevice>? decodeAudioDevices(ByteData? data) {
    if (data == null || data.lengthInBytes < 4) return null;
    final count = data.getUint32(0, Endian.little);
    if (count > (data.lengthInBytes - 4) ~/ 6) return null;
    if (count == 0) return const [];
    final devices = <DenialAudioDevice>[];
    final bytes = Uint8List.sublistView(data);
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + 6 > data.lengthInBytes) return null;
      final active = data.getUint8(offset) != 0;
      final available = data.getUint8(offset + 1) != 0;
      final nameLength = data.getUint16(offset + 2, Endian.little);
      final descriptionLength = data.getUint16(offset + 4, Endian.little);
      offset += 6;
      if (offset + nameLength + descriptionLength > data.lengthInBytes) {
        return null;
      }
      devices.add(
        DenialAudioDevice(
          name: _text(bytes, offset, nameLength),
          description: _text(bytes, offset + nameLength, descriptionLength),
          active: active,
          available: available,
        ),
      );
      offset += nameLength + descriptionLength;
    }
    return UnmodifiableListView(devices);
  }

  /// Four bytes per role: role, level percent, muted, active. Empty without
  /// role volumes.
  static List<DenialAudioRole>? decodeAudioRoles(ByteData? data) {
    if (data == null || data.lengthInBytes % 4 != 0) return null;
    final roles = <DenialAudioRole>[];
    for (var offset = 0; offset < data.lengthInBytes; offset += 4) {
      final role = data.getUint8(offset);
      if (role >= AudioRole.values.length) return null;
      roles.add(
        DenialAudioRole(
          role: AudioRole.values[role],
          level: _percent(data, offset + 1),
          muted: data.getUint8(offset + 2) != 0,
          active: data.getUint8(offset + 3) != 0,
        ),
      );
    }
    return UnmodifiableListView(roles);
  }

  static ({int monitorId, double level})? decodeBrightness(ByteData? data) {
    if (data == null || data.lengthInBytes < 9) return null;
    final monitorId = data.getInt64(0, Endian.little);
    if (monitorId < 0) return null;
    return (monitorId: monitorId, level: _percent(data, 8));
  }

  static ({int monitorId, double level, bool supported})? decodeSoftwareDimming(
    ByteData? data,
  ) {
    if (data == null || data.lengthInBytes < 10) return null;
    final monitorId = data.getInt64(0, Endian.little);
    if (monitorId <= 0) return null;
    return (
      monitorId: monitorId,
      level: _percent(data, 8),
      supported: data.getUint8(9) != 0,
    );
  }

  static double _percent(ByteData data, int offset) =>
      data.getUint8(offset).clamp(0, 100) / 100.0;

  static String _text(Uint8List bytes, int offset, int length) =>
      const Utf8Decoder(allowMalformed: true)
          .convert(bytes, offset, offset + length);
}
