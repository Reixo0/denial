import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A vertical drag that reports its release at the finger's own speed, as
/// Android's shade reads it: [GestureDetector] caps it at 8000 logical px/s,
/// which a fast pull passes.
class ShadeDragDetector extends StatelessWidget {
  const ShadeDragDetector({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    required this.child,
    this.behavior,
    super.key,
  });

  final GestureDragStartCallback onStart;
  final GestureDragUpdateCallback onUpdate;
  final GestureDragEndCallback onEnd;
  final GestureDragCancelCallback onCancel;
  final HitTestBehavior? behavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    final multitouch = ScrollConfiguration.of(context)
        .getMultitouchDragStrategy(context);
    return RawGestureDetector(
      behavior: behavior,
      gestures: <Type, GestureRecognizerFactory>{
        VerticalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
              () => VerticalDragGestureRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onStart = onStart
                ..onUpdate = onUpdate
                ..onEnd = onEnd
                ..onCancel = onCancel
                ..maxFlingVelocity = double.maxFinite
                ..multitouchDragStrategy = multitouch
                ..gestureSettings = settings,
            ),
      },
      child: child,
    );
  }
}
