part of 'lock_screen_layer.dart';

class _LockBackdrop extends ConsumerStatefulWidget {
  const _LockBackdrop({this.output, this.onPainted});

  final DisplayOutput? output;

  /// Reports the whole backdrop, blur and dim included, after it or the
  /// wallpaper inside it repaints.
  final ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  ConsumerState<_LockBackdrop> createState() => _LockBackdropState();
}

class _LockBackdropState extends ConsumerState<_LockBackdrop> {
  final _boundary = GlobalKey();

  /// The wallpaper repaints within its own boundary, which leaves this one's
  /// paint untouched.
  void _wallpaperPainted(RenderRepaintBoundary _) {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is RenderRepaintBoundary) widget.onPainted?.call(boundary);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      shellSettingsProvider.select((value) => value.lockScreen),
    );
    final output = widget.output;
    final onPainted = widget.onPainted;
    return _PaintedBoundary(
      key: _boundary,
      onPainted: onPainted,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _LockFillPainter(color: context.shellColors.background),
          ),
          if (settings.useSystemWallpaper)
            ClipRect(
              child: ImageFiltered(
                key: ValueKey<String>(
                  output == null
                      ? 'lock-wallpaper-blur'
                      : 'lock-wallpaper-blur-${output.monitorId}',
                ),
                imageFilter: ImageFilter.blur(
                  sigmaX: settings.blurRadius * context.shellTheme.blurStrength,
                  sigmaY: settings.blurRadius * context.shellTheme.blurStrength,
                  // The lock wallpaper fills the output. Clamping keeps the
                  // blur kernel from sampling transparent pixels beyond that
                  // boundary and exposing a bright halo around the display.
                  tileMode: TileMode.clamp,
                ),
                child: output == null
                    ? ShellWallpaper(
                        lock: true,
                        onPainted: onPainted == null ? null : _wallpaperPainted,
                      )
                    : ShellOutputWallpaper(output: output, lock: true),
              ),
            ),
          CustomPaint(
            painter: _LockFillPainter(
              color: ShellMediaColors.darkness.withValues(
                alpha: settings.dimAmount,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaintedBoundary extends SingleChildRenderObjectWidget {
  const _PaintedBoundary({super.key, this.onPainted, super.child});

  final ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintedBoundary()..onPainted = onPainted;

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPaintedBoundary).onPainted = onPainted;
  }
}

class _RenderPaintedBoundary extends RenderRepaintBoundary {
  ValueChanged<RenderRepaintBoundary>? onPainted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPainted?.call(this);
  }
}

/// Uses round-rect geometry with an imperceptible radius so the backdrop obeys
/// lock-stage transforms without entering Impeller's UberSDF rect path.
class _LockFillPainter extends CustomPainter {
  const _LockFillPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(0.01)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _LockFillPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _LockStatusIcons extends StatelessWidget {
  const _LockStatusIcons({
    required this.power,
    required this.cpu,
    required this.gpus,
    required this.desktop,
  });

  final ShellPowerStatus power;
  final LoadSeries cpu;
  final List<GpuLoad> gpus;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    if (desktop) {
      return Positioned(
        top: math.max(24.0, topPadding + 18.0),
        right: 34,
        child: _DesktopLockStatusBar(cpu: cpu, gpus: gpus),
      );
    }
    // The operator sits opposite the icons, as far in from the left edge as
    // the battery is from the right.
    return Positioned(
      top: math.max(22.0, topPadding + 18.0),
      left: 28,
      right: 28,
      child: Opacity(
        opacity: 0.92,
        child: Row(
          children: [
            const Expanded(child: _LockOperatorName()),
            const SizedBox(width: 16),
            StatusIconCluster(battery: power.batteryStatus),
          ],
        ),
      ),
    );
  }
}

class _LockOperatorName extends ConsumerWidget {
  const _LockOperatorName();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(
      mobileNetworkProvider.select(
        (discovery) => discovery.isLoading || discovery.hasError
            ? ''
            : discovery.value?.operatorName ?? '',
      ),
    );
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: ShellText.base.copyWith(
        color: context.shellColors.textPrimary,
        fontSize: 15,
        height: 1,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    );
  }
}

class _DesktopLockStatusBar extends StatelessWidget {
  const _DesktopLockStatusBar({required this.cpu, required this.gpus});

