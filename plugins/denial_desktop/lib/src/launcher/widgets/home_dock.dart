import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';

import '../home_drag_controller.dart';
import '../home_grid_geometry.dart';
import '../home_interactions.dart';
import 'home_app_tile.dart';
import 'home_grid_page.dart';
import 'home_item_icon.dart';

/// The row of apps below home's pages. It stays as the pages turn.
///
/// A dragged app opens a gap where it would go; over a full dock, the app
/// it would trade places with fades.
class HomeDock extends ConsumerWidget {
  const HomeDock({super.key, required this.capacity});

  /// How many apps the dock takes, read while a drag needs it.
  final int Function() capacity;

  static const double radius = 30;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.watch(
      homeGridControllerProvider.select(
        (value) => value.asData?.value.dock ?? const <HomeGridItem>[],
      ),
    );
    final interactions = HomeInteractionScope.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: HomeFolderPlate.fill,
        border: Border.all(color: HomeFolderPlate.outline),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final geometry = HomeDockGeometry(
            bounds: Offset.zero & constraints.biggest,
            capacity: 0,
          );
          return ListenableBuilder(
            listenable: Listenable.merge([
              interactions.drag.drag,
              interactions.hiddenItems,
            ]),
            builder: (context, _) => Stack(
              clipBehavior: Clip.none,
              children: _icons(dock, geometry, interactions),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _icons(
    List<HomeGridItem> dock,
    HomeDockGeometry geometry,
    HomeInteractions interactions,
  ) {
    final drag = interactions.drag.drag.value;
    final places = <HomeGridItem?>[...dock];
    String? traded;
    if (drag != null && drag.landing == null) {
      if (drag.inDock) places.removeWhere((app) => app?.id == drag.item.id);
      final target = drag.target;
      if (target != null && target.kind == HomeDropKind.dock) {
        if (drag.inDock || dock.length < capacity()) {
          places.insert(target.index.clamp(0, places.length), null);
        } else if (target.index < places.length) {
          traded = places[target.index]?.id;
        }
      }
    }
    final hidden = interactions.hiddenItems.value;
    return [
      for (var place = 0; place < places.length; place++)
        if (places[place] case final app?)
          AnimatedPositioned.fromRect(
            key: ValueKey(app.id),
            rect: geometry.iconRect(place, places.length),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _DockIcon(
              app: app,
              position: dock.indexOf(app),
              // A released app shows once it has landed.
              hidden: drag?.item.id == app.id,
              iconHidden: hidden.contains(app.id),
              traded: app.id == traded,
            ),
          ),
    ];
  }
}

class _DockIcon extends StatelessWidget {
  const _DockIcon({
    required this.app,
    required this.position,
    required this.hidden,
    required this.iconHidden,
    required this.traded,
  });

  final HomeGridItem app;
  final int position;
  final bool hidden;
  final bool iconHidden;
  final bool traded;

  Rect? _globalRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
  }

  void _tap(BuildContext context) {
    final rect = _globalRect(context);
    if (rect != null) HomeInteractionScope.of(context).launch(app, rect);
  }

  void _hold(BuildContext context, LongPressStartDetails details) {
    final rect = _globalRect(context);
    if (rect == null) return;
    // The tile a drag lifts has its icon where this one is.
    final tile = Rect.fromCenter(
      center: rect.center,
      width: HomeTileMetrics.iconBox,
      height: HomeTileMetrics.iconBox,
    );
    HomeInteractionScope.of(context)
        .hold(app, position, tile, details.globalPosition, inDock: true);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: HomeAppTile.nameOf(context, app),
      excludeSemantics: true,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (recognizer) => recognizer.onTap = () => _tap(context),
              ),
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: HomeSlidingTile.holdDuration,
                ),
                (recognizer) =>
                    recognizer.onLongPressStart = (details) =>
                        _hold(context, details),
              ),
        },
        child: hidden || iconHidden
            ? const SizedBox.expand()
            : AnimatedOpacity(
                opacity: traded ? 0.45 : 1,
                duration: const Duration(milliseconds: 160),
                child: RepaintBoundary(child: HomeItemIcon(item: app)),
              ),
      ),
    );
  }
}
