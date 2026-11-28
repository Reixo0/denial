import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/rendering.dart' show AppIconImage;
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../notification_media.dart'
    show NotificationIconRequest, notificationIconPathProvider;
import '../phone_scheme.dart';
import 'quick_settings_panel.dart' show PixelShadeViewport;
import 'shade_expansion_motion.dart' show androidAnimatorScale, androidDuration;

/// Icons in the dialogs, in the shade's `415.7 dp` (`PixelShadeViewport`)
/// units.
const double _iconSize = phoneIconSize;

/// Shows one of Android 17's quick-settings dialogs, grown out of the tile
/// at [origin] (on screen). [builder] gets the dialog's close, which
/// shrinks it back into the tile.
void showQuickSettingsDialog(
  WidgetRef ref, {
  required String keyName,
  required String debugLabel,
  required Rect origin,
  required Widget Function(VoidCallback close) builder,
}) {
  ref
      .read(shellPopupControllerProvider.notifier)
      .show(
        keyName: keyName,
        debugLabel: debugLabel,
        // The dialog runs its own motion and scrim.
        transitionDuration: const Duration(milliseconds: 16),
        barrierColor: const Color(0x00000000),
        builder: (_, handle) => _QsDialogFrame(
          origin: origin,
          onClosed: handle.close,
          builder: builder,
        ),
      );
}

/// Android's dialog geometry, in dp.
abstract final class _QsDialog {
  static const double sideMargin = 16;
  static const double verticalMargin = 48;
  static const double radius = 28;
  static const double rowHeight = 64;

  // AOSP DialogTransitionAnimator LAUNCH_SPRING_PARAMS & COLLAPSE_SPRING_PARAMS,
  // scaled by androidAnimatorScale.
  static const double _scaleFactor =
      androidAnimatorScale * androidAnimatorScale;
  static final SpringDescription launchX = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 700 / _scaleFactor,
    ratio: 1.1,
  );
  static final SpringDescription launchY = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 700 / _scaleFactor,
    ratio: 1.1,
  );
  static final SpringDescription launchScale =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 700 / _scaleFactor,
        ratio: 1.3,
      );

  static final SpringDescription collapseX = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 380 / _scaleFactor,
    ratio: 0.9,
  );
  static final SpringDescription collapseY = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 380 / _scaleFactor,
    ratio: 0.87,
  );
  static final SpringDescription collapseScale =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 380 / _scaleFactor,
        ratio: 0.9,
      );

  static const Tolerance tolerance = Tolerance(distance: 0.002, velocity: 0.01);
}

class _QsDialogFrame extends StatefulWidget {
  const _QsDialogFrame({
    required this.origin,
    required this.onClosed,
    required this.builder,
  });

  final Rect origin;
  final VoidCallback onClosed;
  final Widget Function(VoidCallback close) builder;

  @override
  State<_QsDialogFrame> createState() => _QsDialogFrameState();
}

