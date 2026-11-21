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
