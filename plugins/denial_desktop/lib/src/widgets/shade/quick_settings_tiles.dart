import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../phone_scheme.dart';

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
    final onDetails = widget.onDetails;
    final VoidCallback? details = onDetails == null
        ? null
        : () => onDetails(_onScreen());
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
        child: Icon(
          widget.icon,
          size: phoneIconSize,
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
    // AOSP squishes the icon well on its own, after its background is drawn
    // (LargeTileContent's verticalSquish): a shorter rounded shape, centred.
    final squish = QsTileSquish.of(context);
    final Widget squishedWell = squish == null
        ? well
        : _SquishedTile(
            row: 0,
            stacked: false,
            radius: active ? 16 : PixelQs.well / 2,
            squish: squish,
            child: well,
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
              child: Column(
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
/// squish with the shade's first pull ([squish], 0.5 to 1:
/// `verticalSquish`), the other rows fade with the quick settings' content
/// ([contentAlpha]). Paint only: neither lays the grid out again.
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

  /// The tile's corner radius, which its squished clip keeps
  /// (common_tile_default_*: 24 dp active, round inactive).
  static double _radius(Widget tile) => switch (tile) {
    QuickTile(:final active) when active => 24,
    QsTileSize(:final child) => _radius(child),
    _ => PixelQs.tileHeight / 2,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final column =
          (constraints.maxWidth - PixelQs.gap * (PixelQs.columns - 1)) /
          PixelQs.columns;
      final motion = this.motion;
      var row = -1;
      var used = PixelQs.columns;
      final shared = <Widget>[];
      final rest = <Widget>[];
      for (final tile in tiles) {
        final span = _wide(tile) ? 2 : 1;
        if (used + span > PixelQs.columns) {
          row++;
          used = 0;
        }
        used += span;
        final sized = SizedBox(
          width: span == 2 ? column * 2 + PixelQs.gap : column,
          height: PixelQs.tileHeight,
          child: tile,
        );
        if (motion == null) {
          shared.add(sized);
        } else if (row < motion.sharedRows) {
          shared.add(
            _SquishedTile(
              row: row,
              radius: _radius(tile),
              squish: motion.squish,
              child: QsTileSquish(squish: motion.squish, child: sized),
            ),
          );
        } else {
          rest.add(sized);
        }
      }
      Widget wrap(List<Widget> children) => Wrap(
        spacing: PixelQs.gap,
        runSpacing: PixelQs.gap,
        children: children,
      );
      if (motion == null || rest.isEmpty) return wrap(shared);
      // The rows only the full quick settings show fade in as one layer.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          wrap(shared),
          const SizedBox(height: PixelQs.gap),
          FadeTransition(opacity: motion.contentAlpha, child: wrap(rest)),
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
  // AOSP BrightnessSliderDimensions.Default: 40 dp track with 12 dp outer
  // and 2 dp inner corners, a 4×52 dp thumb 6 dp clear of the track.
  static const double _height = 52;
  static const double _track = 40;
  static const double _handle = 4;
  static const double _handleGap = 6;
  static const double _outer = 12;
  static const double _inner = 2;

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
                  // The icon ends the empty track, 6 dp in (onSurface), or,
                  // when that is too short, the filled one (onPrimary).
                  // Its 28 dp box holds a 24 dp glyph.
                  Positioned(
                    left: iconOnFill ? math.max(8.0, filledEnd - 8 - 24) : null,
                    right: iconOnFill ? null : 8,
                    top: 0,
                    bottom: 0,
                    child: Icon(
                      Icons.brightness_medium_rounded,
                      size: 24,
                      color: iconOnFill ? scheme.onPrimary : scheme.onSurface,
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
          duration: const Duration(milliseconds: 300),
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

/// AOSP's `verticalSquish` on a quick tile, painted: the tile shows a band
/// [squish] of its height around its centre, with its shape's corners, and
/// its row moves up as the rows above it shrink. 1 draws it as laid out.
/// The first pull's squish of the quick tiles, for parts of a tile that
/// squish on their own (the icon well). It never rebuilds its dependents:
/// the animation repaints them.
class QsTileSquish extends InheritedWidget {
  const QsTileSquish({required this.squish, required super.child, super.key});

  final Animation<double> squish;

  static Animation<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QsTileSquish>()?.squish;

  @override
  bool updateShouldNotify(QsTileSquish oldWidget) =>
      !identical(squish, oldWidget.squish);
}

class _SquishedTile extends SingleChildRenderObjectWidget {
  const _SquishedTile({
    required this.row,
    required this.radius,
    required this.squish,
    required super.child,
    this.stacked = true,
  });

  final int row;

  /// Moves up as Compose stacks squished rows; false squishes in place.
  final bool stacked;
  final double radius;
  final Animation<double> squish;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSquishedTile(row, radius, squish, stacked: stacked);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSquishedTile renderObject,
  ) {
    renderObject
      ..row = row
      ..stacked = stacked
      ..radius = radius
      ..squish = squish;
  }
}

class _RenderSquishedTile extends RenderProxyBox {
  _RenderSquishedTile(
    this._row,
    this._radius,
    this._squish, {
    required this._stacked,
  });

  bool _stacked;
  set stacked(bool value) {
    if (value == _stacked) return;
    _stacked = value;
    markNeedsPaint();
  }

  double _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  int _row;
  set row(int value) {
    if (value == _row) return;
    _row = value;
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

  double get _value => _squish.value.clamp(0.0, 1.0);

  /// Compose lays the squished rows out one under the other: a row moves
  /// up by what the rows above and its own half lost.
  double get _shift =>
      _stacked ? -(_row + 0.5) * size.height * (1 - _value) : 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final s = _value;
    if (s >= 1) {
      _clip.layer = null;
      context.paintChild(child, offset);
      return;
    }
    final h = size.height;
    final shown = h * s;
    final at = offset + Offset(0, _shift);
    _clip.layer = context.pushClipRRect(
      needsCompositing,
      at,
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

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_value < 1) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(0, _value >= 1 ? 0 : _shift, 0, 1);
  }
}
