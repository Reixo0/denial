import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:denial_flutter_sdk/tokens.dart' show ShellText;

import '../phone_scheme.dart';
import '../shade/shade_expansion_motion.dart' show androidDuration;
import 'keyguard_pin_shapes.dart';
import 'keyguard_pin_shapes_data.dart';

/// Android's PIN bouncer (KeyguardPINView with the bouncer revamp, as
/// EvolutionX draws it on this phone): the message at the top, the PIN's
/// shapes, a round 3 x 4 keypad low on the screen with the delete key bare
/// and the enter key on a faint disc.
///
/// Geometry in dp, measured on EvolutionX's own PIN bouncer on the NX809J
/// (1216 x 2688, 2.925 px per dp): keys 84 dp across on a 104.3 x 96.1 dp
/// pitch (the 12 dp row gap is num_pad_entry_row_margin_bottom), the last
/// row 146.3 dp above the bottom, the message centred 110 dp from the top,
/// the shapes centred 125 dp above the first row (the emulator's Android 17
/// bouncer, laid out the same, places them there).
abstract final class KeyguardPinMetrics {
  static const double key = 84;
  static const double columnPitch = 104.3;
  static const double rowPitch = 96.1;
  static const double padBottom = 146.3;
  static const double messageCentre = 110;
  static const double entryAboveKeys = 125;

  /// password_shape_size.
  static const double shape = 30;

  /// Widget.TextView.NumPadKey.Digit: 32 dp, in GSF_LABEL_SMALL_EMPHASIZED
  /// (Google Sans Flex, measured on EvolutionX as weight 700, round 100).
  static const double digitSize = 32;

  /// Its -16 dp bottom padding sets the digits this much below the key's
  /// centre (measured on EvolutionX).
  static const double digitDrop = 3.4;

  /// Keyguard.Bouncer.PrimaryMessage: 18 sp.
  static const double messageSize = 18;

  /// pin_bouncer_delete_filled and pin_bouncer_confirm are 40 dp boxes.
  static const double actionIcon = 40;

  /// KeyguardPINView: ANIMATION_DURATION, pin_view_trans_y_entry and its
  /// per-row offset.
  static const int appearMs = 650;
  static const double appearRise = 120;
  static const double appearRowRise = 10;

  /// The top of the keypad's first row, from the top of [size].
  static double keysTop(Size size, double dp) =>
      size.height - padBottom * dp - (3 * rowPitch + key) * dp;
}

/// Material interpolators the bouncer uses.
abstract final class _Interpolators {
  static const Curve standard = Cubic(0.2, 0, 0, 1);
  static const Curve standardDecelerate = Cubic(0, 0, 0, 1);
  static const Curve legacyDecelerate = Cubic(0, 0, 0.2, 1);
  static const Curve linearOutSlowIn = Cubic(0, 0, 0.2, 1);
}

/// The PIN's shapes, driven by the stage: one per digit (PinShapeNonHintingView).
class KeyguardPinEntryController extends ChangeNotifier {
  final List<_EntryEvent> _events = <_EntryEvent>[];

  /// A digit was typed.
  void append() => _push(_EntryEvent.append);

  /// The last digit was deleted.
  void delete() => _push(_EntryEvent.delete);

  /// All digits go, the last first (a wrong PIN, a long press on delete).
  void reset() => _push(_EntryEvent.reset);

  void _push(_EntryEvent event) {
    _events.add(event);
    notifyListeners();
  }

  List<_EntryEvent> _take() {
    final taken = List<_EntryEvent>.of(_events);
    _events.clear();
    return taken;
  }
}

enum _EntryEvent { append, delete, reset }

/// The PIN bouncer's content, over a background the caller draws.
class KeyguardPinView extends StatefulWidget {
  const KeyguardPinView({
    super.key,
    required this.scheme,
    required this.message,
    required this.entry,
    required this.appear,
    required this.enabled,
    required this.onDigit,
    required this.onDelete,
    required this.onClear,
    required this.onEnter,
  });

  final ColorScheme scheme;

  /// The bouncer's primary message ("Enter PIN", "Wrong PIN. Try again.").
  final String message;
  final KeyguardPinEntryController entry;

