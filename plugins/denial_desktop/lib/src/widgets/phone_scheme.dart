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

/// Text in the phone's system UI is set in Android's sizes, but Roboto Flex
/// runs larger than Android's Google Sans: this brings it to the same
/// apparent size (the owner's choice, checked against EvolutionX).
const double phoneTextScale = 0.945;

/// Icons in the phone's system UI, in dp. Android draws QS tile icons
/// larger (28 dp, 32 dp in small tiles); the owner prefers these.
const double phoneIconSize = 22;

/// Android 17's custom "surface effect" colours, from the same palettes as
/// [ColorScheme] (looked up on EvolutionX: `cmd overlay lookup android
/// android:color/system_surface_effect_N_dark`). They are see-through: the
/// shade's blur shows behind them.
extension PhoneSurfaceEffects on ColorScheme {
  /// Tiles, notification cards, the slider's empty track: #8a111417, the
  /// surfaceContainerLow tone at 0x8a.
  Color get surfaceEffect1 => surfaceContainerLow.withValues(alpha: 0x8a / 255);

  /// A wide tile's inactive icon well: #26cbe6ff, primary tone 90
  /// (onPrimaryContainer in dark) at 0x26.
  Color get surfaceEffect2 => onPrimaryContainer.withValues(alpha: 0x26 / 255);
}

/// The scrim Android's classic shade lays over the blurred scene
/// (shade_panel_scrim: #404040 at 0.4).
const Color phoneShadeScrim = Color(0x66404040);

/// The shade panel over that scrim (SystemUI ShadeColors.shadePanelStandard):
/// shade_panel_bg (neutral tone 4, surfaceContainerLowest in dark, at 0.32)
/// under shade_panel_fg (accent tone 20, onPrimary in dark, at 0.32).
Color phoneShadePanel(ColorScheme scheme) => Color.alphaBlend(
  scheme.onPrimary.withValues(alpha: 0.32),
  scheme.surfaceContainerLowest.withValues(alpha: 0.32),
);