  final LoadSeries cpu;
  final List<GpuLoad> gpus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.lockPerformanceStatusLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.shellTheme.panelColor(
            context.shellColors.panelBackground,
          ),
          borderRadius: context.shellTheme.borderRadius(16),
          border: Border.all(color: context.shellColors.hairlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DesktopPerformanceMetric(
                icon: Icons.memory_rounded,
                label: l10n.lockCpuLabel,
                series: cpu,
              ),
              for (final gpu in gpus) ...[
                const SizedBox(width: 8),
                _DesktopPerformanceMetric(
                  icon: Icons.developer_board_rounded,
                  label: gpu.label,
                  series: gpu.series,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopPerformanceMetric extends StatelessWidget {
  const _DesktopPerformanceMetric({
    required this.icon,
    required this.label,
    required this.series,
  });

  final IconData icon;
  final String label;
  final LoadSeries series;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final usage = series.current;
    final value = usage == null
        ? l10n.lockMetricUnavailable
        : l10n.settingsPercent((usage * 100).round());
    final temperature = series.temperatureC;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.shellColors.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: context.shellTheme.borderRadius(11),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: context.shellColors.textTertiary),
            const SizedBox(width: 7),
            Text(
              l10n.lockPerformanceMetric(label, value),
              style: ShellText.cardTitle.copyWith(fontSize: 11),
            ),
            if (temperature != null) ...[
              const SizedBox(width: 7),
              Text(
                l10n.lockTemperature(temperature.round()),
                style: ShellText.base.copyWith(
                  color: context.shellColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The desktop lock screen's clock, date and status, left of the middle.
/// The phone draws Android's clock instead (_KeyguardClock).
class _LockClockBlock extends StatelessWidget {
  const _LockClockBlock({
    required this.clock,
    required this.scale,
    required this.showSystemStatus,
  });

  final HomeClockInfo clock;
  final double scale;
  final bool showSystemStatus;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Positioned(
      left: math.max(48.0, size.width * 0.065),
      right: size.width * 0.48,
      top: math.max(72.0, size.height * 0.22),
      height: math.min(280.0, size.height * 0.36),
      child: Transform.scale(
        alignment: Alignment.center,
        scale: scale,
        child: RepaintBoundary(
          child: HomeClockWidget(
            clock: clock,
            showStatus: showSystemStatus,
            dateColor: ShellMediaColors.lightForegroundSecondary,
          ),
        ),
      ),
    );
  }
}

/// The swipe-up pill of the mobile face: wider than the navigation pill and
/// centred where it sits. Like the fingerprint ring it stays put and fades
/// out as the face is swiped away.
class _LockSwipePill extends StatelessWidget {
  const _LockSwipePill({required this.face, required this.fadeDistance});

  final ValueListenable<Offset> face;
  final double fadeDistance;

  @override
  Widget build(BuildContext context) {
    // BottomGestureHandle centres the navigation pill below the top 20 px of
    // its hit area.
    return Positioned(
      left: 0,
      right: 0,
      bottom: ReferenceShellMetrics.gestureBottomInset,
      height: ReferenceShellMetrics.gestureHitHeight,
      child: Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Center(
          child: IgnorePointer(
            child: CustomPaint(
              size: const Size(180, 5),
              painter: _LockSwipePillPainter(
                face: face,
                fadeDistance: fadeDistance,
                color: context.shellColors.gesturePill,
                radius: context.shellTheme.borderRadius(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockSwipePillPainter extends CustomPainter {
  _LockSwipePillPainter({
    required this.face,
    required this.fadeDistance,
    required this.color,
    required this.radius,
  }) : super(repaint: face);

  final ValueListenable<Offset> face;
  final double fadeDistance;
  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = 1.0 - _swiped(face, fadeDistance);
    if (alpha <= 0.0) {
      return;
    }
    canvas.drawRRect(
      radius.toRRect(Offset.zero & size),
      Paint()
        ..isAntiAlias = true
        ..color = color.withValues(alpha: color.a * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _LockSwipePillPainter oldDelegate) =>
      oldDelegate.face != face ||
      oldDelegate.fadeDistance != fadeDistance ||
      oldDelegate.color != color ||
      oldDelegate.radius != radius;
}

/// How far the face has been swiped toward gone for marks that stay put:
/// 0 at rest, 1 once it has moved [fadeDistance] up.
double _swiped(ValueListenable<Offset> face, double fadeDistance) =>
    fadeDistance > 0.0 ? (-face.value.dy / fadeDistance).clamp(0.0, 1.0) : 0.0;

/// Marks the fingerprint sensor: on an under-display sensor the ring sits on
/// the sensor, otherwise near the bottom edge. It stays on the sensor and
/// fades out as the face is swiped away. Red while the reader is not
/// listening, after a rejected scan or while it re-arms, so the user waits
/// for white.
class _LockFingerprintRing extends StatefulWidget {
  const _LockFingerprintRing({
    required this.present,
    required this.ready,
    required this.scanning,
    required this.sensor,
    required this.face,
    required this.fadeDistance,
  });

  final bool present;
  final bool ready;
  final bool scanning;

  /// Panel fractions in the panel's native orientation.
  final Rect? sensor;

  /// The face's offset; the ring is gone once it has moved [fadeDistance] up.
  final ValueListenable<Offset> face;
  final double fadeDistance;

  @override
  State<_LockFingerprintRing> createState() => _LockFingerprintRingState();
}

class _LockFingerprintRingState extends State<_LockFingerprintRing>
    with TickerProviderStateMixin {
  late final AnimationController _present = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: widget.present ? 1.0 : 0.0,
  );

  /// 1 white, 0 red: it turns red at once and back to white gently.
  late final AnimationController _ready = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 90),
    value: widget.ready ? 1.0 : 0.0,
  );

  late final AnimationController _scanning = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 220),
    value: widget.scanning ? 1.0 : 0.0,
  );

  @override
  void didUpdateWidget(covariant _LockFingerprintRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    final still = MediaQuery.disableAnimationsOf(context);
    if (oldWidget.present != widget.present) {
      if (still) {
        _present.value = widget.present ? 1.0 : 0.0;
      } else if (widget.present) {
        _present.forward();
      } else {
        _present.reverse();
      }
    }
    if (oldWidget.scanning != widget.scanning) {
      if (still) {
        _scanning.value = widget.scanning ? 1.0 : 0.0;
      } else if (widget.scanning) {
        _scanning.forward();
      } else {
        _scanning.reverse();
      }
    }
    if (oldWidget.ready != widget.ready) {
      if (still) {
        _ready.value = widget.ready ? 1.0 : 0.0;
      } else if (widget.ready) {
        _ready.forward();
      } else {
        _ready.reverse();
      }
    }
  }

  @override
  void dispose() {
    _present.dispose();
    _ready.dispose();
    _scanning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _LockFingerprintRingPainter(
          present: _present,
          ready: _ready,
          scanning: _scanning,
          face: widget.face,
          fadeDistance: widget.fadeDistance,
          sensor: widget.sensor,
        ),
      ),
    );
  }
}

class _LockFingerprintRingPainter extends CustomPainter {
  _LockFingerprintRingPainter({
    required this.present,
    required this.ready,
    required this.scanning,
    required this.face,
    required this.fadeDistance,
    required this.sensor,
  }) : super(repaint: Listenable.merge([present, ready, scanning, face]));

  final Animation<double> present;
  final Animation<double> ready;
  final Animation<double> scanning;
  final ValueListenable<Offset> face;
  final double fadeDistance;
  final Rect? sensor;

  static const double _radius = 13.0;
  static const double _stroke = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = present.value * (1.0 - _swiped(face, fadeDistance));
    if (alpha <= 0.0) {
      return;
    }
    final sensor = this.sensor;
    // Sensor fractions follow the panel's native portrait orientation; a
    // landscape lock screen falls back to the bottom edge.
    final center = sensor != null && size.height >= size.width
        ? Offset(sensor.center.dx * size.width, sensor.center.dy * size.height)
        : Offset(size.width / 2, size.height * 0.88);
    final ink = Color.lerp(
      ShellTelemetryColors.danger,
      ShellMediaColors.lightForeground,
      ready.value,
    )!;
    canvas.drawCircle(
      center,
      _radius * (1.0 + 0.35 * scanning.value),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = ink.withValues(alpha: 0.92 * alpha),
    );
  }

  @override
  bool shouldRepaint(covariant _LockFingerprintRingPainter oldDelegate) =>
      oldDelegate.present != present ||
      oldDelegate.ready != ready ||
      oldDelegate.scanning != scanning ||
      oldDelegate.face != face ||
      oldDelegate.fadeDistance != fadeDistance ||
      oldDelegate.sensor != sensor;
}

/// Depth effect: the subject cut out of the lock wallpaper, drawn over the
/// clock so the clock sits behind it. The mask comes from the optional
/// `wallpaper-depth` program ([wallpaperDepthProvider]):
/// `lock-mask.png` (alpha marks the subject, in wallpaper space) with a
/// sidecar naming the wallpaper it belongs to. This layer is the backdrop
/// again, kept where the mask is, with the mask blurred like the backdrop:
/// away from the clock it matches the backdrop under it exactly.
class _LockDepthForeground extends ConsumerStatefulWidget {
  const _LockDepthForeground({this.spread = 0.0});

  /// Blur beyond the backdrop's, in logical pixels: a spread mask lights
  /// the scene around the subject instead of cutting the subject out.
  final double spread;

  @override
  ConsumerState<_LockDepthForeground> createState() =>
      _LockDepthForegroundState();
}

class _LockDepthForegroundState extends ConsumerState<_LockDepthForeground> {
  String? _wallpaper;
  int? _masks;
  ui.Image? _source;
  ui.Image? _mask;
  (double, Size)? _maskKey;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _source?.dispose();
    _mask?.dispose();
    super.dispose();
  }

  void _forget() {
    _generation++;
    _source?.dispose();
    _mask?.dispose();
    _source = null;
    _mask = null;
    _maskKey = null;
  }

  Future<void> _load(String wallpaper) async {
    final generation = _generation;
    ui.Image? image;
    try {
      final directory = wallpaperDepthDirectory(ref.read(runtimePathsProvider));
      final sidecar = jsonDecode(
        await File('$directory/lock-mask.json').readAsString(),
      );
      if (sidecar is Map && sidecar['wallpaper'] == wallpaper) {
        final codec = await ui.instantiateImageCodec(
          await File('$directory/lock-mask.png').readAsBytes(),
        );
        image = (await codec.getNextFrame()).image;
        codec.dispose();
      }
    } on Object {
      image = null;
    }
    if (!mounted || generation != _generation) {
      image?.dispose();
      return;
    }
    setState(() => _source = image);
  }

  /// Blurs the mask once with the backdrop's blur, in mask pixels.
  Future<void> _bake(ui.Image source, double sigma, Size size) async {
    final key = (sigma, size);
    _maskKey = key;
    final generation = _generation;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      source,
      Offset.zero,
      Paint()
        ..imageFilter = ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    final picture = recorder.endRecording();
    final result = await picture.toImage(source.width, source.height);
    picture.dispose();
    if (!mounted || generation != _generation || _maskKey != key) {
      result.dispose();
      return;
    }
    setState(() {
      _mask?.dispose();
      _mask = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(
      shellSettingsProvider.select((value) => value.lockScreen),
    );
    final outputName = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context))
          .select((layout) => layout?.mainOutput?.name),
    );
    final assignment = ref.watch(
      wallpaperControllerProvider.select((state) => state.assignment.forLock()),
    );
    final resource = outputName == null
        ? assignment.all
        : assignment.forOutput(outputName);
    final alignment = outputName == null
        ? assignment.spanAlignment
        : assignment.alignmentForOutput(outputName);
    final wallpaper =
        settings.useSystemWallpaper &&
            resource.kind == WallpaperResourceKind.file
        ? resource.path
        : null;
    // A new mask may be for this wallpaper: read the cache again.
    final masks = ref.watch(wallpaperDepthProvider);
    if (wallpaper != _wallpaper || masks != _masks) {
      _wallpaper = wallpaper;
      _masks = masks;
      _forget();
      if (wallpaper != null) {
        _load(wallpaper);
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final source = _source;
        final size = constraints.biggest;
        if (source == null || size.isEmpty) {
          return const SizedBox.shrink();
        }
        // Covered, then zoomed about the alignment's point, as the
        // wallpaper is drawn.
        final cover =
            math.max(size.width / source.width, size.height / source.height) *
            (outputName == null
                ? assignment.zoom
                : assignment.zoomForOutput(outputName));
        final sigma =
            (settings.blurRadius * context.shellTheme.blurStrength +
                widget.spread) /
            cover;
        if (sigma > 0.0 && _maskKey != (sigma, size)) {
          _bake(source, sigma, size);
        }
        final mask = sigma > 0.0 ? _mask : source;
        if (mask == null) {
          return const SizedBox.shrink();
        }
        final matrix = Matrix4.diagonal3Values(cover, cover, 1.0)
          ..setTranslationRaw(
            (size.width - source.width * cover) * (alignment.x + 1) / 2,
            (size.height - source.height * cover) * (alignment.y + 1) / 2,
            0.0,
          );
        return IgnorePointer(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (_) => ImageShader(
              mask,
              TileMode.clamp,
              TileMode.clamp,
              matrix.storage,
              filterQuality: FilterQuality.medium,
            ),
            child: const _LockBackdrop(),
          ),
        );
      },
    );
  }
}

/// The phone's notifications under the small clock, unless the lock screen
/// settings hide them. Android's compact lock screen
/// (LockScreenMinimalismCoordinator, on by default): the top ongoing and
/// the newest unseen notification keep their rows (the shade's template,
/// collapsed and opaque); everything else, and any row that does not fit
/// above the lock icon, waits as an icon on the shelf. They slide with the
/// face and let drags through to the swipe; a tap asks for the PIN, then
/// opens.
class _LockNotifications extends ConsumerWidget {
  const _LockNotifications({required this.onOpen});

  /// The tapped group's key.
  final ValueChanged<String> onOpen;

  /// LOCK_SCREEN_NOTIFICATION_MINIMALISM's default; a lock screen setting
  /// later.
  static const bool compact = true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(desktopNotificationsProvider);
    if (state.lockPreview == NotificationPreviewMode.hidden ||
        state.groups.isEmpty) {
      LockShadeHandover.lockTop = null;
      LockShadeHandover.kept = const <String>{};
      return const SizedBox.shrink();
    }
    final groups = state.groups;
    return ValueListenableBuilder<bool>(
      valueListenable: LockShadeHandover.covering,
      builder: (context, covering, _) =>
          _build(context, groups, state.lockPreview, covering),
    );
  }

  /// The groups that had rows when the shade came over the lock screen.
  static List<String>? _frozen;

  Widget _build(
    BuildContext context,
    List<DesktopNotificationGroup> groups,
    NotificationPreviewMode preview,
    bool covering,
  ) {
    var rows = _rows(groups);
    if (covering) {
      // The lock screen's stack is the shade's while it is open: it does
      // not refilter what was seen until it is back (filtering is off while
      // the shade is open).
      final frozen = _frozen ??= [for (final group in rows) group.key];
      rows = [
        for (final group in groups)
          if (frozen.contains(group.key)) group,
      ];
    } else {
      _frozen = null;
    }
    final geometry = _KeyguardGeometry(MediaQuery.sizeOf(context));
    final dp = geometry.dp;
    // The stack ends keyguard_lock_padding above the lock icon.
    final bottom =
        (_KeyguardGeometry.lockIconFromBottom +
            _KeyguardGeometry.lockIconSize / 2 +
            _KeyguardGeometry.lockPadding) *
        dp;
    return Positioned(
      left: 0,
      right: 0,
      top: geometry.notificationsTop,
      bottom: bottom,
      // The shade draws these cards while it is over the lock screen, from
      // this place; they come back as it leaves (keyguard alpha), or at
      // once when the shade sprang back with them still here.
      child: AnimatedOpacity(
        opacity: covering ? 0 : 1,
        duration: covering || LockShadeHandover.returned
            ? Duration.zero
            : const Duration(milliseconds: 200),
        child: PixelShadeViewport(
          child: _LockNotificationStack(
            groups: groups,
            rows: rows,
            preview: preview,
            onOpen: onOpen,
          ),
        ),
      ),
    );
  }

  List<DesktopNotificationGroup> _rows(List<DesktopNotificationGroup> groups) {
    final List<DesktopNotificationGroup> rows;
    if (compact) {
      // LockScreenMinimalismCoordinator: of the alerting notifications
      // (importance DEFAULT and up), the top rich ongoing one (a call; the
      // colourised and promoted kinds don't reach Denial) and the top one
      // not seen yet keep a row.
      bool alerting(DesktopNotificationRecord record) =>
          record.notification.urgency != DesktopNotificationUrgency.low;
      bool richOngoing(DesktopNotificationRecord record) =>
          !record.notification.clearable &&
          (record.notification.category.startsWith('call') ||
              record.notification.urgency ==
                  DesktopNotificationUrgency.critical);
      final ongoing = groups
          .where(
            (group) => group.members.any(
              (record) => alerting(record) && richOngoing(record),
            ),
          )
          .firstOrNull;
      final unseen = groups
          .where(
            (group) =>
                !identical(group, ongoing) &&
                group.members.any(
                  (record) =>
                      record.unread && alerting(record) && !richOngoing(record),
                ),
          )
          .firstOrNull;
      rows = [
        for (final group in groups)
          if (identical(group, ongoing) || identical(group, unseen)) group,
      ];
    } else {
      rows = groups;
    }
    return rows;
  }
}

/// The stack itself, in dp. Rows differ in height, so it lays out all of
/// them, then drops rows from the end until they and the shelf fit; it
/// stays hidden until it has, and starts over when the notifications or
/// its room change.
class _LockNotificationStack extends ConsumerStatefulWidget {
  const _LockNotificationStack({
    required this.groups,
    required this.rows,
    required this.preview,
    required this.onOpen,
  });

  /// Every group, in the shade's order.
  final List<DesktopNotificationGroup> groups;

  /// The groups that may show as rows, in the same order.
  final List<DesktopNotificationGroup> rows;
  final NotificationPreviewMode preview;
  final ValueChanged<String> onOpen;

  @override
  ConsumerState<_LockNotificationStack> createState() =>
      _LockNotificationStackState();
}

class _LockNotificationStackState
    extends ConsumerState<_LockNotificationStack> {
  final GlobalKey _column = GlobalKey();
  List<String> _keys = const <String>[];
  double _room = -1;
  int _fit = 0;
  bool _settled = false;

  /// Tells the shade where this stack is and which cards it shows, for
  /// opening over it (LockShadeHandover).
  void _publish(List<DesktopNotificationGroup> shown) {
    if (!mounted) return;
    final box = _column.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    LockShadeHandover.locked = true;
    LockShadeHandover.lockTop = box.localToGlobal(Offset.zero).dy;
    LockShadeHandover.kept = {for (final group in shown) group.key};
  }

  @override
  void dispose() {
    LockShadeHandover.locked = false;
    LockShadeHandover.lockTop = null;
    LockShadeHandover.kept = const <String>{};
    super.dispose();
  }

  void _measure() {
    if (!mounted || _settled) return;
    final box = _column.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    setState(() {
      if (box.size.height > _room + 0.5 && _fit > 0) {
        _fit--;
      } else {
        _settled = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final notifications = ref.read(desktopNotificationsProvider.notifier);
    final rows = widget.rows;
    return LayoutBuilder(
      builder: (context, constraints) {
        final keys = [
          for (final group in rows) group.key,
          '|',
          for (final group in widget.groups) group.key,
        ];
        if (!listEquals(keys, _keys) || constraints.maxHeight != _room) {
          _keys = keys;
          _room = constraints.maxHeight;
          _fit = rows.length;
          _settled = false;
        }
        if (!_settled) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        }
        final fit = math.min(_fit, rows.length);
        final shown = rows.take(fit).toSet();
        if (_settled) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _publish(shown.toList()),
          );
        }
        final shelf = [
          for (final group in widget.groups)
            if (!shown.contains(group)) group,
        ];
        final column = Column(
          key: _column,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < fit; i++)
              Padding(
                key: ValueKey(rows[i].key),
                padding: EdgeInsets.fromLTRB(
                  PixelNotificationMetrics.margin,
                  i == 0 ? 0 : PixelNotificationMetrics.divider,
                  PixelNotificationMetrics.margin,
                  0,
                ),
                child: _row(
                  rows[i],
                  notifications,
                  roundTop: i == 0,
                  roundBottom: i == fit - 1,
                ),
              ),
            if (shelf.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                  top: fit == 0 ? 0 : PixelNotificationMetrics.divider,
                ),
                child: _LockNotificationShelf(groups: shelf),
              ),
          ],
        );
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Opacity(opacity: _settled ? 1 : 0, child: column),
          ),
        );
      },
    );
  }

  Widget _row(
    DesktopNotificationGroup group,
    DesktopNotificationsController notifications, {
    required bool roundTop,
    required bool roundBottom,
  }) {
    // Swiped aside, it leaves the history; a swipe up still opens the
    // phone.
    return Dismissible(
      key: ValueKey(group.key),
      direction: group.clearable
          ? DismissDirection.horizontal
          : DismissDirection.none,
      confirmDismiss: (_) async {
        // The controller drops the rows when it can.
        notifications.dismissGroupFromHistory(group.key);
        return false;
      },
      child: Listener(
        // A pull that starts here opens this card in the shade.
        onPointerDown: (_) => LockShadeHandover.pressed = group.stacked
            ? group.key
            : lockPullKey(group.newest.notification),
        onPointerUp: (_) => LockShadeHandover.pressed = null,
        onPointerCancel: (_) => LockShadeHandover.pressed = null,
        child: _LockNotificationPress(
          onTap: () {
            ref.read(hapticsServiceProvider).pulse();
            widget.onOpen(group.key);
          },
          child: PixelNotificationCard(
            notification: group.newest.notification,
            group: group,
            interactive: false,
            opaque: true,
            groupLines: 2,
            previewMode: widget.preview,
            roundTop: roundTop,
            roundBottom: roundBottom,
          ),
        ),
      ),
    );
  }
}

