import 'package:flutter/widgets.dart';

import 'quick_settings_panel.dart' show PixelShadeViewport;
import 'shade_expansion.dart';

/// The shade's empty space and its notification list: a vertical drag moves
/// the shade through its [ShadeExpansion] (down opens the full quick
/// settings, up collapses them and then closes the shade). A tap does
/// nothing (EvolutionX: onMiddleClicked has no case for the open shade).
/// A scrollable child wins the vertical gesture arena; [canDrag] also keeps
/// a scrollable list from moving the shade.
class ShadeDismissGesture extends StatefulWidget {
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
  State<ShadeDismissGesture> createState() => _ShadeDismissGestureState();
}

class _ShadeDismissGestureState extends State<ShadeDismissGesture> {
  /// Kept in the state: the shade rebuilds this during the drag.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final expansion = widget.expansion;
    // Inside the shade's dp viewport a drag's delta is in dp.
    final scale = PixelShadeViewport.scaleOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
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
