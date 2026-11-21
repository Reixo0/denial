import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'quick_settings_panel.dart' show PixelShadeViewport;
import 'shade_expansion.dart';

/// The shade's empty space and its notification list: a tap closes the
/// shade, a vertical drag moves it through its [ShadeExpansion] (down opens
/// the full quick settings, up collapses them and then closes the shade).
/// A scrollable child wins the vertical gesture arena; [canDrag] also keeps
/// a scrollable list from moving the shade.
class ShadeDismissGesture extends ConsumerStatefulWidget {
  const ShadeDismissGesture({
    required this.expansion,
    required this.child,
    this.canDrag,
    super.key,
  });

  final ShadeExpansion expansion;
  final Widget child;
  final bool Function()? canDrag;

  @override
  ConsumerState<ShadeDismissGesture> createState() =>
      _ShadeDismissGestureState();
}

class _ShadeDismissGestureState extends ConsumerState<ShadeDismissGesture> {
  /// Kept in the state: the shade rebuilds this during the drag.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final expansion = widget.expansion;
    // Inside the shade's dp viewport a drag's delta is in dp.
    final scale = PixelShadeViewport.scaleOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: ref.read(referenceShellProvider.notifier).closeQuickSettings,
      onVerticalDragStart: (_) {
        _dragging = (widget.canDrag?.call() ?? true) && expansion.beginDrag();
      },
      onVerticalDragUpdate: (details) {
        if (_dragging) expansion.dragBy(details.delta.dy * scale);
      },
      onVerticalDragEnd: (details) {
        if (_dragging) {
          expansion.endDrag((details.primaryVelocity ?? 0) * scale);
        }
        _dragging = false;
      },
      onVerticalDragCancel: () {
        if (_dragging) expansion.endDrag(0);
        _dragging = false;
      },
      child: widget.child,
    );
  }
}
