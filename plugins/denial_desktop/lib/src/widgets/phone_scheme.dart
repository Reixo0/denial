import 'package:flutter/material.dart' show ColorScheme;
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/shell_theme.dart';

/// Material 3 roles from the shell accent (the wallpaper's colour when the
/// accent follows it), as Android's system UI derives its own.
ColorScheme phoneSchemeOf(BuildContext context) {
  final theme = ShellTheme.of(context);
  final brightness = context.shellColors.brightness;
  final key = (theme.accentSeed, brightness);
  final cached = _schemeCache;
  if (cached != null && cached.$1 == key) return cached.$2;
  final scheme = ColorScheme.fromSeed(
    seedColor: theme.accentSeed,
    brightness: brightness,
  );
  _schemeCache = (key, scheme);
  return scheme;
}

((Color, Brightness), ColorScheme)? _schemeCache;

/// Text in the phone's system UI (shade, its dialogs, the power menu) is
/// set in Android's sizes, but Roboto Flex runs larger than Android's
/// Google Sans: this brings it to the same apparent size.
const double phoneTextScale = 0.85;

/// [media]'s text scale (the user's choice) with [phoneTextScale] on top.
TextScaler phoneTextScaler(MediaQueryData media) =>
    TextScaler.linear(media.textScaler.scale(1) * phoneTextScale);

/// Icons in the phone's system UI, in dp.
const double phoneIconSize = 20;
