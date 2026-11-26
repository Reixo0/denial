import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../phone_scheme.dart';
import 'qs_tile_bounce.dart';
import 'shade_expansion_motion.dart' show androidDuration;

/// Android 17 quick-settings geometry, in dp (the shade lays itself out in
/// Android's units; see `PixelShadeViewport`).
abstract final class PixelQs {
  // AOSP: qs_horizontal_margin, qs_tile_margin_horizontal/vertical,
  // common_tile_default_tile_height and _toggle_target_size.
  static const double margin = 16;
  static const double gap = 8;
  static const double tileHeight = 72;
  static const int columns = 4;

  /// A wide tile's icon well.
  static const double well = 56;
}

/// A placed tile with its size from the saved layout, for the grid.
class QsTileSize extends StatelessWidget {
  const QsTileSize({required this.wide, required this.child, super.key});

  final bool wide;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
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

  /// Opens the tile's details from the tile's rectangle on screen: a tap on
  /// a wide tile's text (a long press when the tile has no [onSettings]).
  final ValueChanged<Rect>? onDetails;

  /// Opens the tile's page in Settings: a long press.
  final VoidCallback? onSettings;

  @override
  State<QuickTile> createState() => _QuickTileState();
}

class _QuickTileState extends State<QuickTile> {
  static final Duration _morph = androidDuration(220);
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  void _toggle() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  /// The tile on screen, for a dialog that grows out of it.
  Rect _onScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Rect.zero;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  Color _pressedOver(Color color, ColorScheme scheme) => _pressed
      ? Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.10), color)
      : color;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final dim = widget.enabled ? 1.0 : 0.38;
    final bounce = QsBounceScope.maybeOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bounceContainer =
        widget.enabled && (!widget.wide || widget.onDetails == null);
    final onDetails = widget.onDetails;
    final VoidCallback? details = onDetails == null
        ? null
        : () => onDetails(_onScreen());
    final tile = widget.wide
        ? _wide(scheme, dim, details, bounce)
        : _small(scheme, dim, bounce);
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
          onTapDown: (_) {
            _press(true);
            if (bounceContainer) {
              bounce?.onPressDown(reduceMotion: reduceMotion);
            }
          },
          onTapUp: (_) {
            _press(false);
            if (bounceContainer) bounce?.onPressUp();
          },
          onTapCancel: () {
            _press(false);
            if (bounceContainer) bounce?.onPressUp();
          },
          onTap: widget.wide && details != null
              ? () {
                  bounce?.animateContentBounce(reduceMotion: reduceMotion);
                  details();
                }
              : _toggle,
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

  Widget _small(ColorScheme scheme, double dim, QsBounceableController? bounce) {
    final active = widget.active;
    final icon = Icon(
      widget.icon,
      size: phoneIconSize,
      color: active ? scheme.onPrimary : scheme.onSurface,
    );
    return AnimatedContainer(
      duration: _morph,
      curve: Curves.easeOutCubic,
      height: PixelQs.tileHeight,
      decoration: BoxDecoration(
        // AOSP Tile.kt: active primary, inactive surfaceEffect1; corners
        // 24 dp active, round inactive (common_tile_default_*).
        color: _pressedOver(
          active ? scheme.primary : scheme.surfaceEffect1,
          scheme,
        ),
        borderRadius: BorderRadius.circular(
          active ? 24 : PixelQs.tileHeight / 2,
        ),
      ),
      alignment: Alignment.center,
      child: Opacity(
        opacity: widget.busy ? 0.6 : dim,
        child: bounce == null
            ? icon
            : ScaleTransition(scale: bounce.iconScale, child: icon),
      ),
    );
  }

  Widget _wide(
    ColorScheme scheme,
    double dim,
    VoidCallback? details,
    QsBounceableController? bounce,
  ) {
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
        // Dual-target tiles show surfaceEffect2 in an inactive well.
        color: active
            ? scheme.primary
            : details != null
            ? scheme.surfaceEffect2
            : const Color(0x00000000),
        borderRadius: BorderRadius.circular(active ? 16 : PixelQs.well / 2),
      ),
      alignment: Alignment.center,
      child: Opacity(
        opacity: widget.busy ? 0.6 : 1,
        child: Icon(
          widget.icon,
          size: phoneIconSize,
          color: active ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );
    // AOSP squishes the icon well alone (LargeTileContent's verticalSquish):
    // a shorter rounded shape, centred. The tile's own squish is inside its
    // fixed height and draws nothing different.
    final squish = QsTileSquish.of(context);
    final Widget squishedWell = squish == null
        ? well
        : _SquishedWell(
            radius: active ? 16 : PixelQs.well / 2,
            squish: squish,
            child: well,
          );
    final labels = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // titleSmallEmphasized and labelMedium, both onSurface
          // (AOSP CommonTile.kt).
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 14,
            height: 1.43,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 12,
              height: 1.33,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );
    return AnimatedContainer(
      duration: _morph,
      curve: Curves.easeOutCubic,
      height: PixelQs.tileHeight,
      // AOSP largeTilePadding: start 8, end 12 (8 on dual-target tiles).
      padding: EdgeInsetsDirectional.fromSTEB(
        8,
        0,
        details != null ? 8 : 12,
        0,
      ),
      alignment: AlignmentDirectional.centerStart,
      decoration: BoxDecoration(
        color: _pressedOver(scheme.surfaceEffect1, scheme),
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
                child: squishedWell,
              )
            else
              squishedWell,
            // AOSP TileArrangementPadding.
            const SizedBox(width: 6),
            Expanded(
              child: bounce == null
                  ? labels
                  : ScaleTransition(
                      scale: bounce.textScale,
                      alignment: Directionality.of(context) == TextDirection.rtl
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: labels,
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
/// How the first page's tiles move between the quick tiles and the full
/// quick settings (AOSP Compose QS): the rows shared with the quick tiles
/// stay as they are, but for the wells of their wide tiles, which squish with
/// the shade's first pull ([squish], up to 1: `verticalSquish`); the other
/// rows fade with the quick settings' content ([contentAlpha]). Paint only:
/// neither lays the grid out again.
@immutable
class QsTileMotion {
  const QsTileMotion({
    required this.sharedRows,
    required this.squish,
    required this.contentAlpha,
  });

  final int sharedRows;
  final Animation<double> squish;
  final Animation<double> contentAlpha;
}

class PixelTileGrid extends StatelessWidget {
  const PixelTileGrid({super.key, required this.tiles, this.motion});

  final List<Widget> tiles;
  final QsTileMotion? motion;

  static bool _wide(Widget tile) => switch (tile) {
    QsTileSize(:final wide) => wide,
    QuickTile(:final wide) => wide,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    final motion = this.motion;
    final rows = <({List<({Widget child, int span})> tiles, int used})>[];
    var current = <({Widget child, int span})>[];
    var used = 0;
    for (final tile in tiles) {
      final span = _wide(tile) ? 2 : 1;
      if (used + span > PixelQs.columns) {
        rows.add((tiles: current, used: used));
        current = <({Widget child, int span})>[];
        used = 0;
      }
      current.add((child: tile, span: span));
      used += span;
    }
    if (current.isNotEmpty) {
      rows.add((tiles: current, used: used));
    }

    Widget buildRow(int index) {
      final row = rows[index];
      final bounced = QsBounceRow(
        tiles: row.tiles,
        bounceEnd: row.used < PixelQs.columns,
        columns: PixelQs.columns,
        gap: PixelQs.gap,
        tileHeight: PixelQs.tileHeight,
      );
      if (motion != null && index < motion.sharedRows) {
        return QsTileSquish(squish: motion.squish, child: bounced);
      }
      return bounced;
    }

    final shared = <Widget>[];
    final rest = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final rowWidget = buildRow(i);
      if (motion != null && i >= motion.sharedRows) {
        if (rest.isNotEmpty) rest.add(const SizedBox(height: PixelQs.gap));
        rest.add(rowWidget);
      } else {
        if (shared.isNotEmpty) shared.add(const SizedBox(height: PixelQs.gap));
        shared.add(rowWidget);
      }
    }

    final sharedColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: shared,
    );
    if (motion == null || rest.isEmpty) return sharedColumn;
    // The rows only the full quick settings show fade in as one layer.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        sharedColumn,
        const SizedBox(height: PixelQs.gap),
        FadeTransition(
          opacity: motion.contentAlpha,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: rest,
          ),
        ),
      ],
    );
  }
}

