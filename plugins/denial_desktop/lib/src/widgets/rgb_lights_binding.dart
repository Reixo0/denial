import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

/// Puts the RGB lights back as the Lights settings page left them when the
/// shell starts, and plays the light effects set for events over them: an
/// incoming call or a ringing alarm while it goes on, a new notification for
/// the time set, charging while the phone charges. Calls and charging come
/// from the system bus, so they show with the screen off too. The most
/// important event going on shows, on the lights it is set for; when none
/// does, the lights go back. The settings app changes the lights live
/// itself.
class RgbLightsBinding extends ConsumerStatefulWidget {
  const RgbLightsBinding({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RgbLightsBinding> createState() => _RgbLightsBindingState();
}

class _RgbLightsBindingState extends ConsumerState<RgbLightsBinding> {
  /// Settings changes come as a few file events; one reload follows them.
  static const _settle = Duration(milliseconds: 300);

  late final RgbLights _lights = ref.read(rgbLightsProvider);
  RgbLightsSettings _settings = const RgbLightsSettings();
  bool _loaded = false;

  /// The event shown, or null for the lights as set; unknown before the
  /// first write.
  RgbLightEvent? _shown;
  bool _shownAny = false;
  Timer? _notification;
  Timer? _reloadSoon;
  bool _ringing = false;
  bool _charging = false;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Writes go one after another.
  Future<void> _writes = Future<void>.value();

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      desktopNotificationsProvider.select((state) => state.lastEvent),
      (_, event) => _noteNotification(event),
    );
    ref.listenManual(
      desktopNotificationsProvider.select(
        (state) => (
          call: state.active.values.any((note) => note.incomingCall),
          alarm: state.active.values.any((note) => note.ringingAlarm),
        ),
      ),
      (_, _) => _show(),
    );
    final signals = ref.read(rgbLightSignalsProvider);
    _subscriptions
      ..add(
        signals.ringing().listen((ringing) {
          _ringing = ringing;
          _show();
        }),
      )
      ..add(
        signals.charging().listen((charging) {
          _charging = charging;
          _show();
        }),
      );
    unawaited(_start());
  }

  Future<void> _start() async {
    _settings = await _lights.load();
    _loaded = true;
    _show(force: true);
    final file = File(_lights.settingsPath);
    final name = file.uri.pathSegments.last;
    try {
      // Phone Settings writes a new file and renames it into place.
      final changes = file.parent.watch().listen((change) {
        if (change.path.split('/').last.startsWith(name)) {
          _reloadSoon?.cancel();
          _reloadSoon = Timer(_settle, () => unawaited(_reload()));
        }
      }, onError: (Object error) => debugPrint('RGB light settings: $error'));
      _subscriptions.add(changes);
    } on Object catch (error) {
      debugPrint('RGB light settings not followed: $error');
    }
  }

  Future<void> _reload() async {
    final shown = _shown;
    final before = shown == null ? null : _settings.events[shown];
    _settings = await _lights.load();
    // An effect showing plays again only when it changed: each new pattern
    // starts over, which blinks.
    _show(force: shown != null && _settings.events[shown] != before);
  }

  void _noteNotification(DesktopNotificationEvent? event) {
    final note = event?.notification;
    if (event == null ||
        note == null ||
        event.kind == DesktopNotificationEventKind.closed ||
        !note.alert ||
        note.urgency == DesktopNotificationUrgency.low ||
        note.call ||
        note.ringingAlarm) {
      return;
    }
    final quiet = ref.read(desktopNotificationsProvider).doNotDisturb;
    if (quiet && note.urgency != DesktopNotificationUrgency.critical) return;
    final seconds = _settings.events[RgbLightEvent.notification]?.seconds;
    _notification?.cancel();
    _notification = Timer(Duration(seconds: seconds ?? 30), () {
      _notification = null;
      _show();
    });
    _show();
  }

  /// The most important event going on whose effect is on.
  RgbLightEvent? _event() {
    final notes = ref.read(desktopNotificationsProvider).active.values;
    final going = {
      RgbLightEvent.call: _ringing || notes.any((note) => note.incomingCall),
      RgbLightEvent.alarm: notes.any((note) => note.ringingAlarm),
      RgbLightEvent.notification: _notification != null,
      RgbLightEvent.charging: _charging,
    };
    for (final event in RgbLightEvent.values) {
      if (going[event] == true && (_settings.events[event]?.on ?? false)) {
        return event;
      }
    }
    return null;
  }

  void _show({bool force = false}) {
    if (!_loaded || !mounted) return;
    final event = _event();
    if (!force && _shownAny && event == _shown) return;
    _shown = event;
    _shownAny = true;
    final settings = _settings;
    _writes = _writes.then((_) async {
      try {
        if (event == null) {
          await _lights.applyAll(settings);
        } else {
          await _lights.applyEffect(settings.events[event]!, settings);
        }
      } on Object catch (error) {
        // No lights, or no permission to write them: leave them as they are.
        debugPrint('RGB lights not shown: $error');
      }
    });
  }

  @override
  void dispose() {
    _notification?.cancel();
    _reloadSoon?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
