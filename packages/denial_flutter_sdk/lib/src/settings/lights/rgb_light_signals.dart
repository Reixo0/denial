import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the lights' event effects follow on the system bus, as it changes:
/// whether a call rings (dmail's calls, whichever app shows them) and
/// whether the phone charges (UPower's display device). Both keep reporting
/// while the screen is off.
class RgbLightSignals {
  RgbLightSignals({DBusClient? systemBus})
    : _bus = systemBus ?? DBusClient.system();

  final DBusClient _bus;

  /// Whether a call is ringing: one of dmail's calls is incoming.
  Stream<bool> ringing() => _follow(
    DBusRemoteObject(
      _bus,
      name: 'org.dmail',
      path: DBusObjectPath('/org/dmail'),
    ),
    'org.dmail.Voice1',
    'Calls',
    (calls) =>
        calls is DBusArray &&
        calls.children.any(
          (call) =>
              call is DBusStruct &&
              call.children.length > 3 &&
              call.children[3] == const DBusString('incoming'),
        ),
  );

  /// Whether the phone charges: UPower's state 1.
  Stream<bool> charging() => _follow(
    DBusRemoteObject(
      _bus,
      name: 'org.freedesktop.UPower',
      path: DBusObjectPath('/org/freedesktop/UPower/devices/DisplayDevice'),
    ),
    'org.freedesktop.UPower.Device',
    'State',
    (state) => state == const DBusUint32(1),
  );

  /// `property` of `object` read through `test`, now and on each change,
  /// only when the answer changes. A service that is not there reads false.
  Stream<bool> _follow(
    DBusRemoteObject object,
    String interface,
    String property,
    bool Function(DBusValue value) test,
  ) {
    late final StreamController<bool> out;
    StreamSubscription<DBusPropertiesChangedSignal>? changes;
    bool? last;
    void emit(bool value) {
      if (value != last && !out.isClosed) {
        last = value;
        out.add(value);
      }
    }

    Future<void> read() async {
      try {
        emit(test(await object.getProperty(interface, property)));
      } on Object {
        emit(false);
      }
    }

    out = StreamController<bool>(
      onListen: () {
        changes = object.propertiesChanged.listen((signal) {
          if (signal.propertiesInterface != interface) return;
          final value = signal.changedProperties[property];
          if (value != null) {
            emit(test(value));
          } else if (signal.invalidatedProperties.contains(property)) {
            unawaited(read());
          }
        });
        unawaited(read());
      },
      onCancel: () => changes?.cancel(),
    );
    return out.stream;
  }

  Future<void> close() => _bus.close();
}

final rgbLightSignalsProvider = Provider<RgbLightSignals>((ref) {
  final signals = RgbLightSignals();
  ref.onDispose(() => unawaited(signals.close()));
  return signals;
});
