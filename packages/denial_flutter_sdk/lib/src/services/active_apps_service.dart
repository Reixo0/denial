import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// An Android app running a foreground service or a long job, as Android's
/// task manager ("apps are active") lists it.
@immutable
class ActiveApp {
  const ActiveApp({
    required this.package,
    required this.label,
    required this.desktopEntry,
    required this.since,
    required this.stoppable,
  });

  final String package;
  final String label;

  /// Its desktop entry, or empty.
  final String desktopEntry;
  final DateTime since;

  /// The user may stop it.
  final bool stoppable;

  @override
  bool operator ==(Object other) =>
      other is ActiveApp &&
      other.package == package &&
      other.label == label &&
      other.desktopEntry == desktopEntry &&
      other.since == since &&
      other.stoppable == stoppable;

  @override
  int get hashCode =>
      Object.hash(package, label, desktopEntry, since, stoppable);
}

/// Parses `org.droidloom.ActiveApps`' `Apps` property (a(sssxb)).
@visibleForTesting
List<ActiveApp> parseActiveApps(DBusValue? value) {
  if (value is! DBusArray) return const <ActiveApp>[];
  final apps = <ActiveApp>[];
  for (final item in value.children) {
    if (item is! DBusStruct) continue;
    if (item.children
        case [
          DBusString package,
          DBusString label,
          DBusString entry,
          DBusInt64 since,
          DBusBoolean stoppable,
        ]
        when package.value.isNotEmpty) {
      apps.add(
        ActiveApp(
          package: package.value,
          label: label.value.isEmpty ? package.value : label.value,
          desktopEntry: entry.value,
          since: DateTime.fromMillisecondsSinceEpoch(since.value),
          stoppable: stoppable.value,
        ),
      );
    }
  }
  return List<ActiveApp>.unmodifiable(apps);
}

/// Droidloom's active apps, while it runs.
class ActiveAppsService {
  ActiveAppsService({DBusClient? client})
    : _client = client ?? DBusClient.session();

  static const String _name = 'org.droidloom.ActiveApps';
  static const Duration _timeout = Duration(seconds: 3);

  final DBusClient _client;
  late final DBusRemoteObject _object = DBusRemoteObject(
    _client,
    name: _name,
    path: DBusObjectPath('/org/droidloom/ActiveApps'),
  );
  final StreamController<List<ActiveApp>> _changes =
      StreamController<List<ActiveApp>>.broadcast();
  StreamSubscription<DBusNameOwnerChangedEvent>? _owner;
  StreamSubscription<DBusPropertiesChangedSignal>? _properties;
  List<ActiveApp> _current = const <ActiveApp>[];
  bool _disposed = false;
  int _reads = 0;

  List<ActiveApp> get current => _current;
  Stream<List<ActiveApp>> get changes => _changes.stream;

  Future<void> start() async {
    if (_owner != null || _disposed) return;
    _owner = _client.nameOwnerChanged
        .where((event) => event.name == _name)
        .listen((event) {
          if (event.newOwner == null) {
            _reads++;
            _set(const <ActiveApp>[]);
          } else {
            unawaited(_read());
          }
        });
    _properties = _object.propertiesChanged.listen((signal) {
      if (signal.propertiesInterface != _name) return;
      final apps = signal.changedProperties['Apps'];
      if (apps != null) {
        _reads++;
        _set(parseActiveApps(apps));
      }
    });
    await _read();
  }

  Future<void> _read() async {
    final read = ++_reads;
    try {
      final value = await _object.getProperty(_name, 'Apps').timeout(_timeout);
      if (read == _reads) _set(parseActiveApps(value));
    } on Object {
      // Droidloom does not run, or is older.
      if (read == _reads) _set(const <ActiveApp>[]);
    }
  }

  void _set(List<ActiveApp> apps) {
    if (_disposed || listEquals(apps, _current)) return;
    _current = apps;
    _changes.add(apps);
  }

  /// Stops [package], as the task manager's Stop button.
  Future<void> stop(String package) async {
    try {
      await _object
          .callMethod(_name, 'Stop', <DBusValue>[
            DBusString(package),
          ], replySignature: DBusSignature(''))
          .timeout(_timeout);
    } on Object {
      // Gone meanwhile.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _owner?.cancel();
    await _properties?.cancel();
    await _changes.close();
    await _client.close();
  }
}

final activeAppsServiceProvider = Provider<ActiveAppsService>((ref) {
  final service = ActiveAppsService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final activeAppsProvider = StreamProvider<List<ActiveApp>>((ref) async* {
  final service = ref.watch(activeAppsServiceProvider);
  await service.start();
  yield service.current;
  yield* service.changes;
});
