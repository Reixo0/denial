import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


import 'quick_settings_panel.dart';
import 'shade_expansion_motion.dart' show aospShadeFling;
import 'shade_progress.dart';
import 'status_bar.dart';

/// Top-level coordinator for the status bar and the quick-settings shade.
///
/// It owns a single controller whose value mirrors the shade's open fraction:
/// it tracks the drag 1:1 while the user is pulling, and settles with a spring
/// once released. All control state lives in providers, so this widget stays a
/// thin animation host.
class SystemShadeLayer extends ConsumerStatefulWidget {
  const SystemShadeLayer({super.key, this.ignoring = false});

  final bool ignoring;

  @override
  ConsumerState<SystemShadeLayer> createState() => _SystemShadeLayerState();
}

class _SystemShadeLayerState extends ConsumerState<SystemShadeLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final ProxyAnimation _sharedProgress;
  late final ValueListenable<double> _drag;
  bool _mountedPanel = false;
  bool _offstage = true;
  ShadePage _page = ShadePage.notifications;

  @override
  void initState() {
    super.initState();
    final state = ref.read(referenceShellProvider);
    _drag = ref.read(referenceShellProvider.notifier).quickSettingsDrag
      ..addListener(_followDrag);
    _controller = AnimationController(
      vsync: this,
      value: state.quickSettingsVisible ? 1.0 : _drag.value,
    )..addListener(_updateVisibility);
    _mountedPanel = _controller.value > 0;
    _offstage = !_mountedPanel;
    _sharedProgress = ref.read(shadeProgressProvider)..parent = _controller;
  }

  void _updateVisibility() {
    final offstage = _controller.value <= 0;
    if (offstage == _offstage) return;
    setState(() {
      _offstage = offstage;
      _mountedPanel = true;
    });
  }

  // The drag moves the shade on every frame without touching the shell state.
  void _followDrag() {
    if (!ref.read(referenceShellProvider).quickSettingsDragActive) return;
    _controller.stop();
    _controller.value = _drag.value;
  }

  @override
  void dispose() {
    _drag.removeListener(_followDrag);
    if (identical(_sharedProgress.parent, _controller)) {
      _sharedProgress.parent = const AlwaysStoppedAnimation(0.0);
    }
    _controller.dispose();
    super.dispose();
  }

  void _onShadeChanged((bool, bool) signal) {
    final (visible, dragActive) = signal;
    if (visible &&
        ref
            .read(referenceShellProvider.notifier)
            .takeNotificationPageRequest() &&
        _page != ShadePage.notifications) {
      setState(() => _page = ShadePage.notifications);
    }
    if (dragActive) {
      // Live drag: follow the finger exactly.
      _controller.stop();
      _controller.value = _drag.value;
    } else {
      // Released: settle open or closed, continuing the finger's velocity.
      // A drag moves the shade by one panel extent per extent of travel.
      final size = MediaQuery.sizeOf(context);
      final extent = ReferenceShellMetrics.quickSettingsPanelExtent(size);
      final target = visible ? 1.0 : 0.0;
      // Android's fling: no quicker than its 0.6 s shade, as the owner
      // found the springs too fast.
      final fling = aospShadeFling(
        distance: target - _controller.value,
        velocity:
            ref
                .read(referenceShellProvider.notifier)
                .quickSettingsReleaseVelocity /
            extent,
        dp: PixelShadeViewport.scaleFor(size) / extent,
      );
      _controller.animateTo(
        target,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : fling.duration,
        curve: fling.curve,
      );
    }
  }

  // Android: a pull from anywhere on the status bar shows the notifications
  // first; pulling again opens the full quick settings.
  void _selectPageFromStatusBar(Offset position) {
    if (_page != ShadePage.notifications) {
      setState(() => _page = ShadePage.notifications);
    }
  }

  @override
  Widget build(BuildContext context) {
    final closed = ref.watch(
      referenceShellProvider.select(
        (state) =>
            !state.quickSettingsVisible && !state.quickSettingsDragActive,
      ),
    );
    ref.listen<(bool, bool)>(
      referenceShellProvider.select(
        (state) => (state.quickSettingsVisible, state.quickSettingsDragActive),
      ),
      (_, next) => _onShadeChanged(next),
    );

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: widget.ignoring,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_mountedPanel)
              Offstage(
                offstage: _offstage,
                child: TickerMode(
                  enabled: !_offstage,
                  child: RepaintBoundary(
                    child: QuickSettingsShade(
                      progress: _controller,
                      active: !_offstage,
                      closed: closed,
                      page: _page,
                      onPageChanged: (page) {
                        if (_page != page) setState(() => _page = page);
                      },
                    ),
                  ),
                ),
              ),
            ShadeStatusBar(
              shadeProgress: _controller,
              onDragStart: _selectPageFromStatusBar,
            ),
          ],
        ),
      ),
    );
  }
}
