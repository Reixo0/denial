import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launcher/home_surface.dart';

/// Visibility and interaction policy for the stock launcher feature.
///
/// Home comes back as on Android: out of an app (a swipe up or Back),
/// Launcher3's ScalingWorkspaceRevealAnim grows it from 0.85 over 1000 ms
/// on its own curve while it fades in over the first 200 ms; out of recents,
/// WorkspaceRevealAnim grows it from 0.88 over 350 ms (DECELERATED_EASE)
/// as it fades in. Durations run at the phone's 0.75 animator scale.
class MobileLauncherLayer extends ConsumerStatefulWidget {
  const MobileLauncherLayer({
    super.key,
    required this.contentOpacity,
    required this.overviewPresentationActive,
  });

  final Animation<double> contentOpacity;
  final ValueListenable<bool> overviewPresentationActive;

  @override
  ConsumerState<MobileLauncherLayer> createState() =>
      _MobileLauncherLayerState();
}

class _MobileLauncherLayerState extends ConsumerState<MobileLauncherLayer>
    with SingleTickerProviderStateMixin {
  static const Curve _decelerateEase = Cubic(0, 0, 0.2, 1);

  late final AnimationController _reveal = AnimationController(
    vsync: this,
    value: 1,
  );
  double _fromScale = 1;
  Curve _scaleCurve = _decelerateEase;
  double _fadeShare = 1;

  late final Animation<double> _opacity = _RevealOpacity(
    widget.contentOpacity,
    _reveal,
    () => _fadeShare,
  );

  @override
  void initState() {
    super.initState();
    ref.listenManual(
      referenceShellProvider.select(
        (state) => (
          home: state.homeTransitionActive,
          overview: state.overviewVisible,
          app: state.primaryWindow != null,
        ),
      ),
      (previous, next) {
        if (previous == null) return;
        if (!previous.home && next.home) {
          // An app is leaving for home.
          _play(
            from: 0.85,
            duration: 1000,
            curve: const _ScaleInterpolator(),
            fade: 200,
          );
        } else if (previous.overview && !next.overview && !next.app) {
          // Recents is closing onto home.
          _play(from: 0.88, duration: 350, curve: _decelerateEase, fade: 350);
        }
      },
    );
  }

  void _play({
    required double from,
    required int duration,
    required Curve curve,
    required int fade,
  }) {
    _fromScale = from;
    _scaleCurve = curve;
    _fadeShare = fade / duration;
    _reveal
      ..duration = Duration(milliseconds: (duration * 0.75).round())
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(
      referenceShellProvider.select((state) {
        final active =
            state.primaryWindow == null || state.homeTransitionActive;
        return (
          active: active,
          interactive:
              active &&
              !state.launchTransitionActive &&
              !state.overviewVisible &&
              state.gesture == GestureDragPhase.idle &&
              !state.quickSettingsEngaged &&
              !state.lockLayerVisible,
        );
      }),
    );
    final showsHome = ref.read(referenceShellProvider.notifier).deck.showsHome;
    // Keep the grid mounted while recents fade its content.
    // Phase changes alone update interaction/tickers; animation ticks stay
    // at the renderer and share the existing composited opacity layer.
    return ValueListenableBuilder<bool>(
      valueListenable: widget.overviewPresentationActive,
      // Home takes touches as soon as nothing above it holds them: while an
      // app flies back into its icon or recents slides away, so a quick
      // close and reopen never waits for an animation to end.
      builder: (context, overviewActive, _) => ValueListenableBuilder<bool>(
        // An app sliding in over home is in front already; home stays
        // until it is covered.
        valueListenable: showsHome,
        builder: (context, showsHome, _) => TickerMode(
          enabled: !overviewActive || flags.interactive,
          child: AnimatedBuilder(
            animation: _reveal,
            builder: (context, home) {
              final t = _scaleCurve.transform(_reveal.value);
              final scale = _fromScale + (1 - _fromScale) * t;
              return Transform.scale(scale: scale, child: home);
            },
            child: HomeSurface(
              active: flags.active || showsHome,
              interactive: flags.interactive,
              contentOpacity: _opacity,
            ),
          ),
        ),
      ),
    );
  }
}

/// Home's content opacity: the recents fade times the reveal's fade-in,
/// which takes the first [share] of the reveal.
class _RevealOpacity extends CompoundAnimation<double> {
  _RevealOpacity(
    Animation<double> recents,
    Animation<double> reveal,
    this.share,
  ) : super(first: recents, next: reveal);

  final double Function() share;

  @override
  double get value {
    final fade = (next.value / share()).clamp(0.0, 1.0);
    return (first.value * fade).clamp(0.0, 1.0);
  }
}

/// ScalingWorkspaceRevealAnim.SCALE_INTERPOLATOR: the path (0,0)
/// c(0.045,0.0356 0.0975,0.2055 0.15,0.3952) c(0.235,0.6855 0.235,1 1,1).
class _ScaleInterpolator extends Curve {
  const _ScaleInterpolator();

  static final List<Offset> _table = _build();

  static List<Offset> _build() {
    Offset cubic(Offset a, Offset b, Offset c, Offset d, double t) {
      final u = 1 - t;
      return a * (u * u * u) +
          b * (3 * u * u * t) +
          c * (3 * u * t * t) +
          d * (t * t * t);
    }

    const segments = [
      [
        Offset(0, 0),
        Offset(0.045, 0.0356),
        Offset(0.0975, 0.2055),
        Offset(0.15, 0.3952),
      ],
      [
        Offset(0.15, 0.3952),
        Offset(0.235, 0.6855),
        Offset(0.235, 1),
        Offset(1, 1),
      ],
    ];
    return [
      for (final s in segments)
        for (var i = 0; i <= 200; i++) cubic(s[0], s[1], s[2], s[3], i / 200),
    ];
  }

  @override
  double transformInternal(double t) {
    final table = _table;
    var lo = 0;
    var hi = table.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (table[mid].dx < t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = table[lo];
    final b = table[hi];
    final span = b.dx - a.dx;
    if (span <= 0) return b.dy;
    return a.dy + (b.dy - a.dy) * (t - a.dx) / span;
  }
}
