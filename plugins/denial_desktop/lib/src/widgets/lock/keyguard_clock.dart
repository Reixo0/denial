part of 'lock_screen_layer.dart';

/// Android's lock screen layout on the phone, in dp: SystemUI's default
/// clock (FlexClock) and the keyguard's bottom area. Sizes are SystemUI's
/// resources for this screen (919 dp tall: the values-h800dp clock), and
/// positions were measured on the Android 17 emulator at the phone's size.
/// Every number lives here so lock screen settings can change them later.
class _KeyguardGeometry {
  _KeyguardGeometry(this.screen, {this.clockScale = 1.0})
    : dp = PixelShadeViewport.scaleFor(screen);

  final Size screen;

  /// Logical pixels per Android dp.
  final double dp;

  /// The lock screen settings' clock size.
  final double clockScale;

  /// How far a pull from the lock screen must go to open the shade when
  /// let go (keyguard_drag_down_min_distance).
  static const double dragDownMinDistance = 100;

  /// The status bar's height: Android centres its row 13.85 dp down.
  static const double statusBarHeight = 2 * 13.85;

  /// keyguard_clock_top_margin, small_clock_height, clock_padding_start.
  static const double smallTopMargin = 18;
  static const double smallHeight = 114;
  static const double smallStart = 28;

  /// small_clock_text_size, drawn at 0.98 (SMALL_LAYER_CONFIG).
  static const double smallTextSize = 86 * 0.98;

  /// large_clock_text_size for a screen 800 dp or taller.
  static const double largeTextSize = 200;

  /// clock_vertical_digit_buffer: the gap between the large clock's lines.
  static const double digitBuffer = 8;

  /// Google Sans Flex's tallest and widest digit outlines, in em: the large
  /// clock gives every digit a cell this size, as FlexClockViewGroup does.
  static const double digitHeight = 0.749;
  static const double digitWidth = 0.56;

  /// The height of a digit without overshoot, in em, which is centred in its
  /// cell.
  static const double capHeight = 0.716;

  /// keyguard_status_view_bottom_margin: small clock to the notifications.
  static const double notificationGap = 20;

  /// The date beside the small clock and under the large one, and its box
  /// (date_weather_view_height).
  static const double smallDateGap = 16;
  static const double largeDateGap = 21.5;
  static const double dateHeight = 48;
  static const double dateTextSize = 16;

  /// The large clock sits this far above the screen's middle.
  static const double largeLift = 4.5;

  /// The lock icon's centre and the indication line's centre, up from the
  /// bottom edge, and their sizes (keyguard_indication_text_min_height).
  static const double lockIconFromBottom = 110;
  static const double lockIconSize = 26;
  static const double indicationFromBottom = 56;
  static const double indicationHeight = 48;
  static const double indicationTextSize = 14;

  /// keyguard_indication_text_padding on each side.
  static const double indicationPadding = 16;

  /// keyguard_lock_padding: the notifications end this far above the lock
  /// icon.
  static const double lockPadding = 20;

  double get smallFontSize => smallTextSize * dp;

  Rect get smallBox => Rect.fromLTWH(
    smallStart * dp,
    (statusBarHeight + smallTopMargin) * dp,
    screen.width - 2 * smallStart * dp,
    smallHeight * dp,
  );

  /// Where the notifications start under the small clock.
  double get notificationsTop => smallBox.bottom + notificationGap * dp;

  double get largeFontSize => largeTextSize * dp * clockScale;

  Size get largeCell =>
      Size(digitWidth * largeFontSize, digitHeight * largeFontSize);

  Rect get largeBox {
    final cell = largeCell;
    return Rect.fromCenter(
      center: Offset(screen.width / 2, screen.height / 2 - largeLift * dp),
      width: 2 * cell.width,
      height: 2 * cell.height + digitBuffer * dp * clockScale,
    );
  }

  Rect largeCellAt(int index) {
    final box = largeBox;
    final cell = largeCell;
    final row = index ~/ 2;
    return Rect.fromLTWH(
      box.left + (index % 2) * cell.width,
      box.top + row * (cell.height + digitBuffer * dp * clockScale),
      cell.width,
      cell.height,
    );
  }

