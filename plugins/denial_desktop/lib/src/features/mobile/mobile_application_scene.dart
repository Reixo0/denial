import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_presentation.dart';

import '../../core/denial_shell.dart';

import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/motion.dart' show SelectedListenable;
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/app_flight_layer.dart';
import '../../widgets/back_gesture_layer.dart';
import '../../widgets/bottom_gesture_handle.dart';
import '../../widgets/edge_panel_layer.dart';
import '../../widgets/shade/shade_launch.dart';
import '../../widgets/shade/shade_progress.dart';
import '../../widgets/shade/system_shade_layer.dart';
import '../../state/unlock_then.dart';
import 'mobile_launcher_layer.dart';
import 'mobile_window_layers.dart';

/// Denial's built-in phone/tablet application scene.
///
/// The mobile scene's wallpaper, frosted once.
///
/// Mobile windows are translucent over a static wallpaper: every window, and
/// the shade above them, draws its slice of this backdrop instead of live
/// glass. The keyboard viewport moves the whole scene, so the backdrop is
/// anchored to the scene frame.
final mobileWallpaperGlassProvider = Provider<FrostedBackdropCapture>((ref) {
  final capture = FrostedBackdropCapture(
    frame: GlobalKey(debugLabel: 'mobile scene'),
  );
  ref.onDispose(capture.dispose);
  return capture;
});

/// All compositor lifecycle behavior is supplied by [DenialShell]; this class
/// contains only the visual feature policy of the stock mobile experience.
class MobileApplicationScene extends ConsumerStatefulWidget {
  const MobileApplicationScene({super.key});

  @override
  ConsumerState<MobileApplicationScene> createState() =>
      _MobileApplicationSceneState();
}

