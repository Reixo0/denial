import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the system lists what the power menu's Restart offers.
const String restartTargetsPath = '/etc/denial/restart-targets.json';

/// One choice under Restart: a plain restart through logind, or a systemd
/// unit that restarts into something else (another system on a dual-boot
/// phone, its bootloader).
///
/// The file is `{"targets": [{"label": "System", "icon": "restart",
/// "unit": "example-reboot.service"}, ...]}`; a target without `unit`
/// restarts through logind. The session must be allowed to start each unit
/// (a polkit rule for `org.freedesktop.systemd1.manage-units`).
@immutable
class RestartTarget {
  const RestartTarget({required this.label, this.icon = 'restart', this.unit});

  final String label;

  /// One of `restart`, `android`, `linux`, `bootloader`, `recovery`, `shell`.
  final String icon;

  /// The systemd unit to start, or null for logind's Reboot.
  final String? unit;

  static const RestartTarget system = RestartTarget(label: 'System');

  static RestartTarget? fromJson(Object? value) {
    if (value is! Map) return null;
    final label = value['label'];
    if (label is! String || label.isEmpty || label.length > 40) return null;
    final icon = value['icon'];
    final unit = value['unit'];
    if (unit != null &&
        (unit is! String ||
            !RegExp(r'^[A-Za-z0-9:_.@-]+\.(service|target)$').hasMatch(unit))) {
      return null;
    }
    return RestartTarget(
      label: label,
      icon: icon is String ? icon : 'restart',
      unit: unit as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RestartTarget &&
      other.label == label &&
      other.icon == icon &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(label, icon, unit);
}

/// The Restart choices; a single plain restart when the system lists none.
final restartTargetsProvider = FutureProvider<List<RestartTarget>>((ref) async {
  try {
    final text = await File(restartTargetsPath).readAsString();
    final json = jsonDecode(text);
    final list = json is Map ? json['targets'] : null;
    if (list is List) {
      final targets = list
          .map(RestartTarget.fromJson)
          .whereType<RestartTarget>()
          .take(6)
          .toList(growable: false);
      if (targets.isNotEmpty) return targets;
    }
  } on Object {
    // No file or a broken one: the plain restart below.
  }
  return const <RestartTarget>[RestartTarget.system];
});

/// Starts [unit] through systemd on the system bus.
Future<void> startSystemdUnit(String unit) async {
  final client = DBusClient.system();
  try {
    await DBusRemoteObject(
      client,
      name: 'org.freedesktop.systemd1',
      path: DBusObjectPath('/org/freedesktop/systemd1'),
    ).callMethod(
      'org.freedesktop.systemd1.Manager',
      'StartUnit',
      <DBusValue>[DBusString(unit), const DBusString('replace')],
      replySignature: DBusSignature('o'),
    ).timeout(const Duration(seconds: 10));
  } finally {
    await client.close();
  }
}