  /// KeyguardPINView.startAppearAnimation's progress, 0 to 1 over 650 ms,
  /// linear: each row curves it itself.
  final Animation<double> appear;
  final bool enabled;
  final ValueChanged<int> onDigit;
  final VoidCallback onDelete;

  /// A long press on delete.
  final VoidCallback onClear;
  final VoidCallback onEnter;

  @override
  State<KeyguardPinView> createState() => _KeyguardPinViewState();
}

class _KeyguardPinViewState extends State<KeyguardPinView> {
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dp = _dp(size);
    final scheme = widget.scheme;
    final keysTop = KeyguardPinMetrics.keysTop(size, dp);
    final padWidth =
        (2 * KeyguardPinMetrics.columnPitch + KeyguardPinMetrics.key) * dp;
    final padLeft = (size.width - padWidth) / 2;

    // Row 0 is the shapes, rows 1 to 4 the keys, row 5 the emergency
    // button (not shown: Denial has no emergency dialer).
    Widget row(int index, Widget child) =>
        _AppearRow(appear: widget.appear, index: index, dp: dp, child: child);

    final keys = <Widget>[];
    const digits = <int?>[1, 2, 3, 4, 5, 6, 7, 8, 9, null, 0, null];
    for (var slot = 0; slot < digits.length; slot++) {
      final column = slot % 3;
      final line = slot ~/ 3;
      final digit = digits[slot];
      final Widget key = digit != null
          ? _PinKey(
              dp: dp,
              scheme: scheme,
              enabled: widget.enabled,
              background: scheme.surfaceEffect1,
              appear: widget.appear,
              row: line + 1,
              semanticsLabel: '$digit',
              onTap: () => widget.onDigit(digit),
              builder: (color, scaleX) => Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(scaleX, 1, 1)
                  ..setTranslationRaw(0, KeyguardPinMetrics.digitDrop * dp, 0),
                child: Text(
                  '$digit',
                  textScaler: TextScaler.noScaling,
                  style: ShellText.base.copyWith(
                    fontFamily: ShellText.clockFontFamily,
                    fontSize: KeyguardPinMetrics.digitSize * dp,
                    height: 1,
                    color: color,
                    fontVariations: const [
                      FontVariation('wght', 700),
                      FontVariation('ROND', 100),
                    ],
                    letterSpacing: 0,
                  ),
                ),
              ),
            )
          : slot == 9
          ? _PinKey(
              dp: dp,
              scheme: scheme,
              enabled: widget.enabled,
              background: null,
              appear: widget.appear,
              row: line + 1,
              semanticsLabel: 'Delete',
              onTap: widget.onDelete,
              onLongPress: widget.onClear,
              builder: (color, _) => _ActionIcon(
                svg: _deleteFilledSvg,
                color: color,
                size: KeyguardPinMetrics.actionIcon * dp,
              ),
            )
          : _PinKey(
              dp: dp,
              scheme: scheme,
              enabled: widget.enabled,
              background: scheme.surfaceEffect3,
              appear: widget.appear,
              row: line + 1,
              semanticsLabel: 'Enter',
              onTap: widget.onEnter,
              builder: (color, _) => _ActionIcon(
                svg: _confirmSvg,
                color: color,
                size: KeyguardPinMetrics.actionIcon * dp,
              ),
            );
      keys.add(
        Positioned(
          left: padLeft + column * KeyguardPinMetrics.columnPitch * dp,
          top: keysTop + line * KeyguardPinMetrics.rowPitch * dp,
          width: KeyguardPinMetrics.key * dp,
          height: KeyguardPinMetrics.key * dp,
          child: row(line + 1, key),
        ),
      );
    }

    final entryCentre = keysTop - KeyguardPinMetrics.entryAboveKeys * dp;
    return Stack(
      fit: StackFit.expand,
      children: [
        // The message rises with the standard-decelerate part alone.
        Positioned(
          left: 24 * dp,
          right: 24 * dp,
          top: KeyguardPinMetrics.messageCentre * dp - 12 * dp,
          height: 24 * dp,
          child: AnimatedBuilder(
            animation: widget.appear,
            builder: (context, child) {
              final p = _Interpolators.standardDecelerate.transform(
                widget.appear.value.clamp(0.0, 1.0),
              );
              return Opacity(
                opacity: p,
                child: Transform.translate(
                  offset: Offset(
                    0,
                    KeyguardPinMetrics.appearRise * dp * (1 - p),
                  ),
                  child: child,
                ),
              );
            },
            child: Center(
              child: Text(
                widget.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textScaler: TextScaler.noScaling,
                style: ShellText.base.copyWith(
                  fontFamily: ShellText.clockFontFamily,
                  fontSize: KeyguardPinMetrics.messageSize * dp,
                  height: 1,
                  color: scheme.onSurface,
                  fontVariations: const [FontVariation('wght', 400)],
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: entryCentre - KeyguardPinMetrics.shape * dp / 2,
          height: KeyguardPinMetrics.shape * dp,
          child: row(
            0,
            _PinEntry(
              controller: widget.entry,
              color: scheme.onSurface,
              shape: KeyguardPinMetrics.shape * dp,
            ),
          ),
        ),
        ...keys,
      ],
    );
  }
}

/// Logical pixels per dp on this screen: the phone's 1216 px wide panel is
/// 415.7 dp (density 468).
double _dp(Size size) => size.width / (1216 / 2.925);

/// One row of KeyguardPINView.animate: it starts 7.5 % of the time later
/// than the row above, fades with LEGACY_DECELERATE and rises from
/// 120 + 10 x row dp with STANDARD_DECELERATE.
class _AppearRow extends StatelessWidget {
  const _AppearRow({
    required this.appear,
    required this.index,
    required this.dp,
    required this.child,
  });

  final Animation<double> appear;
  final int index;
  final double dp;
  final Widget child;

  static const int _rows = 6;

  static double scaled(double progress, int index) =>
      _Interpolators.legacyDecelerate.transform(
        ((progress - 0.075 * index) / (1 - 0.075 * _rows)).clamp(0.0, 1.0),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appear,
    child: child,
    builder: (context, child) {
      final progress = appear.value.clamp(0.0, 1.0);
      if (progress >= 1) return child!;
      final rise =
          (KeyguardPinMetrics.appearRise +
              KeyguardPinMetrics.appearRowRise * index) *
          dp *
          (1 - _Interpolators.standardDecelerate.transform(progress));
      return Opacity(
        opacity: scaled(progress, index),
        child: Transform.translate(offset: Offset(0, rise), child: child),
      );
    },
  );
}

/// A key: NumPadKey or NumPadButton with NumPadAnimator. Pressed, its disc
/// turns into a rounded square (corner radius half the height to a quarter)
/// in primaryContainer and the label stretches 1.35 wide in
/// onPrimaryContainer, over 33 ms; released it goes back over 300 ms with
/// STANDARD (bouncerUiRevamp2). While the keypad appears its disc grows from
/// 70 % of its height (setProgress). A key without [background] (delete)
/// has no animator.
class _PinKey extends StatefulWidget {
  const _PinKey({
    required this.dp,
    required this.scheme,
    required this.enabled,
    required this.background,
    required this.appear,
    required this.row,
    required this.semanticsLabel,
    required this.onTap,
    required this.builder,
    this.onLongPress,
  });

  final double dp;
  final ColorScheme scheme;
  final bool enabled;
  final Color? background;
  final Animation<double> appear;
  final int row;
  final String semanticsLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget Function(Color color, double scaleX) builder;

  @override
  State<_PinKey> createState() => _PinKeyState();
}

class _PinKeyState extends State<_PinKey> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(vsync: this);

  void _down() {
    if (!widget.enabled || widget.background == null) return;
    _press.animateTo(1, duration: androidDuration(33), curve: Curves.linear);
  }

  void _up() {
    if (widget.background == null) return;
    _press.animateTo(
      0,
      duration: androidDuration(300),
      curve: _Interpolators.standard,
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final background = widget.background;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _down(),
        onTapUp: (_) => _up(),
        onTapCancel: _up,
        onTap: widget.enabled ? widget.onTap : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
        child: AnimatedBuilder(
          animation: Listenable.merge([_press, widget.appear]),
          builder: (context, _) {
            final pressed = _press.value;
            final grown = _AppearRow.scaled(
              widget.appear.value.clamp(0.0, 1.0),
              widget.row,
            );
            final color = Color.lerp(
              scheme.onSurface,
              scheme.onPrimaryContainer,
              pressed,
            )!;
            return CustomPaint(
              painter: background == null
                  ? null
                  : _KeyDiscPainter(
                      color: Color.lerp(
                        background,
                        scheme.primaryContainer,
                        pressed,
                      )!,
                      pressed: pressed,
                      grown: grown,
                    ),
              child: Center(child: widget.builder(color, 1 + 0.35 * pressed)),
            );
          },
        ),
      ),
    );
  }
}

