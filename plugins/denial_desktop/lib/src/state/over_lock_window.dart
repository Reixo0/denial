import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import 'reference_shell_controller.dart';
import 'reference_shell_profile.dart';

/// The calls app's window, shown over the phone's lock screen.
///
/// While the phone is locked and a call notification of the calls app the
/// settings name stands, that app's window shows above the lock screen and
/// takes its touches; the keyboard stays with the lock screen. A ringing
/// alarm's app shows there the same way, so the alarm can be stopped. Denial
/// applies the same rule natively: it keeps the window running and routes
/// touch to it only then.
final overLockWindowProvider = Provider<DenialWindow?>((ref) {
  if (ref.watch(referenceShellProfileProvider) !=
      ReferenceShellProfile.mobile) {
    return null;
  }
  if (!ref.watch(referenceShellProvider.select((state) => state.locked))) {
    return null;
  }
  final callsApp = ref.watch(
    shellSettingsProvider.select((settings) => settings.lockScreen.callsApp),
  );
  final calling = ref.watch(
    desktopNotificationsProvider.select(
      (notifications) => notifications.active.values.any(
        (notification) =>
            notification.call && notification.desktopEntry == callsApp,
      ),
    ),
  );
  final Set<String> appIds;
  if (calling) {
    appIds = {callsApp};
  } else {
    final alarms = ref.watch(
      desktopNotificationsProvider.select(
        (notifications) => {
          for (final notification in notifications.active.values)
            if (notification.ringingAlarm) notification.desktopEntry,
        },
      ),
    );
    if (alarms.isEmpty) return null;
    appIds = ref.watch(
      homeGridControllerProvider.select((grid) {
        final ids = {...alarms};
        for (final item in grid.value?.apps ?? const <HomeGridItem>[]) {
          final app = item.app;
          final wmClass = app?.startupWmClass;
          if (app == null || wmClass == null || wmClass.isEmpty) continue;
          // An Android app's window names its package, not its desktop entry.
          if (alarms.contains(app.id.replaceFirst(RegExp(r'\.desktop$'), ''))) {
            ids.add(wmClass);
          }
        }
        return ids;
      }),
    );
  }
  return ref.watch(
    referenceShellProvider.select((state) {
      // The newest of the app's windows: an alarm's screen opens in a window
      // of its own beside the app's main one.
      DenialWindow? newest;
      for (final window in state.windows) {
        if (appIds.contains(window.appId) &&
            window.isUserApp &&
            !window.isLocalFlutter &&
            (newest == null || window.objectId > newest.objectId)) {
          newest = window;
        }
      }
      return newest;
    }),
  );
});