class _QsDialogFrameState extends State<_QsDialogFrame>
    with TickerProviderStateMixin {
  late final AnimationController _x = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  late final AnimationController _y = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  late final Listenable _motion = Listenable.merge(<Listenable>[
    _x,
    _y,
    _scale,
  ]);
  bool _started = false;
  bool _closing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _x.value = 1;
      _y.value = 1;
      _scale.value = 1;
      return;
    }
    _x.animateWith(
      SpringSimulation(
        _QsDialog.launchX,
        0,
        1,
        0,
        tolerance: _QsDialog.tolerance,
        snapToEnd: true,
      ),
    );
    _y.animateWith(
      SpringSimulation(
        _QsDialog.launchY,
        0,
        1,
        0,
        tolerance: _QsDialog.tolerance,
        snapToEnd: true,
      ),
    );
    _scale.animateWith(
      SpringSimulation(
        _QsDialog.launchScale,
        0,
        1,
        0,
        tolerance: _QsDialog.tolerance,
        snapToEnd: true,
      ),
    );
  }

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    _scale.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _x.value = 0;
      _y.value = 0;
      _scale.value = 0;
      if (mounted) widget.onClosed();
      return;
    }
    Future.wait<void>(<Future<void>>[
      _x
          .animateWith(
            SpringSimulation(
              _QsDialog.collapseX,
              _x.value,
              0,
              _x.velocity,
              tolerance: _QsDialog.tolerance,
              snapToEnd: true,
            ),
          )
          .orCancel
          .catchError((_) {}),
      _y
          .animateWith(
            SpringSimulation(
              _QsDialog.collapseY,
              _y.value,
              0,
              _y.velocity,
              tolerance: _QsDialog.tolerance,
              snapToEnd: true,
            ),
          )
          .orCancel
          .catchError((_) {}),
      _scale
          .animateWith(
            SpringSimulation(
              _QsDialog.collapseScale,
              _scale.value,
              0,
              _scale.velocity,
              tolerance: _QsDialog.tolerance,
              snapToEnd: true,
            ),
          )
          .orCancel
          .catchError((_) {}),
    ]).whenComplete(() {
      if (mounted) widget.onClosed();
    });
  }

  double _contentOpacity() {
    final p = _scale.value.clamp(0.0, 1.0);
    if (_closing) {
      return ((p - 0.6) / 0.4).clamp(0.0, 1.0);
    }
    return const Cubic(
      0,
      0,
      0.2,
      1,
    ).transform(((p - 0.45) / 0.5).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return PixelShadeViewport(
      child: Builder(
        builder: (context) {
          final scheme = phoneSchemeOf(context);
          final padding = MediaQuery.paddingOf(context);
          final insets = EdgeInsets.fromLTRB(
            _QsDialog.sideMargin + padding.left,
            _QsDialog.verticalMargin + padding.top,
            _QsDialog.sideMargin + padding.right,
            _QsDialog.verticalMargin + padding.bottom,
          );
          final content = DefaultTextStyle.merge(
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 16,
              height: 1.25,
              decoration: TextDecoration.none,
            ),
            child: GestureDetector(
              // Taps on the card stay on it.
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: AnimatedBuilder(
                animation: _scale,
                child: widget.builder(_close),
                builder: (context, child) =>
                    Opacity(opacity: _contentOpacity(), child: child),
              ),
            ),
          );
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: AnimatedBuilder(
                  animation: _scale,
                  child: const ColoredBox(color: Color(0x73000000)),
                  builder: (context, child) => Opacity(
                    opacity: _scale.value.clamp(0.0, 1.0),
                    child: child,
                  ),
                ),
              ),
              _MorphingDialogBox(
                origin: widget.origin,
                insets: insets,
                x: _x,
                y: _y,
                scale: _scale,
                motion: _motion,
                surfaceColor: scheme.surfaceContainer,
                radius: _QsDialog.radius,
                child: content,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Measures the dialog at its resting size, then morphs position, size and
/// corners between [origin] and its centred resting box via [x], [y], [scale].
class _MorphingDialogBox extends SingleChildRenderObjectWidget {
  const _MorphingDialogBox({
    required this.origin,
    required this.insets,
    required this.x,
    required this.y,
    required this.scale,
    required this.motion,
    required this.surfaceColor,
    required this.radius,
    required super.child,
  });

  final Rect origin;
  final EdgeInsets insets;
  final Animation<double> x;
  final Animation<double> y;
  final Animation<double> scale;
  final Listenable motion;
  final Color surfaceColor;
  final double radius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMorphingDialogBox(
        origin: origin,
        insets: insets,
        x: x,
        y: y,
        scale: scale,
        motion: motion,
        surfaceColor: surfaceColor,
        radius: radius,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMorphingDialogBox renderObject,
  ) {
    renderObject
      ..origin = origin
      ..insets = insets
      ..x = x
      ..y = y
      ..scale = scale
      ..motion = motion
      ..surfaceColor = surfaceColor
      ..radius = radius;
  }
}

class _RenderMorphingDialogBox extends RenderProxyBox {
  _RenderMorphingDialogBox({
    required Rect origin,
    required EdgeInsets insets,
    required Animation<double> x,
    required Animation<double> y,
    required Animation<double> scale,
    required Listenable motion,
    required Color surfaceColor,
    required double radius,
  }) : this._raw(origin, insets, x, y, scale, motion, surfaceColor, radius);

  _RenderMorphingDialogBox._raw(
    this._origin,
    this._insets,
    this._x,
    this._y,
    this._scale,
    this._motion,
    this._surfaceColor,
    this._radius,
  );

  Rect _origin;
  set origin(Rect value) {
    if (value == _origin) return;
    _origin = value;
    markNeedsPaint();
  }

  EdgeInsets _insets;
  set insets(EdgeInsets value) {
    if (value == _insets) return;
    _insets = value;
    markNeedsLayout();
  }

  Animation<double> _x;
  set x(Animation<double> value) => _x = value;

  Animation<double> _y;
  set y(Animation<double> value) => _y = value;

  Animation<double> _scale;
  set scale(Animation<double> value) => _scale = value;

  Listenable _motion;
  set motion(Listenable value) {
    if (identical(value, _motion)) return;
    if (attached) {
      _motion.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _motion = value;
    markNeedsPaint();
  }

  Color _surfaceColor;
  set surfaceColor(Color value) {
    if (value == _surfaceColor) return;
    _surfaceColor = value;
    markNeedsPaint();
  }

  double _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  final _clipLayer = LayerHandle<ClipRRectLayer>();
  Rect _endRect = Rect.zero;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _motion.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final available = _insets.deflateRect(Offset.zero & size);
    final child = this.child;
    if (child == null) {
      _endRect = Rect.fromCenter(center: available.center, width: 0, height: 0);
      return;
    }
    child.layout(
      BoxConstraints(
        maxWidth: math.min(420.0, math.max(0.0, available.width)),
        maxHeight: math.max(0.0, available.height),
      ),
      parentUsesSize: true,
    );
    _endRect = Rect.fromCenter(
      center: available.center,
      width: child.size.width,
      height: child.size.height,
    );
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _endRect.topLeft,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_endRect.left, _endRect.top, 0, 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final s = _scale.value.clamp(0.0, 1.15);
    if (s <= 0.001) {
      _clipLayer.layer = null;
      return;
    }
    final from = _origin == Rect.zero
        ? Rect.fromCenter(center: _endRect.center, width: 0, height: 0)
        : Rect.fromPoints(
            globalToLocal(_origin.topLeft),
            globalToLocal(_origin.bottomRight),
          );
    final cx = lerpDouble(from.center.dx, _endRect.center.dx, _x.value)!;
    final cy = lerpDouble(from.center.dy, _endRect.center.dy, _y.value)!;
    final w = math.max(0.0, lerpDouble(from.width, _endRect.width, s)!);
    final h = math.max(0.0, lerpDouble(from.height, _endRect.height, s)!);
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
    if (rect.isEmpty) {
      _clipLayer.layer = null;
      return;
    }
    final corner = math.max(
      0.0,
      lerpDouble(from.height / 2, _radius, _scale.value.clamp(0.0, 1.0))!,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(corner));
    _clipLayer.layer = context.pushClipRRect(
      needsCompositing,
      offset,
      rect,
      rrect,
      (context, offset) {
        context.canvas.drawRect(
          rect.shift(offset),
          Paint()..color = _surfaceColor,
        );
        final childTopLeft = Offset(
          cx - child.size.width / 2,
          cy - child.size.height / 2,
        );
        context.paintChild(child, offset + childTopLeft);
      },
      oldLayer: _clipLayer.layer,
    );
  }
}

// Parts ----------------------------------------------------------------------

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.title,
    required this.subtitle,
    required this.busy,
  });

  final String title;
  final String subtitle;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 24,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _ScanBar(busy: busy),
        ],
      ),
    );
  }
}