class _KeyDiscPainter extends CustomPainter {
  const _KeyDiscPainter({
    required this.color,
    required this.pressed,
    required this.grown,
  });

  final Color color;

  /// 0 a disc, 1 the pressed rounded square.
  final double pressed;

  /// NumPadAnimator.setProgress: 0.7 of the height at 0, all of it at 1,
  /// with the radius from a quarter of the height to half.
  final double grown;

  @override
  void paint(Canvas canvas, Size size) {
    final height = size.height * (0.7 + 0.3 * grown);
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width,
      height: height,
    );
    final rest = size.height / 4 + (size.height / 2 - size.height / 4) * grown;
    final radius = rest + (size.height / 4 - rest) * pressed;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_KeyDiscPainter old) =>
      old.color != color || old.pressed != pressed || old.grown != grown;
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.svg,
    required this.color,
    required this.size,
  });

  final String svg;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    svg,
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );
}

/// The shapes, centred; once they no longer fit, the newest stay in view
/// (PinShapeNonHintingView.onLayout). A new one takes its place at once
/// while the others slide over 160 ms with LINEAR_OUT_SLOW_IN; a deleted
/// one shrinks away over 160 ms first; a reset deletes them from the last,
/// min(200 / count, 40) ms apart.
class _PinEntry extends StatefulWidget {
  const _PinEntry({
    required this.controller,
    required this.color,
    required this.shape,
  });

