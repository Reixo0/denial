import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../phone_scheme.dart';

/// Android 17 quick-settings geometry, in dp (the shade lays itself out in
/// Android's units; see `PixelShadeViewport`).
abstract final class PixelQs {
  static const double margin = 16;
  static const double gap = 8;
  static const double tileHeight = 64;
  static const int columns = 4;

  /// A wide tile's icon well.
  static const double well = 48;
}

/// One quick-settings tile: a pill with an icon, or with [wide] a two-column
/// tile with icon, title and state. An active tile fills with the accent and
/// squares its corners, as Android's do.
class QuickTile extends StatefulWidget {
  const QuickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.active,
    required this.onTap,
    this.subtitle,
    this.wide = false,
    this.enabled = true,
    this.busy = false,
    this.onDetails,
    this.onSettings,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool active;
  final VoidCallback onTap;
  final bool wide;
  final bool enabled;
  final bool busy;

  /// Opens the tile's details: a tap on a wide tile's text (a long press
  /// when the tile has no [onSettings]).
  final VoidCallback? onDetails;

  /// Opens the tile's page in Settings: a long press.
  final VoidCallback? onSettings;

  @override
  State<QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<QuickTile> {
  static const Duration _morph = Duration(milliseconds: 220);
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  void _toggle() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  Color _pressedOver(Color color, ColorScheme scheme) => _pressed
      ? Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.10), color)
      : color;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final dim = widget.enabled ? 1.0 : 0.38;
    final details = widget.onDetails;
    final tile = widget.wide
        ? _wide(scheme, dim, details)
        : _small(scheme, dim);
    return Semantics(
      button: true,
      enabled: widget.enabled,
      toggled: widget.active,
      label: widget.title,
      value: widget.subtitle,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          onTap: widget.wide && details != null ? details : _toggle,
          onLongPress: widget.onSettings == null && details == null
              ? null
              : () {
                  HapticFeedback.heavyImpact();
                  (widget.onSettings ?? details)!();
                },
          child: tile,
        ),
      ),
    );
  }

  Widget _small(ColorScheme scheme, double dim) {
    final active = widget.active;
    return AnimatedContainer(
      duration: _morph,
      curve: Curves.easeOutCubic,
      height: PixelQs.tileHeight,
      decoration: BoxDecoration(
        color: _pressedOver(
          active ? scheme.primary : scheme.surfaceContainerHigh,
          scheme,
        ),
        borderRadius: BorderRadius.circular(
          active ? 20 : PixelQs.tileHeight / 2,
        ),
      ),
      alignment: Alignment.center,
      child: Opacity(
        opacity: widget.busy ? 0.6 : dim,
        child: Icon(
          widget.icon,
          size: 24,
          color: active ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );
  }

  Widget _wide(ColorScheme scheme, double dim, VoidCallback? details) {
    final active = widget.active;
    final subtitle = widget.subtitle;
    // With details, the well toggles and the text opens them (Android's
    // Internet and Bluetooth tiles).
    final well = AnimatedContainer(
      duration: _morph,
      curve: Curves.easeOutCubic,
      width: PixelQs.well,
      height: PixelQs.well,
      decoration: BoxDecoration(
        color: active ? scheme.primary : const Color(0x00000000),
        borderRadius: BorderRadius.circular(active ? 16 : PixelQs.well / 2),
      ),
      alignment: Alignment.center,
      child: Opacity(
        opacity: widget.busy ? 0.6 : 1,
        child: Icon(
          widget.icon,
          size: 24,
          color: active ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );
    return AnimatedContainer(
      duration: _morph,
      curve: Curves.easeOutCubic,
      height: PixelQs.tileHeight,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _pressedOver(scheme.surfaceContainerHigh, scheme),
        borderRadius: BorderRadius.circular(
          active ? 24 : PixelQs.tileHeight / 2,
        ),
      ),
      child: Opacity(
        opacity: dim,
        child: Row(
          children: <Widget>[
            if (details != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                child: well,
              )
            else
              well,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 15,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiles in Android's four-column grid: a wide tile takes two columns, the
/// rest one, in order, row by row.
class PixelTileGrid extends StatelessWidget {
  const PixelTileGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  static bool _wide(Widget tile) => tile is QuickTile ? tile.wide : true;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final column =
          (constraints.maxWidth - PixelQs.gap * (PixelQs.columns - 1)) /
          PixelQs.columns;
      return Wrap(
        spacing: PixelQs.gap,
        runSpacing: PixelQs.gap,
        children: <Widget>[
          for (final tile in tiles)
            SizedBox(
              width: _wide(tile) ? column * 2 + PixelQs.gap : column,
              height: PixelQs.tileHeight,
              child: tile,
            ),
        ],
      );
    },
  );
}

/// Android 17's brightness slider: a thick track split by a thin handle,
/// the filled part in the accent.
class PixelBrightnessSlider extends StatefulWidget {
  const PixelBrightnessSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<PixelBrightnessSlider> createState() => _PixelBrightnessSliderState();
}

class _PixelBrightnessSliderState extends State<PixelBrightnessSlider> {
  static const double _height = 48;
  static const double _track = 40;
  static const double _handle = 4;
  static const double _handleGap = 6;

  double? _dragValue;

  double _valueAt(double x, double width) =>
      ((x - _handle / 2) / math.max(1, width - _handle)).clamp(0.0, 1.0);

  void _update(double x, double width) {
    final value = _valueAt(x, width);
    setState(() => _dragValue = value);
    widget.onChanged(value);
  }

  void _end() {
    final value = _dragValue;
    setState(() => _dragValue = null);
    if (value != null) widget.onChangeEnd?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final value = (_dragValue ?? widget.value).clamp(0.0, 1.0);
    return Semantics(
      slider: true,
      label: context.l10n.settingsBrightness,
      value: '${(value * 100).round()}%',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final handleX = _handle / 2 + value * (width - _handle);
          final filledEnd = math.max(0.0, handleX - _handle / 2 - _handleGap);
          final emptyStart = math.min(
            width,
            handleX + _handle / 2 + _handleGap,
          );
          const top = (_height - _track) / 2;
          final iconOnFill = width - emptyStart < 40;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => _update(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, width),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            onTapDown: (d) => _update(d.localPosition.dx, width),
            onTapUp: (_) => _end(),
            child: SizedBox(
              height: _height,
              child: Stack(
                children: <Widget>[
                  if (filledEnd > 0)
                    Positioned(
                      left: 0,
                      top: top,
                      width: filledEnd,
                      height: _track,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(_track / 2),
                            right: Radius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  if (emptyStart < width)
                    Positioned(
                      left: emptyStart,
                      right: 0,
                      top: top,
                      height: _track,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(4),
                            right: Radius.circular(_track / 2),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: handleX - _handle / 2,
                    top: 0,
                    width: _handle,
                    height: _height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(_handle / 2),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: Icon(
                      Icons.brightness_medium_rounded,
                      size: 22,
                      color: iconOnFill
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The open shade's footer: settings and the power menu, Android's round
/// buttons at the end of the row.
class ShadeActions extends StatelessWidget {
  const ShadeActions({
    super.key,
    required this.onOpenPower,
    this.onOpenSettings,
  });

  final VoidCallback onOpenPower;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RoundButton(
          label: l10n.settingsApplicationTitle,
          icon: Icons.settings_rounded,
          color: scheme.surfaceContainerHigh,
          iconColor: scheme.onSurface,
          onPressed: onOpenSettings,
        ),
        const SizedBox(width: 8),
        _RoundButton(
          label: l10n.desktopOpenPowerControls,
          icon: Icons.power_settings_new_rounded,
          color: scheme.primary,
          iconColor: scheme.onPrimary,
          onPressed: onOpenPower,
        ),
      ],
    );
  }
}

class _RoundButton extends StatefulWidget {
  const _RoundButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.iconColor,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color iconColor;
  final VoidCallback? onPressed;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  static const double _size = 40;
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final color = _pressed
        ? Color.alphaBlend(
            widget.iconColor.withValues(alpha: 0.12),
            widget.color,
          )
        : widget.color;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _press(true) : null,
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: widget.onPressed,
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Opacity(
            opacity: enabled ? 1 : 0.38,
            child: Icon(widget.icon, size: 22, color: widget.iconColor),
          ),
        ),
      ),
    );
  }
}

IconData profileIcon(String profile) => switch (profile) {
  PowerProfile.powerSave => Icons.battery_saver_rounded,
  PowerProfile.performance => Icons.speed_rounded,
  _ => Icons.balance_rounded,
};

String profileLabel(String profile, AppLocalizations l10n) => switch (profile) {
  PowerProfile.powerSave => l10n.quickSettingsBatterySaver,
  PowerProfile.performance => l10n.quickSettingsHighPerformance,
  _ => l10n.quickSettingsBalanced,
};