  Rect get largeDateBox => Rect.fromLTWH(
    0,
    largeBox.bottom + largeDateGap * dp,
    screen.width,
    dateHeight * dp,
  );
}

/// The clock's font axes: Android's default clock on the lock screen
/// (weight 600, width 100, round), thinning on the always-on display to
/// FlexClockTextView's AOD axes (weight 74 large or 133 small, width 43).
List<FontVariation> _keyguardClockAxes({
  required bool large,
  required double doze,
}) => <FontVariation>[
  FontVariation('wght', ui.lerpDouble(600, large ? 74 : 133, doze)!),
  FontVariation('wdth', ui.lerpDouble(100, 43, doze)!),
  const FontVariation('ROND', 100),
];

TextPainter _keyguardClockText(
  String text, {
  required double fontSize,
  required List<FontVariation> axes,
  required Color color,
  List<FontFeature> features = const <FontFeature>[],
}) => TextPainter(
  text: TextSpan(
    text: text,
    style: TextStyle(
      fontFamily: ShellText.clockFontFamily,
      fontSize: fontSize,
      height: 1,
      letterSpacing: 0,
      fontVariations: axes,
      fontFeatures: features,
      color: color,
    ),
  ),
  textDirection: TextDirection.ltr,
  textScaler: TextScaler.noScaling,
  maxLines: 1,
)..layout();

/// The top of [painter]'s box that centres a digit's height on [centreY].
double _capCentredTop(TextPainter painter, double fontSize, double centreY) =>
    centreY +
    _KeyguardGeometry.capHeight * fontSize / 2 -
    painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);

/// The small clock's time: Android's TIME_FULL_FORMAT, without a day half.
String _smallClockTime(BuildContext context, DateTime now) {
  final (hour, minute) = localizedClockDigits(context, now);
  // Twelve-hour time drops the hour's leading zero; 24-hour time keeps it.
  final shown = localizedTime(context, now).startsWith(hour)
      ? hour
      : int.parse(hour).toString();
  return '$shown:$minute';
}

/// How far the clock has gone from large (0) to small (1), as the large
/// face fades out (ClockFaceOutTransition, 133 ms) before the small one
/// fades in (ClockFaceInTransition, 167 ms after 133 ms).
abstract final class _KeyguardClockSwitch {
  static const Duration duration = Duration(milliseconds: 300);
  static const Curve largeOut = Interval(0.0, 133 / 300);
  static const Curve smallIn = Interval(
    133 / 300,
    1.0,
    curve: Cubic(0.0, 0.0, 0.2, 1.0),
  );
}

/// Which part of the clock a layer draws: the large time goes under the
/// wallpaper's subject (the depth effect), the rest over it.
enum _KeyguardClockLayer { largeTime, overlay }

/// Android's lock screen clock: two lines in the middle, hours over
/// minutes, while no notification shows; one line at the top start with the
/// date beside it once one does.
class _KeyguardClock extends ConsumerWidget {
  const _KeyguardClock({
    required this.layer,
    required this.small,
    required this.doze,
    required this.clockScale,
    this.caption,
  });

  final _KeyguardClockLayer layer;

  /// 0 while the large clock shows, 1 once the small one does.
  final Animation<double> small;

  /// The always-on display's share.
  final Animation<double> doze;

  final double clockScale;