  final KeyguardPinEntryController controller;
  final Color color;
  final double shape;

  @override
  State<_PinEntry> createState() => _PinEntryState();
}

class _PinShape {
  _PinShape(this.drawable, this.born);

  final AvdDrawable drawable;

  /// When it was typed, on the ticker's clock (ms).
  final double born;

  /// Its slot's x, sliding from [from] to [to] since [moved].
  double from = 0;
  double to = 0;
  double moved = -1e9;

  /// When its delete began, or null.
  double? deleting;
}

class _PinEntryState extends State<_PinEntry>
    with SingleTickerProviderStateMixin {
  static const double _slide = 160;
  static const double _shrink = 160;

  /// Repaints while something moves; time comes from [_clock].
  late final Ticker _ticker = createTicker(_tick);
  final Stopwatch _clock = Stopwatch()..start();
  final List<_PinShape> _shapes = <_PinShape>[];

  /// PinShapeAdapter: the six shapes in a shuffled order, then round again.
  late final List<AvdDrawable> _order = List<AvdDrawable>.of(keyguardPinShapes)
    ..shuffle(math.Random());
  int _position = 0;

  /// Deletes still to start: when each starts (ms).
  final List<double> _pendingDeletes = <double>[];

  /// Typing during a reset waits for it (mDelayedAppend).
  int _delayedAppends = 0;
  bool _resetting = false;

  double _width = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handle);
  }

  @override
  void didUpdateWidget(covariant _PinEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handle);
      widget.controller.addListener(_handle);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handle);
    _ticker.dispose();
    super.dispose();
  }

  /// Android time (ms): Denial runs Android's durations at its animator
  /// scale.
  double get _ms => _clock.elapsedMicroseconds / 1000.0 / _scale;

  static final double _scale =
      androidDuration(1000).inMicroseconds /
      const Duration(seconds: 1).inMicroseconds;

  void _wake() {
    if (!_ticker.isTicking) _ticker.start();
  }

  bool get _moving {
    final now = _ms;
    return _pendingDeletes.isNotEmpty ||
        _shapes.any(
          (shape) =>
              shape.deleting != null ||
              now - shape.born < 350 ||
              now - shape.moved < _slide,
        );
  }

  void _tick(Duration elapsed) {
    final now = _ms;
    // Deletes whose turn has come.
    while (_pendingDeletes.isNotEmpty && _pendingDeletes.first <= now) {
      _pendingDeletes.removeAt(0);
      _deleteLast();
      if (_pendingDeletes.isEmpty) {
        _resetting = false;
        final appends = _delayedAppends;
        _delayedAppends = 0;
        for (var i = 0; i < appends; i++) {
          _append();
        }
      }
    }
    // Shrunk shapes leave, and the rest close up.
    final before = _shapes.length;
    _shapes.removeWhere(
      (shape) => shape.deleting != null && now - shape.deleting! >= _shrink,
    );
    if (_shapes.length != before) _relayout();
    setState(() {});
    if (!_moving) _ticker.stop();
  }

  void _handle() {
    for (final event in widget.controller._take()) {
      switch (event) {
        case _EntryEvent.append:
          if (_resetting) {
            _delayedAppends++;
          } else {
            _append();
          }
        case _EntryEvent.delete:
          _deleteLast();
        case _EntryEvent.reset:
          final count = _shapes.where((s) => s.deleting == null).length;
          if (count == 0) break;
          final base = math.min(200 / count, 40.0);
          _resetting = true;
          for (var i = 0; i < count; i++) {
            _pendingDeletes.add(_ms + base * i);
          }
      }
    }
    _wake();
    setState(() {});
  }

  void _append() {
    final shape = _PinShape(_order[_position % _order.length], _ms);
    _position++;
    _shapes.add(shape);
    _relayout(appended: shape);
  }

  void _deleteLast() {
    final live = _shapes.where((s) => s.deleting == null).toList();
    if (live.isEmpty) return;
    live.last.deleting = _ms;
    _position = math.max(0, _position - 1);
  }

  double _x(_PinShape shape) {
    final t = ((_ms - shape.moved) / _slide).clamp(0.0, 1.0);
    return shape.from +
        (shape.to - shape.from) * _Interpolators.linearOutSlowIn.transform(t);
  }

  /// Centred, or held at the end once wider than the row.
  void _relayout({_PinShape? appended}) {
    final size = widget.shape;
    final total = _shapes.length * size;
    final start = total <= _width ? (_width - total) / 2 : _width - total;
    for (var i = 0; i < _shapes.length; i++) {
      final shape = _shapes[i];
      final target = start + i * size;
      if (identical(shape, appended)) {
        shape
          ..from = target
          ..to = target
          ..moved = _ms;
      } else if (shape.to != target) {
        shape
          ..from = _x(shape)
          ..to = target
          ..moved = _ms;
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth != _width) {
        _width = constraints.maxWidth;
        _relayout();
      }
      return ClipRect(
        child: CustomPaint(
          size: Size(constraints.maxWidth, widget.shape),
          painter: _PinEntryPainter(
            shapes: _shapes,
            now: _ms,
            x: _x,
            size: widget.shape,
            color: widget.color,
            shrink: _shrink,
          ),
        ),
      );
    },
  );
}