/// NotificationShelf on the compact lock screen: a pill at the start, on
/// the rows' opaque colour, holding the icons of what has no row
/// (notification_shelf_height 48 dp, shelf_icon_container_padding 13 dp,
/// the status bar's 22 dp icon slots; measured on the emulator).
class _LockNotificationShelf extends StatelessWidget {
  const _LockNotificationShelf({required this.groups});

  final List<DesktopNotificationGroup> groups;

  static const double height = 48;
  static const double padding = 13;
  static const double slot = 22;
  static const double glyph = 16;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final room =
            constraints.maxWidth -
            2 * PixelNotificationMetrics.margin -
            2 * padding;
        final fits = math.max(1, (room / slot).floor());
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              start: PixelNotificationMetrics.margin,
            ),
            child: Container(
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: padding),
              decoration: ShapeDecoration(
                color: scheme.surfaceContainer,
                shape: const StadiumBorder(),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final group in groups.take(fits))
                    SizedBox.square(
                      dimension: slot,
                      child: Center(
                        child: SizedBox.square(
                          dimension: glyph,
                          child: _shelfIcon(
                            group.newest.notification,
                            scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _shelfIcon(DesktopNotification notification, Color color) =>
      switch (notification.smallIcon) {
        final small? => NotificationSmallIcon(image: small, color: color),
        null => ClipOval(
          child: NotificationAppIcon(notification: notification),
        ),
      };
}

/// The card gives under the finger and springs back as the face leaves for
/// the PIN.
class _LockNotificationPress extends StatefulWidget {
  const _LockNotificationPress({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_LockNotificationPress> createState() => _LockNotificationPressState();
}

class _LockNotificationPressState extends State<_LockNotificationPress>
    with SingleTickerProviderStateMixin {
  static const double _pressedScale = 0.95;

  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: const Duration(milliseconds: 380),
  );

  // The release overshoots a little past full size before settling.
  late final Animation<double> _scale = CurvedAnimation(
    parent: _press,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeInBack,
  ).drive(Tween<double>(begin: 1.0, end: _pressedScale));

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _release() => _press.reverse();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      onTap: widget.onTap,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          _LiftTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<_LiftTapGestureRecognizer>(
                _LiftTapGestureRecognizer.new,
                (recognizer) => recognizer
                  ..onTapDown = ((_) => _press.forward())
                  ..onTapCancel = _release
                  ..onTap = () {
                    // A quick tap still shows the press before the release.
                    _press.forward().whenCompleteOrCancel(_release);
                    widget.onTap();
                  },
              ),
        },
        child: ScaleTransition(scale: _scale, child: widget.child),
      ),
    );
  }
}

/// Takes the tap as the finger lifts instead of waiting out the face's
/// double tap, so the PIN comes up at once.
class _LiftTapGestureRecognizer extends TapGestureRecognizer {
  @override
  void handlePrimaryPointer(PointerEvent event) {
    super.handlePrimaryPointer(event);
    if (event is PointerUpEvent) resolve(GestureDisposition.accepted);
  }
}