class _MobileApplicationSceneState
    extends ConsumerState<MobileApplicationScene> {
  final _overviewPresentationActive = ValueNotifier(false);
  final _overviewProgress = ValueNotifier(0.0);
  late final _wallpaperGlass = ref.read(mobileWallpaperGlassProvider);
  late final _homeContentOpacity = Animation<double>.fromValueListenable(
    _overviewProgress,
    transformer: (progress) => 1.0 - progress,
  );

  @override
  void initState() {
    super.initState();
    // Nothing here animates a window's close, so a closed window's last frame
    // is released at once instead of staying leased until native's watchdog.
    ref.listenManual(referenceShellProvider.select((state) => state.windows), (
      previous,
      next,
    ) {
      if (previous == null) {
        return;
      }
      final remaining = {for (final window in next) window.windowId};
      final bridge = ref.read(denialBridgeProvider);
      for (final window in previous) {
        if (!remaining.contains(window.windowId)) {
          bridge.completeWindowClose(window.windowId);
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wallpaperGlass.configure(
      theme: context.shellTheme,
      pixelRatio: math.min(MediaQuery.devicePixelRatioOf(context), 1),
    );
  }

  @override
  void dispose() {
    _overviewPresentationActive.dispose();
    _overviewProgress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.shellColors.background,
      child: MobileKeyboardViewport(
        appScene: true,
        child: ValueListenableBuilder<FrostedBackdrop?>(
          valueListenable: _wallpaperGlass,
          // Layers that move windows add their motion below.
          builder: (context, backdrop, scene) => WindowBackdropCache(
            backdrop: backdrop,
            motion: const AlwaysStoppedAnimation<double>(0),
            child: scene!,
          ),
          child: Stack(
            key: _wallpaperGlass.frame,
            fit: StackFit.expand,
            children: [
              _MobileSceneWallpaper(
                overviewPresentationActive: _overviewPresentationActive,
                onPainted: _wallpaperGlass.painted,
              ),
              RepaintBoundary(
                child: MobileLauncherLayer(
                  contentOpacity: _homeContentOpacity,
                  overviewPresentationActive: _overviewPresentationActive,
                ),
              ),
              const MobilePrimaryWindowLayer(),
              MobileAppDeckLayer(
                backdrop: _wallpaperGlass,
                onPresentationChanged: (active) =>
                    _overviewPresentationActive.value = active,
                onProgressChanged: (progress) =>
                    _overviewProgress.value = progress,
              ),
              // Above recents: a card leaving recents for home keeps
              // flying over the cards that settle away.
              const AppFlightLayer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The wallpaper, kept mounted but unpainted while a settled opaque app
/// covers the whole stage: every app frame would otherwise also composite
/// the wallpaper's full-output fills and image underneath it.
class _MobileSceneWallpaper extends ConsumerStatefulWidget {
  const _MobileSceneWallpaper({
    required this.overviewPresentationActive,
    required this.onPainted,
  });

  final ValueListenable<bool> overviewPresentationActive;
  final ValueChanged<RenderRepaintBoundary> onPainted;

  @override
  ConsumerState<_MobileSceneWallpaper> createState() =>
      _MobileSceneWallpaperState();
}

class _MobileSceneWallpaperState extends ConsumerState<_MobileSceneWallpaper> {
  late final ValueListenable<bool> _shadeCovers = ref.read(shadeCoversProvider);

  /// Recents shows the wallpaper around its cards. The shade's frost fades
  /// out at the screen's edge, over the wallpaper once the app beneath it is
  /// hidden. Either signal changing can change that.
  late final _exposure = SelectedListenable(
    Listenable.merge([widget.overviewPresentationActive, _shadeCovers]),
    () => widget.overviewPresentationActive.value || _shadeCovers.value,
  );

  @override
  void dispose() {
    _exposure.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final covered = ref.watch(
      referenceShellProvider.select((state) {
        final window = state.primaryWindow;
        return window != null &&
            window.isOpaque &&
            state.launchRequest == null &&
            state.gesture == GestureDragPhase.idle &&
            !state.overviewVisible &&
            !state.homeTransitionActive;
      }),
    );
    final topInset = ref.watch(mobilePresentationTopInsetProvider);
    final frost = shadeFrostOccludes(context);
    return ListenableBuilder(
      listenable: _exposure,
      builder: (context, wallpaper) => Offstage(
        offstage:
            covered &&
            topInset == 0 &&
            !widget.overviewPresentationActive.value &&
            !(frost && _shadeCovers.value),
        child: wallpaper,
      ),
      child: ShellWallpaper(onPainted: widget.onPainted),
    );
  }
}

/// Gesture chrome for the stock mobile shell, under the lock screen.
class MobileShellChrome extends ConsumerWidget {
  const MobileShellChrome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ValueListenableBuilder<FrostedBackdrop?>(
      valueListenable: ref.watch(mobileWallpaperGlassProvider),
      builder: (context, backdrop, chrome) => WindowBackdropCache(
        backdrop: backdrop,
        motion: const AlwaysStoppedAnimation<double>(0),
        child: chrome!,
      ),
      child: const Stack(
        fit: StackFit.expand,
        children: [BottomGestureHandle()],
      ),
    );
  }
}

/// The status bar and notification shade, with the Back gesture that
/// closes them, over the apps and the lock screen alike: on Android the
/// shade pulls down over the lock screen too. The Back gesture is off
/// while locked unless the shade is open.
class MobileShellShade extends ConsumerWidget {
  const MobileShellShade({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launchActive = ref.watch(
      referenceShellProvider.select((state) => state.launchRequest != null),
    );
    return ValueListenableBuilder<FrostedBackdrop?>(
      valueListenable: ref.watch(mobileWallpaperGlassProvider),
      builder: (context, backdrop, chrome) => WindowBackdropCache(
        backdrop: backdrop,
        motion: const AlwaysStoppedAnimation<double>(0),
        child: chrome!,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The shade's layers are positioned in a stack of their own.
          Positioned.fill(
            child: _ShadeUnderCredential(
              child: Stack(
                fit: StackFit.expand,
                children: [SystemShadeLayer(ignoring: launchActive)],
              ),
            ),
          ),
          // A launch out of the shade grows over it.
          const ShadeLaunchLayer(),
          const MobileBackGestureLayer(),
        ],
      ),
    );
  }
}

/// The credential over the locked shade: as Android's bouncer comes up, the
/// shade blurs at once and fades out under it (about 200 ms on the
/// emulator), and comes back as quickly when the credential is dismissed or
/// the phone unlocks. Back still reaches the credential through the layer
/// above.
class _ShadeUnderCredential extends ConsumerStatefulWidget {
  const _ShadeUnderCredential({required this.child});

  final Widget child;

  @override
  ConsumerState<_ShadeUnderCredential> createState() =>
      _ShadeUnderCredentialState();
}

class _ShadeUnderCredentialState extends ConsumerState<_ShadeUnderCredential>
    with SingleTickerProviderStateMixin {
  static const double _blurSigma = 30;

  late final AnimationController _hidden = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 120),
    value: ref.read(unlockThenProvider).overShade ? 1 : 0,
  );

  @override
  void dispose() {
    _hidden.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(unlockThenProvider.select((state) => state.overShade), (
      _,
      over,
    ) {
      if (over) {
        _hidden.forward();
      } else {
        _hidden.reverse();
      }
    });
    // One tree at every value, so the shade keeps its state.
    return AnimatedBuilder(
      animation: _hidden,
      child: widget.child,
      builder: (context, child) {
        final t = _hidden.value;
        // The blur is whole within the first fifth, as Android's is in a
        // frame.
        final sigma = _blurSigma * (t * 5).clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: t > 0,
          child: Opacity(
            opacity: 1 - t,
            child: ImageFiltered(
              enabled: sigma > 0,
              imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