class _PinEntryPainter extends CustomPainter {
  _PinEntryPainter({
    required this.shapes,
    required this.now,
    required this.x,
    required this.size,
    required this.color,
    required this.shrink,
  });

  final List<_PinShape> shapes;
  final double now;
  final double Function(_PinShape) x;
  final double size;
  final Color color;
  final double shrink;

  @override
  void paint(Canvas canvas, Size area) {
    for (final shape in shapes) {
      final left = x(shape);
      var scale = 1.0;
      final deleting = shape.deleting;
      if (deleting != null) {
        // DISAPPEAR_DURATION, ValueAnimator's default accelerate-decelerate.
        final t = ((now - deleting) / shrink).clamp(0.0, 1.0);
        scale = 1 - (math.cos((t + 1) * math.pi) / 2 + 0.5);
      }
      if (scale <= 0) continue;
      final rect = Rect.fromCenter(
        center: Offset(left + size / 2, area.height / 2),
        width: size * scale,
        height: size * scale,
      );
      shape.drawable.paint(canvas, rect, now - shape.born, color);
    }
  }

  @override
  bool shouldRepaint(covariant _PinEntryPainter old) => true;
}

// pin_bouncer_delete_filled and pin_bouncer_confirm (AOSP SystemUI
// res-keyguard, Apache-2.0).
const String _deleteFilledSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><path d="'
    'M22.167,21.9L25.531,25.265C25.795,25.502 26.112,25.621 26.481,25.621'
    'C26.851,25.621 27.167,25.502 27.431,25.265C27.669,25.001 27.788,24.684 '
    '27.788,24.315C27.788,23.919 27.669,23.589 27.431,23.325L24.067,20'
    'L27.392,16.675C27.656,16.411 27.788,16.094 27.788,15.725C27.788,15.356 '
    '27.656,15.039 27.392,14.775C27.128,14.511 26.798,14.379 26.402,14.379'
    'C26.033,14.379 25.729,14.511 25.492,14.775L22.167,18.1L18.802,14.735'
    'C18.538,14.498 18.222,14.379 17.852,14.379C17.483,14.379 17.166,14.498 '
    '16.902,14.735C16.665,14.999 16.546,15.329 16.546,15.725C16.546,16.094 '
    '16.665,16.411 16.902,16.675L20.267,20L16.902,23.325C16.665,23.589 '
    '16.546,23.906 16.546,24.275C16.546,24.644 16.665,24.961 16.902,25.225'
    'C17.166,25.489 17.483,25.621 17.852,25.621C18.248,25.621 18.578,25.489 '
    '18.842,25.225L22.167,21.9ZM14.012,32.667C13.59,32.667 13.181,32.574 '
    '12.785,32.39C12.416,32.179 12.099,31.915 11.835,31.598L4.394,21.623'
    'C4.024,21.148 3.84,20.607 3.84,20C3.84,19.393 4.024,18.852 4.394,18.377'
    'L11.835,8.402C12.073,8.085 12.39,7.835 12.785,7.65C13.181,7.439 '
    '13.59,7.333 14.012,7.333H32.142C32.907,7.333 33.554,7.597 34.081,8.125'
    'C34.609,8.653 34.873,9.286 34.873,10.025V29.975C34.873,30.714 '
    '34.609,31.347 34.081,31.875C33.554,32.403 32.907,32.667 32.142,32.667'
    'H14.012Z"/></svg>';

