import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart'
    show appLauncherProvider, desktopAppsRepositoryProvider;
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;

import '../../launcher/widgets/launcher_icon.dart';
import '../../state/reference_shell_controller.dart';
import '../../state/reference_shell_metrics.dart';
import 'quick_settings_panel.dart' show PixelShadeViewport;

/// Something in the shade an app opens out of (Android's
/// `ActivityTransitionAnimator.Controller.fromView`): a press on it marks it,
/// and the launch that press starts grows out of it.
class LaunchSource extends StatefulWidget {
  const LaunchSource({
    required this.color,
    required this.radius,
    required this.child,
    this.scales = true,
    super.key,
  });

  /// Its background, which grows with the launch.
  final Color color;

  /// Its corners, in its own coordinates.
  final BorderRadius radius;

  /// Its content scales with the growing bounds, as Android's ghosted view
  /// does; a notification's keeps its size while the row grows around it.
  final bool scales;

  final Widget child;

  @override
  State<LaunchSource> createState() => _LaunchSourceState();
}

class _LaunchSourceState extends State<LaunchSource> {
  final _boundary = GlobalKey();

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => LaunchSources._pressed(this, event),
    child: RepaintBoundary(key: _boundary, child: widget.child),
  );

  ShadeLaunchOrigin? _capture() {
    final box = _boundary.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.attached || !box.hasSize) {
      return null;
    }
    final size = box.size;
    if (size.isEmpty) return null;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & size,
    );
    // The shade draws at Android's size and is scaled to the screen.
    final scale = rect.width / size.width;
    final radius = widget.radius.resolve(Directionality.maybeOf(context));
    ui.Image? image;
    try {
      image = box.toImageSync(
        pixelRatio: View.of(context).devicePixelRatio * scale,
      );
    } catch (_) {
      // Not painted yet: the background grows alone.
    }
    return ShadeLaunchOrigin(
      rect: rect,
      topRadius: radius.topLeft.x * scale,
      bottomRadius: radius.bottomLeft.x * scale,
      color: widget.color,
      scales: widget.scales,
      image: image,
    );
  }
}

/// Which [LaunchSource] the press that starts a launch landed on.
abstract final class LaunchSources {
  static _LaunchSourceState? _last;
  static Duration? _lastAt;
  static int? _lastPointer;
  static Duration? _latestDown;
  static _LaunchSourceState? _resumed;
  static bool _routed = false;

  static void _route() {
    if (_routed) return;
    _routed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
      if (event is PointerDownEvent) _latestDown = event.timeStamp;
    });
  }

  static void _pressed(_LaunchSourceState source, PointerDownEvent event) {
    _route();
    // The innermost source hears the press first.
    if (_lastAt == event.timeStamp && _lastPointer == event.pointer) return;
    _last = source;
    _lastAt = event.timeStamp;
    _lastPointer = event.pointer;
  }

  /// The source the latest press landed on, if it landed on one.
  static _LaunchSourceState? _pressedNow() {
    _route();
    final source = _last;
    if (source == null || !source.mounted || _lastAt != _latestDown) {
      return null;
    }
    return source;
  }

  /// Keeps the source of the press for an action that waits for the unlock.
  static Object? keep() => _pressedNow();

  /// The action that waited for the unlock goes ahead from what [keep]
  /// kept.
  static void resume(Object? kept) =>
      _resumed = kept is _LaunchSourceState ? kept : null;

  /// Where the launch the current press starts grows from, measured now;
  /// null when the press was not on a [LaunchSource].
  static ShadeLaunchOrigin? take() {
    final source = _resumed ?? _pressedNow();
    _resumed = null;
    _last = null;
    if (source == null || !source.mounted) return null;
    return source._capture();
  }
}

/// The view a launch grows out of, in global coordinates.
class ShadeLaunchOrigin {
  ShadeLaunchOrigin({
    required this.rect,
    required this.topRadius,
    required this.bottomRadius,
    required this.color,
    required this.scales,
    this.image,
  });

  final Rect rect;
  final double topRadius;
  final double bottomRadius;
  final Color color;
  final bool scales;