/// Android's thin progress line under the title: moving while it scans.
class _ScanBar extends StatefulWidget {
  const _ScanBar({required this.busy});

  final bool busy;

  @override
  State<_ScanBar> createState() => _ScanBarState();
}

class _ScanBarState extends State<_ScanBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: androidDuration(1400),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _sweep.stop();
    } else if (widget.busy && !_sweep.isAnimating) {
      unawaited(_sweep.repeat());
    }
  }

  @override
  void didUpdateWidget(covariant _ScanBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !_reduceMotion && !_sweep.isAnimating) {
      unawaited(_sweep.repeat());
    } else if ((!widget.busy || _reduceMotion) && _sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    const width = 136.0;
    return SizedBox(
      width: width,
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: widget.busy
              ? AnimatedBuilder(
                  animation: _sweep,
                  builder: (context, _) {
                    final t = Curves.easeInOut.transform(_sweep.value);
                    return Stack(
                      children: <Widget>[
                        Positioned(
                          left: -40 + (width + 40) * t,
                          top: 0,
                          bottom: 0,
                          width: 40,
                          child: ColoredBox(color: scheme.primary),
                        ),
                      ],
                    );
                  },
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// A row with a label and Android's switch.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onChanged();
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.38,
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PhoneSwitch(value: value),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Material 3's switch, drawn without Material: a 52×32 track, a thumb of
/// 24 dp on and 16 dp off.
class PhoneSwitch extends StatelessWidget {
  const PhoneSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : androidDuration(200);
    final thumb = value ? 24.0 : 16.0;
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      width: 52,
      height: 32,
      decoration: BoxDecoration(
        color: value ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: value ? scheme.primary : scheme.outline,
          width: 2,
        ),
      ),
      child: AnimatedAlign(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: value ? 2 : 6),
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            width: thumb,
            height: thumb,
            decoration: BoxDecoration(
              color: value ? scheme.onPrimary : scheme.outline,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// A network or device: icon, name and state, an optional trailing button.
/// [highlighted] is Android's connected pill.
class _ItemRow extends StatefulWidget {
  const _ItemRow({
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.highlighted = false,
    this.trailing,
    this.dimmed = false,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool highlighted;
  final bool dimmed;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final foreground = widget.highlighted
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final subtitle = widget.subtitle;
    var background = widget.highlighted
        ? scheme.primaryContainer
        : const Color(0x00000000);
    if (_pressed) {
      background = Color.alphaBlend(
        foreground.withValues(alpha: 0.10),
        background,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Semantics(
        button: widget.onTap != null,
        label: widget.title,
        value: subtitle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.onTap == null ? null : (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : androidDuration(150),
            constraints: const BoxConstraints(minHeight: _QsDialog.rowHeight),
            padding: const EdgeInsetsDirectional.only(start: 20, end: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(_QsDialog.rowHeight / 2),
            ),
            child: Row(
              children: <Widget>[
                IconTheme(
                  data: IconThemeData(
                    color: widget.dimmed
                        ? foreground.withValues(alpha: 0.6)
                        : foreground,
                    size: _iconSize,
                  ),
                  child: widget.leading,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: foreground, fontSize: 16),
                        ),
                        if (subtitle != null && subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.highlighted
                                  ? foreground
                                  : scheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.trailing case final trailing?)
                  IconTheme(
                    data: IconThemeData(color: foreground, size: _iconSize),
                    child: trailing,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round 48 dp button with an icon, such as a row's settings gear.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(dimension: 48, child: Icon(icon)),
    ),
  );
}

/// Android's filled "Done" button, at the dialog's end.
class _DialogButtons extends StatelessWidget {
  const _DialogButtons({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Semantics(
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDone,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                context.l10n.quickSettingsDone,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rows between the header and the buttons, scrolling when the screen
/// is short.
class _DialogBody extends StatelessWidget {
  const _DialogBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Flexible(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

// Wi-Fi ----------------------------------------------------------------------

/// Android's Internet dialog: the Wi-Fi switch, nearby networks with the
/// connected one first, and the way to Phone Settings.
class QuickSettingsWifiDialog extends ConsumerStatefulWidget {
  const QuickSettingsWifiDialog({
    super.key,
    required this.onClose,
    required this.onOpenSettings,
  });

  static const int _shown = 4;

  final VoidCallback onClose;

  /// Closes the shade and opens the Wi-Fi page in Phone Settings.
  final VoidCallback onOpenSettings;

  @override
  ConsumerState<QuickSettingsWifiDialog> createState() =>
      _QuickSettingsWifiDialogState();
}

class _QuickSettingsWifiDialogState
    extends ConsumerState<QuickSettingsWifiDialog> {
  @override
  void initState() {
    super.initState();
    // Fresh results, as Android scans while the dialog is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(networkConnectivityProvider);
      if (state.snapshot.wirelessEnabled && !state.scanning) {
        unawaited(ref.read(networkConnectivityProvider.notifier).scan());
      }
    });
  }

  void _activate(WifiNetwork network, NetworkConnectivityState state) {
    final controller = ref.read(networkConnectivityProvider.notifier);
    if (network.connected) {
      widget.onOpenSettings();
    } else if (!network.saved && network.security.requiresPassword) {
      // The password is asked for on the Wi-Fi page.
      widget.onOpenSettings();
    } else if (network.connectable) {
      unawaited(controller.connect(network));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(networkConnectivityProvider);
    final snapshot = state.snapshot;
    final controller = ref.read(networkConnectivityProvider.notifier);
    final radioEnabled =
        !state.initializing &&
        snapshot.serviceAvailable &&
        snapshot.wifiDeviceAvailable &&
        snapshot.wirelessHardwareEnabled &&
        snapshot.radioPermission != NetworkPermission.denied &&
        !state.radioChanging;
    final networks = snapshot.wirelessEnabled
        ? ([...snapshot.networks]..sort((a, b) {
                // Connected first, then saved, then by strength.
                int rank(WifiNetwork n) => n.connected
                    ? 0
                    : n.saved
                    ? 1
                    : 2;
                final byRank = rank(a).compareTo(rank(b));
                return byRank != 0 ? byRank : b.strength.compareTo(a.strength);
              }))
              .take(QuickSettingsWifiDialog._shown)
              .toList()
        : const <WifiNetwork>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DialogHeader(
          title: l10n.commonWifi,
          subtitle: l10n.quickSettingsWifiHint,
          busy: state.scanning || state.radioChanging,
        ),
        _DialogBody(
          children: <Widget>[
            _SwitchRow(
              label: l10n.quickSettingsUseWifi,
              value: snapshot.wirelessEnabled,
              enabled: radioEnabled,
              onChanged: controller.toggleWireless,
            ),
            for (final network in networks) _wifiRow(context, network, state),
            if (snapshot.wirelessEnabled)
              _ItemRow(
                leading: const Icon(Icons.chevron_right_rounded),
                title: l10n.quickSettingsSeeAll,
                onTap: widget.onOpenSettings,
              ),
          ],
        ),
        _DialogButtons(onDone: widget.onClose),
      ],
    );
  }

  Widget _wifiRow(
    BuildContext context,
    WifiNetwork network,
    NetworkConnectivityState state,
  ) {
    final l10n = context.l10n;
    final busy = state.busyNetworks.contains(network.identity);
    final status = busy
        ? l10n.commonConnecting
        : network.connected
        ? l10n.settingsConnected
        : network.saved
        ? l10n.quickSettingsSaved
        : null;
    return _ItemRow(
      leading: Icon(_wifiIcon(network.strength)),
      title: network.ssid,
      subtitle: status,
      highlighted: network.connected,
      dimmed: !network.connected,
      onTap: busy ? null : () => _activate(network, state),
      trailing: network.connected
          ? _IconAction(
              icon: Icons.settings_outlined,
              label: l10n.quickSettingsItemSettings(network.ssid),
              onTap: widget.onOpenSettings,
            )
          : network.security.requiresPassword
          ? const SizedBox.square(
              dimension: 48,
              child: Icon(Icons.lock_outline_rounded),
            )
          : null,
    );
  }

  static IconData _wifiIcon(int strength) => strength >= 75
      ? Icons.wifi_rounded
      : strength >= 50
      ? Icons.network_wifi_3_bar_rounded
      : strength >= 25
      ? Icons.network_wifi_2_bar_rounded
      : Icons.network_wifi_1_bar_rounded;
}

// Bluetooth ------------------------------------------------------------------

/// Android's Bluetooth dialog: the switch, saved devices to connect or
/// disconnect, and pairing in Phone Settings.
class QuickSettingsBluetoothDialog extends ConsumerWidget {
  const QuickSettingsBluetoothDialog({
    super.key,
    required this.onClose,
    required this.onOpenSettings,
  });

  static const int _shown = 4;

  final VoidCallback onClose;

  /// Closes the shade and opens the Bluetooth page in Phone Settings.
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = phoneSchemeOf(context);
    final state = ref.watch(bluetoothProvider);
    final controller = ref.read(bluetoothProvider.notifier);
    final usable =
        !state.initializing &&
        state.serviceAvailable &&
        state.available &&
        !state.powerChanging;
    final devices = state.powered
        ? ([...state.devices.where((device) => device.paired)]..sort(
                (a, b) => (b.connected ? 1 : 0).compareTo(a.connected ? 1 : 0),
              ))
              .take(_shown)
              .toList()
        : const <BluetoothDeviceInfo>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DialogHeader(
          title: l10n.commonBluetooth,
          subtitle: l10n.quickSettingsBluetoothHint,
          busy: state.scanning || state.powerChanging,
        ),
        _DialogBody(
          children: <Widget>[
            _SwitchRow(
              label: l10n.quickSettingsUseBluetooth,
              value: state.powered,
              enabled: usable,
              onChanged: controller.togglePower,
            ),
            for (final device in devices)
              _deviceRow(context, scheme, state, controller, device),
            if (state.powered)
              _ItemRow(
                leading: const Icon(Icons.add_rounded),
                title: l10n.quickSettingsPairNewDevice,
                onTap: onOpenSettings,
              ),
          ],
        ),
        _DialogButtons(onDone: onClose),
      ],
    );
  }

  Widget _deviceRow(
    BuildContext context,
    ColorScheme scheme,
    BluetoothState state,
    BluetoothController controller,
    BluetoothDeviceInfo device,
  ) {
    final l10n = context.l10n;
    final busy = state.busyDevices.contains(device.objectPath);
    final name = device.name.isEmpty ? device.address : device.name;
    return _ItemRow(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: device.connected
              ? scheme.onPrimaryContainer
              : scheme.tertiaryContainer,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          _deviceIcon(device.icon),
          size: 18,
          color: device.connected
              ? scheme.primaryContainer
              : scheme.onTertiaryContainer,
        ),
      ),
      title: name,
      subtitle: busy
          ? l10n.commonConnecting
          : device.connected
          ? l10n.settingsConnected
          : l10n.quickSettingsSaved,
      highlighted: device.connected,
      onTap: busy ? null : () => unawaited(controller.toggleConnection(device)),
      trailing: _IconAction(
        icon: Icons.settings_outlined,
        label: l10n.quickSettingsItemSettings(name),
        onTap: onOpenSettings,
      ),
    );
  }

  static IconData _deviceIcon(String icon) {
    if (icon.contains('audio') || icon.contains('headset')) {
      return Icons.headphones_rounded;
    }
    if (icon.contains('input') || icon.contains('keyboard')) {
      return Icons.keyboard_rounded;
    }
    if (icon.contains('mouse')) return Icons.mouse_rounded;
    if (icon.contains('phone')) return Icons.smartphone_rounded;
    if (icon.contains('computer')) return Icons.computer_rounded;
    if (icon.contains('watch')) return Icons.watch_rounded;
    return Icons.bluetooth_rounded;
  }
}

// Active apps ----------------------------------------------------------------

/// Android's task manager dialog: the apps that are active, how long, and a
/// Stop button for those the user may stop. A stopped app stays, marked so,
/// until the dialog closes.
class QuickSettingsActiveAppsDialog extends ConsumerStatefulWidget {
  const QuickSettingsActiveAppsDialog({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<QuickSettingsActiveAppsDialog> createState() =>
      _QuickSettingsActiveAppsDialogState();
}

class _QuickSettingsActiveAppsDialogState
    extends ConsumerState<QuickSettingsActiveAppsDialog> {
  final Map<String, ActiveApp> _stopped = <String, ActiveApp>{};

  String _since(BuildContext context, DateTime since) {
    final l10n = context.l10n;
    final time = DateTime.now().difference(since);
    if (time.inMinutes < 1) return l10n.notificationTimeNow;
    if (time.inHours < 1) return l10n.notificationTimeMinutes(time.inMinutes);
    if (time.inDays < 1) return l10n.notificationTimeHours(time.inHours);
    return l10n.notificationTimeDays(time.inDays);
  }

  void _stop(ActiveApp app) {
    setState(() => _stopped[app.package] = app);
    unawaited(ref.read(activeAppsServiceProvider).stop(app.package));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = phoneSchemeOf(context);
    final active = ref.watch(activeAppsProvider).value ?? const <ActiveApp>[];
    final listed = <String, ActiveApp>{
      ..._stopped,
      for (final app in active) app.package: app,
    };
    final apps = listed.values.toList()
      ..sort((a, b) => b.since.compareTo(a.since));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DialogHeader(
          title: l10n.activeAppsTitle,
          subtitle: l10n.activeAppsMessage,
          busy: false,
        ),
        _DialogBody(
          children: <Widget>[
            for (final app in apps)
              _ItemRow(
                leading: SizedBox.square(
                  dimension: 28,
                  child: _ActiveAppIcon(app: app),
                ),
                title: app.label,
                subtitle: _since(context, app.since),
                onTap: null,
                trailing: !app.stoppable
                    ? null
                    : _TextAction(
                        label: _stopped.containsKey(app.package)
                            ? l10n.activeAppsStopped
                            : l10n.activeAppsStop,
                        color: scheme.primary,
                        onTap: _stopped.containsKey(app.package)
                            ? null
                            : () => _stop(app),
                      ),
              ),
          ],
        ),
        _DialogButtons(onDone: widget.onClose),
      ],
    );
  }
}

class _ActiveAppIcon extends ConsumerWidget {
  const _ActiveAppIcon({required this.app});

  final ActiveApp app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(
      notificationIconPathProvider(
        NotificationIconRequest(
          appIcon: '',
          desktopEntry: app.desktopEntry,
          appName: app.label,
        ),
      ),
    );
    return AppIconImage(iconPath: path.value);
  }
}

/// A row's text button.
class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 64, minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                color: onTap == null ? color.withValues(alpha: 0.38) : color,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