const String _confirmSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><path d="'
    'M6.125,29.413q-0.75,0 -1.275,-0.488a1.76,1.76 0,0 1,-0.487 -1.238'
    'V12.313q0,-0.711 0.487,-1.2 0.525,-0.524 1.275,-0.524 0.712,0 1.2,0.525 '
    '0.525,0.488 0.525,1.2v15.374q0,0.713 -0.525,1.238a1.63,1.63 0,0 1,-1.2 '
    '0.488ZM29,21.725H12.95q-0.75,0 -1.275,-0.488A1.76,1.76 0,0 1,11.187 20'
    'q0,-0.75 0.488,-1.238 0.525,-0.487 1.275,-0.487H29l-4.2,-4.237a1.63,1.63 '
    '0,0 1,-0.488 -1.2q0,-0.713 0.488,-1.238 0.525,-0.487 1.2,-0.487 0.712,0 '
    '1.238,0.487l7.162,7.162q0.262,0.262 0.375,0.6 0.15,0.3 0.15,0.638 '
    '0,0.337 -0.15,0.675 -0.113,0.3 -0.375,0.563L27.238,28.4q-0.525,0.487 '
    '-1.238,0.525 -0.675,0 -1.2,-0.488a1.7,1.7 0,0 1,-0.525 -1.237q0,-0.75 '
    '0.525,-1.275z"/></svg>';