  /// A line under the large clock's date.
  final String? caption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final color = phoneSchemeOf(context).primaryFixed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _KeyguardGeometry(
          constraints.biggest,
          clockScale: clockScale,
        );
        final largeOpacity = small.drive(
          CurveTween(curve: _KeyguardClockSwitch.largeOut),
        );
        final smallOpacity = small.drive(
          CurveTween(curve: _KeyguardClockSwitch.smallIn),
        );
        if (layer == _KeyguardClockLayer.largeTime) {
          final (hour, minute) = localizedClockDigits(context, now);
          return IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                size: geometry.screen,
                painter: _LargeClockPainter(
                  digits: '$hour$minute',
                  geometry: geometry,
                  color: color,
                  doze: doze,
                  hidden: largeOpacity,
                ),
              ),
            ),
          );
        }
        final time = _smallClockTime(context, now);
        // The date's place beside the small clock, from the time's width on
        // the lock screen, so it stays put on the always-on display.
        final timeWidth = _keyguardClockText(
          time,
          fontSize: geometry.smallFontSize,
          axes: _keyguardClockAxes(large: false, doze: 0),
          color: color,
          features: const [FontFeature.proportionalFigures()],
        ).width;
        final date = localizedShortDate(context, now);
        final dateStyle = _keyguardDateStyle(geometry.dp);
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: geometry.screen,
                  painter: _SmallClockPainter(
                    time: time,
                    geometry: geometry,
                    color: color,
                    doze: doze,
                    shown: smallOpacity,
                  ),
                ),
              ),
              Positioned(
                left:
                    geometry.smallBox.left +
                    timeWidth +
                    _KeyguardGeometry.smallDateGap * geometry.dp,
                right: 0,
                top: geometry.smallBox.top,
                height: geometry.smallBox.height,
                child: FadeTransition(
                  opacity: smallOpacity,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      date,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      textScaler: TextScaler.noScaling,
                      style: dateStyle,
                    ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: geometry.largeDateBox,
                child: FadeTransition(
                  opacity: ReverseAnimation(largeOpacity),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        date,
                        maxLines: 1,
                        textScaler: TextScaler.noScaling,
                        style: dateStyle,
                      ),
                      if (caption != null)
                        Text(
                          caption!,
                          maxLines: 1,
                          textScaler: TextScaler.noScaling,
                          style: dateStyle.copyWith(fontSize: 14 * geometry.dp),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The date and the bottom line: white with Android's keyguard text shadow
/// (a soft key shadow and a tight ambient one).
TextStyle _keyguardDateStyle(double dp) => TextStyle(
  fontFamily: ShellText.clockFontFamily,
  fontSize: _KeyguardGeometry.dateTextSize * dp,
  height: 1.2,
  letterSpacing: 0,
  fontVariations: const [FontVariation('wght', 500)],
  color: ShellMediaColors.lightForeground,
  shadows: [
    Shadow(color: const Color(0x33000000), blurRadius: 3 * dp),
    Shadow(color: const Color(0x4D000000), blurRadius: 1 * dp),
  ],
);

/// The large clock's four digits, each centred in a cell as wide and tall
/// as the widest and tallest digit, in two rows 8 dp apart.
class _LargeClockPainter extends CustomPainter {
  _LargeClockPainter({
    required this.digits,
    required this.geometry,
    required this.color,
    required this.doze,
    required this.hidden,
  }) : super(repaint: Listenable.merge([doze, hidden]));

  final String digits;
  final _KeyguardGeometry geometry;
  final Color color;
  final Animation<double> doze;

  /// 0 while shown, 1 once faded out.
  final Animation<double> hidden;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = 1.0 - hidden.value;
    if (alpha <= 0.0 || digits.length != 4) return;
    final fontSize = geometry.largeFontSize;
    final axes = _keyguardClockAxes(large: true, doze: doze.value);
    final paintColor = color.withValues(alpha: color.a * alpha);
    for (var i = 0; i < 4; i++) {
      final cell = geometry.largeCellAt(i);
      final painter = _keyguardClockText(
        digits[i],
        fontSize: fontSize,
        axes: axes,
        color: paintColor,
      );
      painter.paint(
        canvas,
        Offset(
          cell.center.dx - painter.width / 2,
          _capCentredTop(painter, fontSize, cell.center.dy),
        ),
      );
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _LargeClockPainter oldDelegate) =>
      oldDelegate.digits != digits ||
      oldDelegate.color != color ||
      oldDelegate.geometry.screen != geometry.screen ||
      oldDelegate.geometry.clockScale != geometry.clockScale ||
      oldDelegate.doze != doze ||
      oldDelegate.hidden != hidden;
}

/// The small clock's single line, from the start of its box and centred in
/// it, with proportional figures.
class _SmallClockPainter extends CustomPainter {
  _SmallClockPainter({
    required this.time,
    required this.geometry,
    required this.color,
    required this.doze,
    required this.shown,
  }) : super(repaint: Listenable.merge([doze, shown]));

  final String time;
  final _KeyguardGeometry geometry;
  final Color color;
  final Animation<double> doze;
  final Animation<double> shown;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = shown.value;
    if (alpha <= 0.0) return;
    final fontSize = geometry.smallFontSize;
    final painter = _keyguardClockText(
      time,
      fontSize: fontSize,
      axes: _keyguardClockAxes(large: false, doze: doze.value),
      color: color.withValues(alpha: color.a * alpha),
      features: const [FontFeature.proportionalFigures()],
    );
    final box = geometry.smallBox;
    painter.paint(
      canvas,
      Offset(box.left, _capCentredTop(painter, fontSize, box.center.dy)),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant _SmallClockPainter oldDelegate) =>
      oldDelegate.time != time ||
      oldDelegate.color != color ||
      oldDelegate.geometry.screen != geometry.screen ||
      oldDelegate.doze != doze ||
      oldDelegate.shown != shown;
}

/// The keyguard's bottom area: the lock icon, and under it the indication
/// line (the charging state, or "Swipe up to open" for a while after a tap
/// on the face). Both fade as the face is swiped away.
class _KeyguardBottomArea extends ConsumerWidget {
  const _KeyguardBottomArea({
    required this.face,
    required this.fadeDistance,
    required this.hint,
  });

  final ValueListenable<Offset> face;
  final double fadeDistance;

  /// Whether the swipe hint replaces the charging state.
  final ValueListenable<bool> hint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final power = ref.watch(effectivePowerStatusProvider);
    final l10n = context.l10n;
    final capacity = power.capacity;
    final charging = switch (power.state) {
      'charging' when capacity != null =>
        power.fastCharge
            ? l10n.lockIndicationChargingRapidly(capacity)
            : l10n.lockIndicationCharging(capacity),
      'idle' when capacity != null && capacity >= 100 =>
        l10n.lockIndicationCharged,
      _ => null,
    };
    final size = MediaQuery.sizeOf(context);
    final geometry = _KeyguardGeometry(size);
    final dp = geometry.dp;
    final style = _keyguardDateStyle(dp).copyWith(
      fontSize: _KeyguardGeometry.indicationTextSize * dp,
      fontVariations: const [FontVariation('wght', 400)],
    );
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: face,
        builder: (context, child) =>
            Opacity(opacity: 1.0 - _swiped(face, fadeDistance), child: child),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top:
                  size.height -
                  (_KeyguardGeometry.lockIconFromBottom +
                          _KeyguardGeometry.lockIconSize / 2) *
                      dp,
              height: _KeyguardGeometry.lockIconSize * dp,
              child: Center(
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: _KeyguardGeometry.lockIconSize * dp,
                  color: ShellMediaColors.lightForeground,
                  shadows: style.shadows,
                ),
              ),
            ),
            Positioned(
              left: _KeyguardGeometry.indicationPadding * dp,
              right: _KeyguardGeometry.indicationPadding * dp,
              top:
                  size.height -
                  (_KeyguardGeometry.indicationFromBottom +
                          _KeyguardGeometry.indicationHeight / 2) *
                      dp,
              height: _KeyguardGeometry.indicationHeight * dp,
              child: ValueListenableBuilder<bool>(
                valueListenable: hint,
                builder: (context, hinting, _) {
                  final text = hinting ? l10n.lockIndicationSwipeUp : charging;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: text == null
                        ? const SizedBox.shrink()
                        : Center(
                            key: ValueKey<String>(text),
                            child: Text(
                              text,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              textScaler: TextScaler.noScaling,
                              style: style,
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