  /// What the view showed: Android's ghost of it.
  final ui.Image? image;
}

final shadeLaunchProvider = Provider<ShadeLaunch>((ref) {
  final launch = ShadeLaunch();
  ref.onDispose(launch.dispose);
  return launch;
});

/// A launch out of the shade, between whoever starts it and the layer that
/// draws it. The shade stays on screen under the launch until the app
/// covers it, then goes at once (`ShadeController.instantCollapseShade`
/// after the launch, as on Android); a launch that does not happen leaves
/// it to close as it would.
class ShadeLaunch extends ChangeNotifier {
  ({int requestId, ShadeLaunchOrigin origin, String? iconPath})? _start;
  bool _holding = false;
  bool _covered = false;

  /// The shade stays where it is.
  bool get holding => _holding;

  /// The last launch ended with its app covering the screen. Read once.
  bool takeCovered() {
    final covered = _covered;
    _covered = false;
    return covered;
  }

  void _begin(int requestId, ShadeLaunchOrigin origin, String? iconPath) {
    _start?.origin.image?.dispose();
    _start = (requestId: requestId, origin: origin, iconPath: iconPath);
    _holding = true;
    notifyListeners();
  }

  ({int requestId, ShadeLaunchOrigin origin, String? iconPath})? _takeStart() {
    final start = _start;
    _start = null;
    return start;
  }

  void _release({required bool covered}) {
    if (!_holding) return;
    _holding = false;
    _covered = covered;
    notifyListeners();
  }
}

/// Opens an app out of the view in the shade the current press landed on,
/// [origin] (from [LaunchSources.take], taken before anything is awaited;
/// [launch] is [shadeLaunchProvider]'s),
/// as Android's launch from a view does. [running] is the app's window when
/// it is already open; [start] starts the app, or makes it come, with the
/// launch's request id and says whether it did. Without an origin, or when
/// no launch can start, the shade closes and [start] runs alone.
Future<void> launchFromShade(
  ReferenceShellController shell,
  ShadeLaunch launch, {
  required ShadeLaunchOrigin? origin,
  required String appName,
  required String? iconPath,
  required Iterable<String> appIds,
  required DenialWindow? running,
  required FutureOr<bool> Function(int? requestId) start,
}) async {
  int? requestId;
  if (origin != null) {
    final radius = (top: origin.topRadius, bottom: origin.bottomRadius);
    requestId = running != null
        ? shell.activateAppFromLauncher(
            window: running,
            appName: appName,
            iconPath: iconPath,
            sourceRect: origin.rect,
            sourceRadius: radius,
          )
        : shell.beginAppLaunch(
            appName: appName,
            iconPath: iconPath,
            expectedAppIds: appIds,
            sourceRect: origin.rect,
            sourceRadius: radius,
          );
  }
  if (requestId == null) {
    origin?.image?.dispose();
    if (await start(null)) shell.closeQuickSettings();
    return;
  }
  launch._begin(requestId, origin!, iconPath);
  if (!await start(requestId)) shell.failAppLaunch(requestId);
}

/// Draws a launch out of the shade, above the shade (Android's
/// TransitionAnimator from a view, for a tap: no spring): over 500 ms the
/// view's background grows to the screen, top, bottom and width on
/// EMPHASIZED and the centre's x on EMPHASIZED_COMPLEMENT, its corners
/// turning into the window's, with the view's content scaled inside. The
/// window's colour fades in over it in the first 150 ms (LINEAR_OUT_SLOW_IN)
/// and out over the app's window in the next 183 ms (0, 0, 0.6, 1). An app
/// that has no window yet shows its splash (its icon on the window's colour)
/// until it has one. Once the app covers the screen it is handed over and
/// the shade goes.
class ShadeLaunchLayer extends ConsumerStatefulWidget {
  const ShadeLaunchLayer({super.key});

  @override
  ConsumerState<ShadeLaunchLayer> createState() => _ShadeLaunchLayerState();
}

