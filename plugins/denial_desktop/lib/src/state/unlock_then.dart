import 'package:flutter/foundation.dart' show VoidCallback, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/shade/shade_launch.dart' show LaunchSources;
import 'reference_shell_controller.dart';

/// What the shade over the lock screen asks to do that the lock protects
/// (Android's ActivityStarter dismissKeyguardThenExecute): the lock screen
/// asks for the credential over the open shade, and the action runs once
/// the phone is unlocked and the lock screen has gone, from the shade, so
/// it opens as it would on an unlocked phone. The lock screen listens and
/// brings up the credential.
final unlockThenProvider = NotifierProvider<UnlockThen, UnlockThenState>(
  UnlockThen.new,
);

@immutable
class UnlockThenState {
  const UnlockThenState({
    this.request = 0,
    this.cancel = 0,
    this.overShade = false,
  });

  /// Changes each time the credential is asked for.
  final int request;

  /// Changes each time Back asks the credential to close.
  final int cancel;

  /// The credential is up over the open shade: the shade blurs away under
  /// it, stays open through the unlock (StatusBarStateController's
  /// setLeaveOpenOnKeyguardHide) and comes back when it is dismissed.
  final bool overShade;

  UnlockThenState copyWith({int? request, int? cancel, bool? overShade}) =>
      UnlockThenState(
        request: request ?? this.request,
        cancel: cancel ?? this.cancel,
        overShade: overShade ?? this.overShade,
      );
}

class UnlockThen extends Notifier<UnlockThenState> {
  VoidCallback? _pending;

  /// What was pressed to ask: the launch the action starts grows out of it.
  Object? _source;

  /// The shade stays open when the phone unlocks: the credential came up
  /// over it. Read by the shell as the session unlocks, before this
  /// notifier hears of it.
  bool get leavesShadeOpen => _leaveShadeOpen;
  bool _leaveShadeOpen = false;

  @override
  UnlockThenState build() {
    ref.listen<bool>(referenceShellProvider.select((state) => state.locked), (
      previous,
      locked,
    ) {
      if (locked) {
        // A new lock forgets what the last one asked.
        _pending = null;
        _source = null;
        _leaveShadeOpen = false;
        if (state.overShade) state = state.copyWith(overShade: false);
        return;
      }
      // Unlocked: the shade comes back while the lock screen leaves.
      if (state.overShade) state = state.copyWith(overShade: false);
    });
    // The action runs once the lock screen is gone, when launches can
    // animate from where they were asked.
    ref.listen<bool>(
      referenceShellProvider.select(
        (state) => state.locked || state.lockLayerVisible,
      ),
      (previous, covered) {
        if (previous != true || covered) return;
        final action = _pending;
        final source = _source;
        _pending = null;
        _source = null;
        _leaveShadeOpen = false;
        if (action != null) {
          Future<void>.microtask(() {
            LaunchSources.resume(source);
            action();
            LaunchSources.resume(null);
          });
        }
      },
    );
    return const UnlockThenState();
  }

  /// Whether the lock screen covers the phone.
  bool get locked {
    final shell = ref.read(referenceShellProvider);
    return shell.locked || shell.lockLayerVisible;
  }

  /// Runs [action] now on an unlocked phone; on a locked one, after the
  /// unlock. Without an action it only asks for the unlock.
  void run([VoidCallback? action]) {
    if (!locked) {
      action?.call();
      return;
    }
    _pending = action;
    _source = LaunchSources.keep();
    final shell = ref.read(referenceShellProvider);
    _leaveShadeOpen = shell.locked && shell.quickSettingsEngaged;
    state = state.copyWith(
      request: state.request + 1,
      overShade: _leaveShadeOpen,
    );
  }

  /// Back on the credential: the lock screen closes it, and [drop] follows.
  void cancel() => state = state.copyWith(cancel: state.cancel + 1);

  /// The credential was dismissed: nothing runs, and the shade comes back.
  void drop() {
    _pending = null;
    _source = null;
    _leaveShadeOpen = false;
    if (state.overShade) state = state.copyWith(overShade: false);
  }
}
