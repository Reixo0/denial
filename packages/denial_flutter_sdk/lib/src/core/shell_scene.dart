import 'package:flutter/widgets.dart';

/// The feature-owned part of a Denial shell profile.
///
/// [content] is the application scene, [chrome] is profile UI that should move
/// with the scene during an unlock transition, and [overlays] are transient
/// feature layers such as notifications and heads-up displays. This value object
/// installs no UI or lifecycle handlers. Its consuming root plugin composes the
/// required SDK input, surface, authentication and presentation primitives.
@immutable
class DenialShellScene {
  const DenialShellScene({
    required this.content,
    this.chrome = const SizedBox.shrink(),
    this.overlays = const <Widget>[],
    this.overLock,
  });

  final Widget content;
  final Widget chrome;
  final List<Widget> overlays;

  /// Chrome over the lock screen as well as the apps: on the phone, the
  /// notification shade, which opens over the lock screen as on Android.
  final Widget? overLock;
}