/// Android 17's brightness slider: a thick track split by a thin handle,
/// the filled part in the accent, with AOSP mirror container & icon fade.
class PixelBrightnessSlider extends StatefulWidget {
  const PixelBrightnessSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.onDraggingChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final ValueChanged<bool>? onDraggingChanged;

  @override
  State<PixelBrightnessSlider> createState() => _PixelBrightnessSliderState();
}

class _PixelBrightnessSliderState extends State<PixelBrightnessSlider>
    with TickerProviderStateMixin {
  // AOSP BrightnessSliderDimensions.Default: 40 dp track with 12 dp outer
  // and 2 dp inner corners, a 4×52 dp thumb 6 dp clear of the track.
  static const double _height = 52;
  static const double _track = 40;
  static const double _handle = 4;
  static const double _handleGap = 6;
  static const double _outer = 12;
  static const double _inner = 2;

  late final AnimationController _inactiveIcon = AnimationController(
    vsync: this,
    value: 1,
  );
  late final AnimationController _activeIcon = AnimationController(
    vsync: this,
    value: 0,
  );
  Timer? _appearDelay;
  double? _dragValue;
  bool _dragging = false;
  bool? _iconOnFill;
  bool _targetIconOnFill = false;
  bool _syncScheduled = false;

  @override
  void dispose() {
    _appearDelay?.cancel();
    if (_dragging) widget.onDraggingChanged?.call(false);
    _inactiveIcon.dispose();
    _activeIcon.dispose();
    super.dispose();
  }

  static bool _isIconOnFill(double value, double width) {
    final handleX = _handle / 2 + value * (width - _handle);
    final filledEnd = math.max(0.0, handleX - _handle / 2 - _handleGap);
    final emptyStart = math.min(width, handleX + _handle / 2 + _handleGap);
    return width - emptyStart <= 40 && filledEnd > 40;
  }

  static IconData _brightnessIcon(double value) => value <= 0.20
      ? Icons.brightness_low_rounded
      : value >= 0.80
      ? Icons.brightness_high_rounded
      : Icons.brightness_medium_rounded;

  void _setDragging(bool value) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
    widget.onDraggingChanged?.call(value);
  }

  void _applyIconSide(
    bool iconOnFill, {
    required bool reduceMotion,
    bool snap = false,
  }) {
    _targetIconOnFill = iconOnFill;
    if (_iconOnFill == iconOnFill && !snap) return;
    final first = _iconOnFill == null;
    _iconOnFill = iconOnFill;
    _appearDelay?.cancel();
    _appearDelay = null;
    if (snap || first || reduceMotion) {
      _inactiveIcon.value = iconOnFill ? 0.0 : 1.0;
      _activeIcon.value = iconOnFill ? 1.0 : 0.0;
      if (first && mounted) setState(() {});
      return;
    }
    final outgoing = iconOnFill ? _inactiveIcon : _activeIcon;
    final incoming = iconOnFill ? _activeIcon : _inactiveIcon;
    outgoing.animateTo(0, duration: androidDuration(50));
    _appearDelay = Timer(androidDuration(33), () {
      _appearDelay = null;
      if (!mounted) return;
      incoming.animateTo(1, duration: androidDuration(100));
    });
  }

  double _valueAt(double x, double width) =>
      ((x - _handle / 2) / math.max(1, width - _handle)).clamp(0.0, 1.0);

  void _update(double x, double width, {required bool reduceMotion}) {
    final value = _valueAt(x, width);
    setState(() => _dragValue = value);
    _setDragging(true);
    _applyIconSide(_isIconOnFill(value, width), reduceMotion: reduceMotion);
    widget.onChanged(value);
  }

  void _end() {
    final value = _dragValue;
    setState(() => _dragValue = null);
    _setDragging(false);
    if (value != null) widget.onChangeEnd?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
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
          final iconOnFill = _isIconOnFill(value, width);
          _targetIconOnFill = iconOnFill;
          if (_iconOnFill != iconOnFill && !_syncScheduled) {
            final first = _iconOnFill == null;
            _syncScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _syncScheduled = false;
              if (!mounted) return;
              _applyIconSide(
                _targetIconOnFill,
                reduceMotion: MediaQuery.disableAnimationsOf(context),
                snap: first,
              );
            });
          }
          final icon = _brightnessIcon(value);
          final Animation<double> activeOpacity = _iconOnFill == null
              ? AlwaysStoppedAnimation<double>(iconOnFill ? 1.0 : 0.0)
              : _activeIcon;
          final Animation<double> inactiveOpacity = _iconOnFill == null
              ? AlwaysStoppedAnimation<double>(iconOnFill ? 0.0 : 1.0)
              : _inactiveIcon;
          Widget trackIcon({
            required Animation<double> opacity,
            required Color color,
            required BorderRadius radius,
          }) => ClipRRect(
            borderRadius: radius,
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: 32,
              maxWidth: 32,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FadeTransition(
                  opacity: opacity,
                  child: Icon(icon, size: 24, color: color),
                ),
              ),
            ),
          );
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => _update(
              d.localPosition.dx,
              width,
              reduceMotion: reduceMotion,
            ),
            onHorizontalDragUpdate: (d) => _update(
              d.localPosition.dx,
              width,
              reduceMotion: reduceMotion,
            ),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            onTapDown: (d) => _update(
              d.localPosition.dx,
              width,
              reduceMotion: reduceMotion,
            ),
            onTapUp: (_) => _end(),
            onTapCancel: _end,
            child: SizedBox(
              height: _height,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // AOSP BrightnessSlider.kt: mirror backdrop pill while dragging.
                  Positioned(
                    left: -10,
                    right: -10,
                    top: -6,
                    bottom: -6,
                    child: AnimatedContainer(
                      duration: reduceMotion
                          ? Duration.zero
                          : androidDuration(200),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        color: _dragging
                            ? scheme.surfaceContainer
                            : const Color(0x00000000),
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
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
                            left: Radius.circular(_outer),
                            right: Radius.circular(_inner),
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
                          color: scheme.surfaceEffect1,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(_inner),
                            right: Radius.circular(_outer),
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
                  if (emptyStart < width)
                    Positioned(
                      left: emptyStart,
                      right: 0,
                      top: top,
                      height: _track,
                      child: trackIcon(
                        opacity: inactiveOpacity,
                        color: scheme.onSurface,
                        radius: const BorderRadius.horizontal(
                          left: Radius.circular(_inner),
                          right: Radius.circular(_outer),
                        ),
                      ),
                    ),
                  if (filledEnd > 0)
                    Positioned(
                      left: 0,
                      top: top,
                      width: filledEnd,
                      height: _track,
                      child: trackIcon(
                        opacity: activeOpacity,
                        color: scheme.onPrimary,
                        radius: const BorderRadius.horizontal(
                          left: Radius.circular(_outer),
                          right: Radius.circular(_inner),
                        ),
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
    this.activeApps = 0,
    this.onActiveApps,
  });

  final VoidCallback onOpenPower;
  final VoidCallback? onOpenSettings;

  /// How many apps Android calls active, and what a tap on that does, given
  /// where the chip is on the screen.
  final int activeApps;
  final ValueChanged<Rect>? onActiveApps;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    return Row(
      children: <Widget>[
        Expanded(
          child: activeApps > 0
              ? _ActiveAppsChip(count: activeApps, onTap: onActiveApps)
              : const SizedBox.shrink(),
        ),
        const SizedBox(width: 8),
        _RoundButton(
          label: l10n.settingsApplicationTitle,
          icon: Icons.settings_rounded,
          color: scheme.surfaceEffect1,
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

/// AOSP's foreground services button (FooterActions' TextButton): 40 dp tall,
/// 20 dp inside, the icon and the chevron 20 dp.
class _ActiveAppsChip extends StatefulWidget {
  const _ActiveAppsChip({required this.count, this.onTap});

  final int count;
  final ValueChanged<Rect>? onTap;

  @override
  State<_ActiveAppsChip> createState() => _ActiveAppsChipState();
}

class _ActiveAppsChipState extends State<_ActiveAppsChip> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  void _tap() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    widget.onTap?.call(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero),
        box.localToGlobal(box.size.bottomRight(Offset.zero)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final label = context.l10n.quickSettingsActiveApps(widget.count);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: _tap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: _tap,
        child: Container(
          height: _RoundButtonState._size,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: _pressed
                ? Color.alphaBlend(
                    scheme.onSurface.withValues(alpha: 0.12),
                    scheme.surfaceEffect1,
                  )
                : scheme.surfaceEffect1,
            borderRadius: BorderRadius.circular(_RoundButtonState._size / 2),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_rounded, size: 20, color: scheme.onSurface),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurface,
              ),
            ],
          ),
        ),
      ),
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
            child: Icon(
              widget.icon,
              size: phoneIconSize,
              color: widget.iconColor,
            ),
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

/// Android's paginated tile grid (AOSP PaginatedGridLayout): four rows a
/// page (`quick_settings_paginated_grid_num_rows`), pages side by side
/// 16 dp apart, swiped sideways.
class PixelPagedTileGrid extends StatelessWidget {
  const PixelPagedTileGrid({
    super.key,
    required this.tiles,
    required this.controller,
    required this.scrollable,
    this.motion,
  });

  static const int rowsPerPage = 4;

  /// How the first page moves with the quick settings ([QsTileMotion]).
  final QsTileMotion? motion;

  /// The bar under the grid with the page dots (AOSP FooterHeight).
  static const double footerHeight = 48;
  static const double pageSpacing = 16;

  final List<Widget> tiles;
  final PageController controller;

  /// Only the full quick settings page; the first pull shows page one.
  final bool scrollable;

  static int _span(Widget tile) => PixelTileGrid._wide(tile) ? 2 : 1;

  /// [tiles] split into pages of at most [rowsPerPage] rows.
  static List<List<Widget>> pagesOf(List<Widget> tiles) {
    final pages = <List<Widget>>[];
    var page = <Widget>[];
    var rows = 0;
    var used = PixelQs.columns;
    for (final tile in tiles) {
      final span = _span(tile);
      if (used + span > PixelQs.columns) {
        rows++;
        used = 0;
        if (rows > rowsPerPage) {
          pages.add(page);
          page = <Widget>[];
          rows = 1;
        }
      }
      page.add(tile);
      used += span;
    }
    if (page.isNotEmpty) pages.add(page);
    return pages;
  }

  /// Rows [tiles] take in one grid.
  static int rowsOf(List<Widget> tiles) {
    var rows = 0;
    var used = PixelQs.columns;
    for (final tile in tiles) {
      final span = _span(tile);
      if (used + span > PixelQs.columns) {
        rows++;
        used = 0;
      }
      used += span;
    }
    return rows;
  }

  static double gridHeight(int rows) =>
      rows <= 0 ? 0 : rows * PixelQs.tileHeight + (rows - 1) * PixelQs.gap;

  /// The tallest page's height.
  static double heightOf(List<Widget> tiles) => gridHeight(
    pagesOf(tiles).fold(0, (rows, page) => math.max(rows, rowsOf(page))),
  );

  @override
  Widget build(BuildContext context) {
    final pages = pagesOf(tiles);
    if (pages.length <= 1) return PixelTileGrid(tiles: tiles, motion: motion);
    return LayoutBuilder(
      builder: (context, constraints) => OverflowBox(
        minWidth: constraints.maxWidth + pageSpacing * 2,
        maxWidth: constraints.maxWidth + pageSpacing * 2,
        child: PageView(
          controller: controller,
          physics: scrollable
              ? const PageScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          children: <Widget>[
            for (final (index, page) in pages.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: pageSpacing),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: PixelTileGrid(
                    tiles: page,
                    motion: index == 0 ? motion : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Android's pager dots (AOSP PagerDots): 6 dp dots 4 dp apart, the current
/// page's twice as wide, stretching toward the next as the pages move; in
/// onSurfaceVariant, the others at half alpha. A tap goes to the next page.
class PixelPagerDots extends StatelessWidget {
  const PixelPagerDots({
    super.key,
    required this.controller,
    required this.count,
  });

  static const double _dot = 6;
  static const double _space = 4;

  final PageController controller;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count < 2) return const SizedBox.shrink();
    final scheme = phoneSchemeOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!controller.hasClients) return;
        final page = (controller.page ?? 0).round();
        controller.animateToPage(
          (page + 1) % count,
          duration: androidDuration(300),
          curve: Curves.easeInOut,
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: _dot * 2 + (_dot + _space) * (count - 1),
          height: _dot,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final position =
                  controller.hasClients &&
                      controller.position.hasContentDimensions
                  ? controller.page ?? 0
                  : 0.0;
              return CustomPaint(
                painter: _PagerDotsPainter(
                  position: position.clamp(0.0, count - 1.0),
                  count: count,
                  active: scheme.onSurfaceVariant,
                  inactive: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PagerDotsPainter extends CustomPainter {
  _PagerDotsPainter({
    required this.position,
    required this.count,
    required this.active,
    required this.inactive,
  });

  final double position;
  final int count;
  final Color active;
  final Color inactive;

  @override
  void paint(Canvas canvas, Size size) {
    const dot = PixelPagerDots._dot;
    final current = position.floor();
    final fraction = position - current;
    // AOSP: the current dot gives width to the neighbour the pages move
    // toward; colours switch at the page change.
    final shown = position.round();
    var x = 0.0;
    for (var page = 0; page < count; page++) {
      final width = page == current
          ? dot * 2 - dot * fraction
          : page == current + 1
          ? dot + dot * fraction
          : dot;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, width, size.height),
          Radius.circular(size.height / 2),
        ),
        Paint()..color = page == shown ? active : inactive,
      );
      x += width + PixelPagerDots._space;
    }
  }

  @override
  bool shouldRepaint(_PagerDotsPainter old) =>
      old.position != position ||
      old.count != count ||
      old.active != active ||
      old.inactive != inactive;
}

/// The first pull's squish, for the icon wells of the quick tiles. It never
/// rebuilds its dependents: the animation repaints them.
class QsTileSquish extends InheritedWidget {
  const QsTileSquish({required this.squish, required super.child, super.key});

  final Animation<double> squish;

  static Animation<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QsTileSquish>()?.squish;

  @override
  bool updateShouldNotify(QsTileSquish oldWidget) =>
      !identical(squish, oldWidget.squish);
}

/// AOSP's `verticalSquish` on an icon well, painted: it shows a band [squish]
/// of its height around its centre, with its shape's corners. 1 draws it as
/// laid out.
class _SquishedWell extends SingleChildRenderObjectWidget {
  const _SquishedWell({
    required this.radius,
    required this.squish,
    required super.child,
  });

  final double radius;
  final Animation<double> squish;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSquishedWell(radius, squish);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSquishedWell renderObject,
  ) {
    renderObject
      ..radius = radius
      ..squish = squish;
  }
}

class _RenderSquishedWell extends RenderProxyBox {
  _RenderSquishedWell(this._radius, this._squish);

  double _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  Animation<double> _squish;
  set squish(Animation<double> value) {
    if (identical(value, _squish)) return;
    if (attached) _squish.removeListener(markNeedsPaint);
    _squish = value;
    if (attached) _squish.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipRRectLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _squish.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _squish.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final s = _squish.value.clamp(0.0, 1.0);
    if (s >= 1) {
      _clip.layer = null;
      context.paintChild(child, offset);
      return;
    }
    final h = size.height;
    final shown = h * s;
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      RRect.fromLTRBR(
        0,
        (h - shown) / 2,
        size.width,
        (h + shown) / 2,
        Radius.circular(math.min(_radius, shown / 2)),
      ),
      (context, offset) => context.paintChild(child, offset),
      oldLayer: _clip.layer,
    );
  }
}
