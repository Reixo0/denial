import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';

import 'home_app_tile.dart';
import 'home_item_icon.dart';

/// Every installed app, by name, over home: the ones taken off home too.
/// A swipe up on home pulls it up. Pulling down on its search field, or on
/// the list scrolled to its top, brings it down with the finger.
class HomeAppDrawer extends ConsumerStatefulWidget {
  const HomeAppDrawer({
    super.key,
    required this.progress,
    required this.onPull,
    required this.onRelease,
    required this.onLaunch,
    required this.onHold,
  });

  /// 0 put away, 1 open.
  final Animation<double> progress;

  /// The finger pulled it down by this many pixels (up when negative).
  final ValueChanged<double> onPull;

  /// The finger let go at this speed, in pixels a second downwards.
  final ValueChanged<double> onRelease;

  /// An app tapped or held, with its icon in global coordinates.
  final void Function(HomeGridItem app, Rect iconRect) onLaunch;
  final void Function(HomeGridItem app, Rect iconRect, Offset pointer) onHold;

  @override
  ConsumerState<HomeAppDrawer> createState() => _HomeAppDrawerState();
}

class _HomeAppDrawerState extends ConsumerState<HomeAppDrawer> {
  static const Color _scrim = Color(0xeb0e0f12);
  static const double _top = 66;

  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  String _query = '';

  /// The finger pulls the drawer instead of scrolling the list.
  bool _pulling = false;
  VelocityTracker? _velocity;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      final query = _search.text.trim().toLowerCase();
      if (query != _query) setState(() => _query = query);
    });
    widget.progress.addStatusListener(_progressChanged);
  }

  @override
  void didUpdateWidget(covariant HomeAppDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeStatusListener(_progressChanged);
      widget.progress.addStatusListener(_progressChanged);
    }
  }

  @override
  void dispose() {
    widget.progress.removeStatusListener(_progressChanged);
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Put away, it opens fresh next time: at the top, without a search.
  void _progressChanged(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    _searchFocus.unfocus();
    _search.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Pulled down past the top of the list, the drawer follows the finger
  /// from then on.
  bool _scrolled(ScrollNotification notification) {
    if (notification is OverscrollNotification &&
        notification.overscroll < 0 &&
        notification.dragDetails != null &&
        !_pulling) {
      _pulling = true;
      widget.onPull(-notification.overscroll);
    }
    return false;
  }

  void _pointerDown(PointerDownEvent event) {
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _pointerMove(PointerMoveEvent event) {
    _velocity?.addPosition(event.timeStamp, event.position);
    if (_pulling) widget.onPull(event.delta.dy);
  }

  void _pointerUp(PointerEvent event) {
    final velocity = _velocity?.getVelocity().pixelsPerSecond.dy ?? 0;
    _velocity = null;
    if (!_pulling) return;
    widget.onRelease(event is PointerCancelEvent ? 0 : velocity);
    // The list settles after this event: it must not fling with the pull.
    scheduleMicrotask(() => _pulling = false);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(
      homeGridControllerProvider.select(
        (value) => value.asData?.value.catalog ?? const <HomeGridItem>[],
      ),
    );
    final named = [
      for (final app in catalog)
        (app: app, name: HomeAppTile.nameOf(context, app)),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final shown = _query.isEmpty
        ? named
        : named.where((entry) => entry.name.toLowerCase().contains(_query));
    final apps = [for (final entry in shown) entry.app];

    return AnimatedBuilder(
      animation: widget.progress,
      builder: (context, child) {
        final progress = widget.progress.value;
        // Put away, it neither paints nor takes touches.
        return Offstage(
          offstage: progress == 0,
          child: IgnorePointer(
            ignoring: progress < 0.5,
            // It rises from the bottom of the screen.
            child: FractionalTranslation(
              translation: Offset(0, 1 - progress),
              child: child,
            ),
          ),
        );
      },
      child: ColoredBox(
        color: _scrim,
        child: Padding(
          padding: const EdgeInsets.only(top: _top),
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) =>
                    widget.onPull(details.primaryDelta ?? 0),
                onVerticalDragEnd: (details) =>
                    widget.onRelease(details.primaryVelocity ?? 0),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
                  child: _SearchField(controller: _search, focus: _searchFocus),
                ),
              ),
              Expanded(
                child: Listener(
                  onPointerDown: _pointerDown,
                  onPointerMove: _pointerMove,
                  onPointerUp: _pointerUp,
                  onPointerCancel: _pointerUp,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _scrolled,
                    child: LayoutBuilder(
                      builder: (context, constraints) => GridView.builder(
                        controller: _scroll,
                        physics: _PullLockPhysics(
                          locked: () => _pulling,
                          parent: const AlwaysScrollableScrollPhysics(
                            parent: ClampingScrollPhysics(),
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 72),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: (constraints.maxWidth / 104)
                              .floor()
                              .clamp(4, 10),
                          mainAxisExtent: 112,
                        ),
                        itemCount: apps.length,
                        itemBuilder: (context, index) => _DrawerTile(
                          key: ValueKey(apps[index].id),
                          app: apps[index],
                          onLaunch: widget.onLaunch,
                          onHold: widget.onHold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focus});

  final TextEditingController controller;
  final FocusNode focus;

  static const Color _fill = Color(0x26ffffff);
  static const Color _hint = Color(0x99ffffff);

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focus,
      textInputAction: TextInputAction.search,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      cursorColor: Colors.white,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: _fill,
        hintText: 'Search apps',
        hintStyle: const TextStyle(color: _hint),
        prefixIcon: const Icon(Icons.search_rounded, color: _hint),
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(26),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    super.key,
    required this.app,
    required this.onLaunch,
    required this.onHold,
  });

  final HomeGridItem app;
  final void Function(HomeGridItem app, Rect iconRect) onLaunch;
  final void Function(HomeGridItem app, Rect iconRect, Offset pointer) onHold;

  static const double _icon = 62;

  Rect? _iconRect(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final tile = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    return Rect.fromLTWH(
      tile.center.dx - _icon / 2,
      tile.top + 8,
      _icon,
      _icon,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: HomeAppTile.nameOf(context, app),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_iconRect(context) case final rect?) onLaunch(app, rect);
        },
        onLongPressStart: (details) {
          if (_iconRect(context) case final rect?) {
            onHold(app, rect, details.globalPosition);
          }
        },
        child: Column(
          children: [
            const SizedBox(height: 8),
            SizedBox.square(
              dimension: _icon,
              child: RepaintBoundary(child: HomeItemIcon(item: app)),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                HomeAppTile.nameOf(context, app),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: HomeAppTile.labelStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The list holds still while the finger pulls the drawer.
class _PullLockPhysics extends ScrollPhysics {
  const _PullLockPhysics({required this.locked, super.parent});

  final bool Function() locked;

  @override
  _PullLockPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullLockPhysics(locked: locked, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      locked() ? 0 : super.applyPhysicsToUserOffset(position, offset);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => locked() ? null : super.createBallisticSimulation(position, velocity);
}
