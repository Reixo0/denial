import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shares the handle's interactive panel motion with the space below it.
/// A scrollable child wins the vertical gesture arena; [canDrag] also guards
/// against dismissing a long history when its scroll position is at an edge.
class ShadeDismissGesture extends ConsumerStatefulWidget {
  const ShadeDismissGesture({
    required this.progress,
    required this.child,
    this.canDrag,
    this.handlers,
    super.key,
  });

  final Animation<double> progress;
  final Widget child;
  final bool Function()? canDrag;

  /// Takes the vertical drag instead of moving the shade (the phone shade
  /// uses it to open its full quick settings).
  final ShadeDragHandlers? handlers;

  @override
  ConsumerState<ShadeDismissGesture> createState() =>
      _ShadeDismissGestureState();
}

class _ShadeDismissGestureState extends ConsumerState<ShadeDismissGesture> {
  bool _dragging = false;
  double _distance = 0;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(referenceShellProvider.notifier);
    final handlers = widget.handlers;
    if (handlers != null) {
      // The flag lives in the state: the shade rebuilds this during the
      // drag, and a local would forget the drag halfway.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: controller.closeQuickSettings,
        onVerticalDragStart: (details) {
          _dragging = widget.canDrag?.call() ?? true;
          if (_dragging) handlers.onStart(details);
        },
        onVerticalDragUpdate: (details) {
          if (_dragging) handlers.onUpdate(details);
        },
        onVerticalDragEnd: (details) {
          if (_dragging) handlers.onEnd(details);
          _dragging = false;
        },
        onVerticalDragCancel: () {
          if (_dragging) handlers.onEnd(DragEndDetails(primaryVelocity: 0));
          _dragging = false;
        },
        child: widget.child,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.closeQuickSettings,
      onVerticalDragStart: (_) {
        _dragging = widget.canDrag?.call() ?? true;
        _distance = 0;
        if (_dragging) {
          controller.startQuickSettingsDrag(progress: widget.progress.value);
        }
      },
      onVerticalDragUpdate: (details) {
        if (!_dragging) return;
        _distance += details.delta.dy;
        controller.updateQuickSettingsDrag(
          Offset(
            0,
            details.delta.dy *
                ReferenceShellMetrics.quickSettingsDragScale(
                  MediaQuery.sizeOf(context),
                ),
          ),
        );
      },
      onVerticalDragEnd: (details) {
        if (!_dragging) return;
        _dragging = false;
        final velocity = details.primaryVelocity ?? 0;
        if (_distance <= -48 || velocity <= -500) {
          controller.closeQuickSettings(releaseVelocity: velocity);
        } else {
          controller.endQuickSettingsDrag(velocity);
        }
      },
      onVerticalDragCancel: () {
        if (!_dragging) return;
        _dragging = false;
        controller.endQuickSettingsDrag(0);
      },
      child: widget.child,
    );
  }
}

/// A vertical drag's callbacks, handed down to the shade's gesture areas.
class ShadeDragHandlers {
  const ShadeDragHandlers({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final GestureDragStartCallback onStart;
  final GestureDragUpdateCallback onUpdate;
  final GestureDragEndCallback onEnd;
}
