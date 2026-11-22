import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'quick_settings_panel.dart';
import 'shade_expansion.dart';
import 'shade_progress.dart';
import 'status_bar.dart';

/// Top-level coordinator for the status bar and the shade.
///
/// It owns the shade's [ShadeExpansion]: the panel and quick settings
/// fractions, which every drag on the status bar or the shade moves. The
/// shell keeps only whether the shade is open; when that changes (a drag let
/// go, or anything that opens or closes the shade) the panel settles with
/// Android's fling.
class SystemShadeLayer extends ConsumerStatefulWidget {
  const SystemShadeLayer({super.key, this.ignoring = false});

  final bool ignoring;

  @override
  ConsumerState<SystemShadeLayer> createState() => _SystemShadeLayerState();
}

class _SystemShadeLayerState extends ConsumerState<SystemShadeLayer>
    with TickerProviderStateMixin {
  late final ShadeExpansion _expansion;
  late final ProxyAnimation _sharedProgress;
  bool _mountedPanel = false;
  bool _offstage = true;
  bool _active = false;

  AnimationController get _panel => _expansion.panel;

  @override
  void initState() {
    super.initState();
    final shell = ref.read(referenceShellProvider.notifier);
    _expansion = ShadeExpansion(
      vsync: this,
      onDragStart: shell.beginShadeDrag,
      onDragMove: shell.shadeDragMoved,
      onDragEnd: (open, velocity) =>
          shell.endShadeDrag(open: open, velocity: velocity),
    );
    _panel
      ..value = ref.read(referenceShellProvider).quickSettingsVisible ? 1 : 0
      ..addListener(_updateVisibility);
    _expansion.depth.addListener(_updateVisibility);
    _mountedPanel = _panel.value > 0;
    _offstage = !_mountedPanel;
    _active = _mountedPanel;
    _sharedProgress = ref.read(shadeProgressProvider)..parent = _panel;
    ref.read(shadeExpansionProvider).current = _expansion;
  }

  void _updateVisibility() {
    // The blur goes away after the shade has.
    final active = _panel.value > 0;
    final offstage = !active && _expansion.blur.value <= 0;
    if (offstage == _offstage && active == _active) return;
    setState(() {
      _offstage = offstage;
      _active = active;
      _mountedPanel = true;
    });
  }

  @override
  void dispose() {
    if (identical(_sharedProgress.parent, _panel)) {
      _sharedProgress.parent = const AlwaysStoppedAnimation(0.0);
    }
    final handle = ref.read(shadeExpansionProvider);
    if (identical(handle.current, _expansion)) handle.current = null;
    _expansion.dispose();
    super.dispose();
  }

  void _onShadeChanged((bool, bool) signal) {
    final (visible, dragActive) = signal;
    final shell = ref.read(referenceShellProvider.notifier);
    if (visible && shell.takeNotificationPageRequest()) {
      // Opened for its notifications: the quick tiles, not the full QS.
      if (_panel.value <= 0) {
        _expansion.qs.value = 0;
      } else {
        _expansion.flingQs(0);
      }
    }
    // A drag moves the panel itself; the shell only follows.
    if (dragActive || _expansion.dragging) return;
    _expansion.settlePanel(
      visible,
      velocity: shell.quickSettingsReleaseVelocity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    _expansion
      ..screenTravel = ReferenceShellMetrics.quickSettingsPanelExtent(size)
      ..dp = PixelShadeViewport.scaleFor(size)
      ..reduceMotion = MediaQuery.disableAnimationsOf(context);
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
                      expansion: _expansion,
                      active: _active,
                      shown: _active,
                      closed: closed,
                    ),
                  ),
                ),
              ),
            ShadeStatusBar(expansion: _expansion),
          ],
        ),
      ),
    );
  }
}