class _ShadeLaunchLayerState extends ConsumerState<ShadeLaunchLayer>
    with TickerProviderStateMixin {
  static const _total = Duration(milliseconds: 500);
  static const _fadeIn = 150 / 500;
  static const _reveal = Duration(milliseconds: 183);

  /// An app that has not shown a window by then opens without the launch.
  static const _patience = Duration(seconds: 5);

  static const _emphasizedComplement = ThreePointCubic(
    Offset(0.1217, 0.0462),
    Offset(0.15, 0.4686),
    Offset(0.1667, 0.66),
    Offset(0.1834, 0.8878),
    Offset(0.1667, 1),
  );
  static const _linearOutSlowIn = Cubic(0, 0, 0.2, 1);
  static const _windowFadeIn = Cubic(0, 0, 0.6, 1);

  late final ShadeLaunch _launch = ref.read(shadeLaunchProvider);
  _Run? _run;
  Size _size = Size.zero;
  final _leaving = <_Run>[];

  @override
  void initState() {
    super.initState();
    _launch.addListener(_started);
    ref.listenManual(
      referenceShellProvider.select(
        (state) =>
            (request: state.launchRequest, window: state.launchingWindow),
      ),
      (_, next) => _shellChanged(next.request, next.window),
    );
  }

  @override
  void dispose() {
    _launch.removeListener(_started);
    _launch._release(covered: false);
    _run?.dispose();
    for (final run in _leaving) {
      run.dispose();
    }
    super.dispose();
  }

  void _started() {
    final start = _launch._takeStart();
    if (start == null) return;
    final previous = _run;
    if (previous != null) _cancel(previous);
    final run = _Run(
      vsync: this,
      requestId: start.requestId,
      origin: start.origin,
      iconPath: start.iconPath,
      grow: _total,
      reveal: _reveal,
    );
    _run = run;
    run.grow.addListener(() => _tick(run));
    run.grow.addStatusListener((_) => _maybeFinish(run));
    run.reveal.addListener(() => _tick(run));
    run.reveal.addStatusListener((_) => _maybeFinish(run));
    run.patience = Timer(_patience, () {
      if (identical(_run, run) && run.window == null) {
        ref.read(referenceShellProvider.notifier).failAppLaunch(run.requestId);
      }
    });
    final state = ref.read(referenceShellProvider);
    _shellChanged(state.launchRequest, state.launchingWindow);
    if (!identical(_run, run)) return;
    run.grow.forward();
    _tick(run);
    setState(() {});
  }

  void _shellChanged(AppLaunchRequest? request, DenialWindow? window) {
    final run = _run;
    if (run == null) return;
    if (request?.requestId != run.requestId) {
      _cancel(run);
      return;
    }
    if (window != null && run.window?.objectId != window.objectId) {
      run.window = window;
      _tick(run);
      setState(() {});
    }
  }

  /// The launch did not happen: what was drawn fades, and the shade closes
  /// as it would.
  void _cancel(_Run run) {
    if (identical(_run, run)) _run = null;
    run.patience?.cancel();
    run.grow.stop();
    run.reveal.stop();
    _launch._release(covered: false);
    _leaving.add(run);
    run.away.forward().whenCompleteOrCancel(() {
      _leaving.remove(run);
      run.dispose();
      if (mounted) setState(() {});
    });
    if (mounted) setState(() {});
  }

  void _tick(_Run run) {
    if (!identical(_run, run)) return;
    final t = run.grow.value;
    // The window's colour is opaque over the view: the app shows through
    // it once it has a window, or its splash does.
    if (t >= _fadeIn && run.reveal.isDismissed && !run.reveal.isAnimating) {
      if (run.window != null) {
        run.reveal.forward();
      } else if (!run.splash) {
        setState(() => run.splash = true);
      }
    }
    final size = _size;
    if (size.isEmpty) return;
    final rect = _rectAt(run, size, t);
    final radius = _radiusAt(run, t);
    run.pose.value = WindowPose(rect, math.max(radius.$1, radius.$2));
  }

  void _maybeFinish(_Run run) {
    if (!identical(_run, run) ||
        !run.grow.isCompleted ||
        !run.reveal.isCompleted) {
      return;
    }
    final window = run.window;
    if (window == null) return;
    _run = null;
    run.patience?.cancel();
    // The app covers the shade: it goes at once, and the app is handed
    // over to the stage beneath, in the same frame.
    _launch._release(covered: true);
    ref
        .read(referenceShellProvider.notifier)
        .completeLaunchTransition(run.requestId, window.objectId);
    WidgetsBinding.instance.addPostFrameCallback((_) => run.dispose());
    setState(() {});
  }

  Rect _toLocal(Rect global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return global;
    return Rect.fromPoints(
      box.globalToLocal(global.topLeft),
      box.globalToLocal(global.bottomRight),
    );
  }

  Rect _rectAt(_Run run, Size size, double t) {
    final from = run.local ??= _toLocal(run.origin.rect);
    final to = Offset.zero & size;
    final p = Curves.easeInOutCubicEmphasized.transform(t);
    final px = _emphasizedComplement.transform(t);
    final centre = ui.lerpDouble(from.center.dx, to.center.dx, px)!;
    final half = ui.lerpDouble(from.width, to.width, p)! / 2;
    return Rect.fromLTRB(
      centre - half,
      ui.lerpDouble(from.top, to.top, p)!,
      centre + half,
      ui.lerpDouble(from.bottom, to.bottom, p)!,
    );
  }

  (double, double) _radiusAt(_Run run, double t) {
    final p = Curves.easeInOutCubicEmphasized.transform(t);
    final end = context.shellTheme.windowRadius;
    return (
      ui.lerpDouble(run.origin.topRadius, end, p)!,
      ui.lerpDouble(run.origin.bottomRadius, end, p)!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = _size = MediaQuery.sizeOf(context);
    final runs = [..._leaving, ?_run];
    // Kept full size: a launch measures where it starts in it.
    if (runs.isEmpty) return const Positioned.fill(child: SizedBox.expand());
    final surface = context.shellColors.launchSurface;
    final splashIcon = 160 * PixelShadeViewport.scaleFor(size);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final run in runs)
              FadeTransition(
                key: ObjectKey(run),
                opacity: ReverseAnimation(run.away),
                child: AnimatedBuilder(
                  animation: Listenable.merge([run.grow, run.reveal]),
                  builder: (context, _) {
                    final t = run.grow.value;
                    final rect = _rectAt(run, size, t);
                    final (top, bottom) = _radiusAt(run, t);
                    final shape = RRect.fromRectAndCorners(
                      rect,
                      topLeft: Radius.circular(top),
                      topRight: Radius.circular(top),
                      bottomLeft: Radius.circular(bottom),
                      bottomRight: Radius.circular(bottom),
                    );
                    final fadeIn = _linearOutSlowIn.transform(
                      (t / _fadeIn).clamp(0.0, 1.0),
                    );
                    final revealing =
                        run.window != null && run.reveal.value > 0;
                    final layer =
                        fadeIn *
                        (1 - _windowFadeIn.transform(run.reveal.value));
                    final window = run.window;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        if (!revealing)
                          CustomPaint(
                            painter: _ViewPainter(
                              shape: shape,
                              from: run.local ?? rect,
                              origin: run.origin,
                            ),
                          ),
                        if (revealing && window != null)
                          PosedWindow(
                            pose: run.pose,
                            child: WindowSurface(
                              window: window,
                              contentPadding: EdgeInsets.only(
                                top: ReferenceShellMetrics.appStatusInset(size),
                              ),
                            ),
                          ),
                        CustomPaint(
                          painter: _LayerPainter(
                            shape: shape,
                            color: surface.withValues(alpha: surface.a * layer),
                          ),
                        ),
                        if (run.splash && layer > 0)
                          Positioned.fromRect(
                            rect: Rect.fromCenter(
                              center: rect.center,
                              width: splashIcon,
                              height: splashIcon,
                            ),
                            child: Opacity(
                              opacity: layer,
                              child: LauncherIcon(
                                iconPath: run.iconPath,
                                rasterize: true,
                              ),
                            ),
                          ),
                      ],
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

class _Run {
  _Run({
    required TickerProvider vsync,
    required this.requestId,
    required this.origin,
    required this.iconPath,
    required Duration grow,
    required Duration reveal,
  }) : grow = AnimationController(vsync: vsync, duration: grow),
       reveal = AnimationController(vsync: vsync, duration: reveal),
       away = AnimationController(
         vsync: vsync,
         duration: const Duration(milliseconds: 150),
       );

  final int requestId;
  final ShadeLaunchOrigin origin;
  final String? iconPath;
  final AnimationController grow;
  final AnimationController reveal;
  final AnimationController away;
  final pose = ValueNotifier(WindowPose.hidden);
  DenialWindow? window;
  bool splash = false;
  Timer? patience;

  /// The view's bounds in the layer.
  Rect? local;

  void dispose() {
    patience?.cancel();
    grow.dispose();
    reveal.dispose();
    away.dispose();
    pose.dispose();
    origin.image?.dispose();
  }
}

/// The view's background grown to [shape], its content (the ghost) over it:
/// scaled to fit and centred, or for a notification its own size at the
/// top.
class _ViewPainter extends CustomPainter {
  _ViewPainter({required this.shape, required this.from, required this.origin});

  final RRect shape;
  final Rect from;
  final ShadeLaunchOrigin origin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(shape, Paint()..color = origin.color);
    final image = origin.image;
    if (image == null || from.isEmpty) return;
    final rect = shape.outerRect;
    final Rect to;
    if (origin.scales) {
      final scale = math.min(
        rect.width / from.width,
        rect.height / from.height,
      );
      to = Rect.fromCenter(
        center: rect.center,
        width: from.width * scale,
        height: from.height * scale,
      );
    } else {
      to = Rect.fromLTWH(
        rect.center.dx - from.width / 2,
        rect.top,
        from.width,
        from.height,
      );
    }
    canvas
      ..save()
      ..clipRRect(shape);
    paintImage(
      canvas: canvas,
      rect: to,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ViewPainter old) =>
      old.shape != shape || old.from != from || old.origin != origin;
}

class _LayerPainter extends CustomPainter {
  _LayerPainter({required this.shape, required this.color});

  final RRect shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a <= 0) return;
    canvas.drawRRect(shape, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LayerPainter old) =>
      old.shape != shape || old.color != color;
}

/// Opens [desktopEntry]'s app out of the view the current press in the
/// shade landed on; [start] starts it with the launch's request id (null
/// without a launch) and says whether it did. An app open on a desk, or
/// one that cannot be found, opens as before, the shade closing.
Future<void> launchEntryFromShade(
  WidgetRef ref, {
  required String desktopEntry,
  required FutureOr<bool> Function(int? requestId, DenialWindow? running) start,
}) async {
  final origin = LaunchSources.take();
  final shell = ref.read(referenceShellProvider.notifier);
  final launch = ref.read(shadeLaunchProvider);
  final launcher = ref.read(appLauncherProvider);
  final app = desktopEntry.isEmpty
      ? null
      : await ref
            .read(desktopAppsRepositoryProvider)
            .loadApplication(desktopEntry);
  final state = shell.state;
  final running = app == null
      ? null
      : launcher.findOpenWindow(app, state.openAppWindows);
  final elsewhere =
      app != null &&
      running == null &&
      launcher.findOpenWindow(app, state.allOpenAppWindows) != null;
  final grows = app != null && !elsewhere;
  if (!grows) origin?.image?.dispose();
  await launchFromShade(
    shell,
    launch,
    origin: grows ? origin : null,
    appName: app?.name ?? '',
    iconPath: app?.iconPath,
    appIds: app == null ? const <String>[] : launcher.expectedWindowAppIds(app),
    running: running,
    start: (requestId) => start(requestId, running),
  );
}

/// Opens Phone Settings, at [page], out of the view the current press in
/// the shade landed on: the gear, a tile held, the notifications' button.
Future<void> openPhoneSettingsFromShade(WidgetRef ref, [String? page]) {
  final bridge = ref.read(denialBridgeProvider);
  final argv = <String>['denial-phone-settings', ?page];
  return launchEntryFromShade(
    ref,
    desktopEntry: 'org.denialwm.Settings',
    start: (requestId, _) =>
        bridge.launchApplication(argv, launchRequestId: requestId),
  );
}
