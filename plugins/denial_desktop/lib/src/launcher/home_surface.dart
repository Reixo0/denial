import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart' show ShellSprings;
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import '../state/home_back.dart';
import '../state/reference_shell_controller.dart';
import 'home_drag_controller.dart';
import 'home_grid_geometry.dart';
import 'home_icon_locator.dart';
import 'home_interactions.dart';
import 'home_item_menu.dart';
import 'home_launch.dart';
import 'home_pager.dart';
import 'home_resize_controller.dart';
import 'widgets/home_app_drawer.dart';
import 'widgets/home_backdrop.dart';
import 'widgets/home_dock.dart';
import 'widgets/home_drag_layer.dart';
import 'widgets/home_folder_panel.dart';
import 'widgets/home_resize_frame.dart';

/// The mobile home screen: paged apps, folders and widgets over the
/// wallpaper.
class HomeSurface extends ConsumerStatefulWidget {
  const HomeSurface({
    super.key,
    this.active = true,
    this.interactive = true,
    this.contentOpacity,
  });

  /// Whether home is part of the visible shell scene. Its laid-out subtree
  /// is retained offstage while inactive, avoiding a cold grid and icon
  /// rebuild on the first frame of a swipe back to home.
  final bool active;

  /// Whether pointer events may reach home. Home can stay visible behind
  /// shell-owned transitions without accepting accidental taps.
  final bool interactive;

  /// Fades icons, widgets and page indicators independently of the backdrop.
  /// The animation updates composited opacity without rebuilding the grid.
  final Animation<double>? contentOpacity;

  @override
  ConsumerState<HomeSurface> createState() => _HomeSurfaceState();
}

class _HomeSurfaceState extends ConsumerState<HomeSurface>
    with TickerProviderStateMixin
    implements HomeGridHost, HomeInteractions {
  static const double _top = 66;

  /// The dock clears the bottom gesture handle, and sideways, the screen's
  /// right edge.
  static const double _dockBottom = 56;
  static const double _dockSide = 12;

  /// Where the pages go: above the dock, or beside it when sideways.
  static EdgeInsets _contentPadding({required bool sideways}) => sideways
      ? const EdgeInsets.fromLTRB(
          0,
          _top,
          _dockSide + HomeDockGeometry.thickness + 4,
          4,
        )
      : const EdgeInsets.fromLTRB(
          0,
          _top,
          0,
          _dockBottom + HomeDockGeometry.thickness + 14,
        );

  /// A held icon's menu gives way to a drag past this distance.
  static const double _menuSlop = 14;

  /// A held icon lifts first; its menu follows if the finger stays put, so
  /// starting a drag never flashes it.
  static const Duration _menuDelay = Duration(milliseconds: 350);

  /// A swipe this fast opens or closes the app drawer however short it was;
  /// slower, it has to travel a quarter of the screen.
  static const double _drawerFling = 500;
  static const double _drawerTravel = 0.25;

  /// A widget held in its resize frame starts moving past this distance.
  static const double _widgetDragSlop = 28;

  final _pages = PageController();
  final _viewportKey = GlobalKey();
  final _surfaceKey = GlobalKey();
  final _dockKey = GlobalKey();
  final _menuKey = GlobalKey();
  late final _drawer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  /// The menu of the held icon, while it shows.
  final _menu = ValueNotifier<HomeItemMenuRequest?>(null);

  /// Where the finger was when it held an icon; null once it moved on to
  /// drag.
  Offset? _menuHold;

  /// The menu the held icon opens once [_menuDelay] passes, or the finger
  /// lifts without moving.
  HomeItemMenuRequest? _pendingMenu;
  Timer? _menuTimer;

  /// An app held in the drawer: moving the finger drags it onto home.
  ({HomeGridItem app, Rect iconRect})? _drawerHold;

  /// A text field on home, such as the drawer's search or a folder's name,
  /// is being edited: the keyboard types into the shell.
  final _editing = ValueNotifier(false);

  /// The grid's columns upright: the dock takes as many apps either way.
  int _uprightColumns = HomeGridLayout.columns;
  late final HomeIconLocator _locator = ref.read(homeIconLocatorProvider);
  late final _taps = _BackgroundTaps(onDoubleTap: _sleepFromDoubleTap);

  @override
  final folders = HomeFolderController();
  @override
  late final drag = HomeDragController(this);
  @override
  late final resize = HomeResizeController(this);

  HomeGridGeometry? _geometry;
  int? _pointer;

  /// A widget whose long press opened its resize frame; moving the finger
  /// on lifts it instead.
  ({HomeGridItem item, int index, Rect rect, Offset start})? _heldWidget;

  /// The press that dismissed a resize frame does nothing else.
  bool _swallowTap = false;

  @override
  void initState() {
    super.initState();
    _locator.attach(_iconFor);
    FocusManager.instance.addListener(_focusChanged);
    _drawer.addStatusListener((_) => _syncBack());
    folders.open.addListener(_syncBack);
    _menu.addListener(_syncBack);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(homeGridControllerProvider.notifier)
          .setLauncherActive(widget.active && widget.interactive);
    });
  }

  @override
  void didUpdateWidget(covariant HomeSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasVisible = oldWidget.active && oldWidget.interactive;
    final visible = widget.active && widget.interactive;
    if (wasVisible != visible) {
      ref.read(homeGridControllerProvider.notifier).setLauncherActive(visible);
    }
    if (wasVisible && !visible) {
      _cancelInteraction();
      _drawer.value = 0;
    }
  }

  @override
  void dispose() {
    _locator.detach(_iconFor);
    FocusManager.instance.removeListener(_focusChanged);
    _menuTimer?.cancel();
    _editing.dispose();
    drag.dispose();
    resize.dispose();
    folders.dispose();
    _pages.dispose();
    _drawer.dispose();
    _menu.dispose();
    super.dispose();
  }

  void _cancelInteraction() {
    _pointer = null;
    _heldWidget = null;
    _clearHold();
    _menu.value = null;
    _taps.reset();
    resize.exit();
    drag.abandon();
  }

  // HomeGridHost -------------------------------------------------------------

  @override
  HomeGridState? get grid => ref.read(homeGridControllerProvider).asData?.value;

  @override
  HomeGridController get gridController =>
      ref.read(homeGridControllerProvider.notifier);

  @override
  HomeGridGeometry? get geometry => _geometry;

  @override
  HomeDockGeometry? get dock {
    final box = _boxOf(_dockKey);
    if (box == null) return null;
    return HomeDockGeometry(
      bounds: box.localToGlobal(Offset.zero) & box.size,
      capacity: _dockCapacity(),
    );
  }

  int _dockCapacity() => _uprightColumns;

  RenderBox? _boxOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  @override
  Offset globalToGrid(Offset global) =>
      _boxOf(_viewportKey)?.globalToLocal(global) ?? global;

  @override
  Rect gridToGlobal(Rect rect) {
    final box = _boxOf(_viewportKey);
    return box == null ? rect : rect.shift(box.localToGlobal(Offset.zero));
  }

  Rect _globalToSurface(Rect rect) {
    final surface = _boxOf(_surfaceKey);
    return surface == null
        ? rect
        : rect.shift(surface.globalToLocal(Offset.zero));
  }

  Rect _gridToSurface(Rect rect) {
    final surface = _boxOf(_surfaceKey);
    final global = gridToGlobal(rect);
    return surface == null
        ? global
        : global.shift(surface.globalToLocal(Offset.zero));
  }

  @override
  void turnPage(int direction) {
    final page = grid?.page ?? 0;
    final target = page + direction;
    if (target < 0) return;
    unawaited(
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  String folderNameFor(List<HomeGridItem> apps) {
    final l10n = context.l10n;
    Set<String> categoriesOf(HomeGridItem app) => {
      for (final category in [
        ...?app.app?.categories,
        ...?app.localApp?.categories,
      ])
        category.toLowerCase(),
    };
    final shared = apps.map(categoriesOf).reduce((a, b) => a.intersection(b));
    // Freedesktop main categories, most specific first.
    final names = <String, String>{
      'game': l10n.homeFolderGames,
      'development': l10n.homeFolderDevelopment,
      'graphics': l10n.homeFolderGraphics,
      'audiovideo': l10n.homeFolderMedia,
      'audio': l10n.homeFolderMedia,
      'video': l10n.homeFolderMedia,
      'office': l10n.homeFolderOffice,
      'network': l10n.homeFolderInternet,
      'education': l10n.homeFolderEducation,
      'science': l10n.homeFolderScience,
      'settings': l10n.homeFolderSettings,
      'system': l10n.homeFolderSystem,
      'utility': l10n.homeFolderUtilities,
    };
    for (final MapEntry(key: category, value: name) in names.entries) {
      if (shared.contains(category)) return name;
    }
    return l10n.homeFolderDefaultName;
  }

  // HomeInteractions ---------------------------------------------------------

  @override
  ValueListenable<Set<String>> get hiddenItems => _locator.hidden;

  @override
  void launch(HomeGridItem app, Rect iconRect) {
    if (_swallowTap || drag.active) return;
    unawaited(launchHomeApp(context, ref, app, iconRect));
  }

  @override
  void openFolder(HomeGridItem folder, Rect iconRect) {
    if (_swallowTap || drag.active) return;
    folders.show(folder.id, iconRect);
  }

  @override
  void hold(
    HomeGridItem item,
    int index,
    Rect tileRect,
    Offset pointer, {
    bool inFolder = false,
    bool inDock = false,
  }) {
    if (drag.active) return;
    if (item.resizable) {
      resize.enter(index);
      _heldWidget = (item: item, index: index, rect: tileRect, start: pointer);
      return;
    }
    resize.exit();
    drag.start(
      item: item,
      source: index,
      inFolder: inFolder,
      inDock: inDock,
      tileRect: tileRect,
      global: pointer,
    );
    _holdForMenu(
      HomeItemMenuRequest(
        item: item,
        place: inDock
            ? HomeItemPlace.dock
            : inFolder
            ? HomeItemPlace.folder
            : HomeItemPlace.grid,
        iconRect: HomeTileMetrics.iconRectIn(tileRect),
      ),
      pointer,
    );
  }

  // Menu and drawer ----------------------------------------------------------

  List<HomeItemAction> _actionsFor(HomeItemMenuRequest request) {
    final grid = this.grid;
    if (grid == null) return const [];
    return [
      for (final action in homeItemActions)
        if (action.appliesTo(request, grid)) action,
    ];
  }

  /// The menu shows while the finger rests; moving it on drags instead.
  void _holdForMenu(HomeItemMenuRequest request, Offset pointer) {
    _menuHold = pointer;
    _pendingMenu = request;
    _menuTimer?.cancel();
    _menuTimer = Timer(_menuDelay, () {
      _menuTimer = null;
      final pending = _pendingMenu;
      if (pending != null) _openMenu(pending);
    });
  }

  void _clearHold() {
    _menuHold = null;
    _pendingMenu = null;
    _drawerHold = null;
    _menuTimer?.cancel();
    _menuTimer = null;
  }

  /// Opens the menu for [request] when any option applies to it.
  bool _openMenu(HomeItemMenuRequest request) {
    if (_actionsFor(request).isEmpty) return false;
    _menu.value = request;
    return true;
  }

  void _select(HomeItemAction action) {
    final request = _menu.value;
    _menu.value = null;
    if (request != null) action.invoke(request, this);
  }

  bool _onMenu(Offset global) {
    final box = _menuKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  bool get _drawerShown => _drawer.value > 0;

  double get _height => _boxOf(_surfaceKey)?.size.height ?? 800;

  /// Settles the drawer open (1) or put away (0) on the system's springs,
  /// carrying the finger's speed in pixels a second downwards.
  void _settleDrawer(double target, {double velocity = 0}) {
    if (target == 0) _menu.value = null;
    final motion = target == 1
        ? ShellSprings.recentsOpen
        : ShellSprings.recentsClose;
    unawaited(
      _drawer.animateWith(
        motion.createSimulation(
          start: _drawer.value,
          end: target,
          velocity: -velocity / _height,
        ),
      ),
    );
  }

  void _closeDrawer() => _settleDrawer(0);

  /// The finger moved the drawer by [dy] pixels downwards.
  void _pullDrawer(double dy) {
    _drawer.value -= dy / _height;
  }

  /// Let go at [velocity] pixels a second downwards, the drawer goes where
  /// the finger sent it: a quarter of the way, or flung.
  void _releaseDrawer(double velocity, {required bool opening}) {
    final open = velocity < -_drawerFling
        ? true
        : velocity > _drawerFling
        ? false
        : opening
        ? _drawer.value > _drawerTravel
        : _drawer.value > 1 - _drawerTravel;
    _settleDrawer(open ? 1 : 0, velocity: velocity);
  }

  void _launchFromDrawer(HomeGridItem app, Rect iconRect) {
    if (_swallowTap) return;
    unawaited(launchHomeApp(context, ref, app, iconRect));
  }

  void _holdInDrawer(HomeGridItem app, Rect iconRect, Offset pointer) {
    _holdForMenu(
      HomeItemMenuRequest(
        item: app,
        place: HomeItemPlace.drawer,
        iconRect: iconRect,
      ),
      pointer,
    );
    _drawerHold = (app: app, iconRect: iconRect);
  }

  /// The drawer gives way to home, and the app held in it goes with the
  /// finger: from where it is on home, or new to home.
  void _dragFromDrawer(HomeGridItem app, Rect iconRect, Offset start) {
    final grid = this.grid;
    if (grid == null) return;
    var source = -1;
    var inFolder = false;
    var inDock = false;
    final docked = grid.dock.indexWhere((item) => item.id == app.id);
    if (docked >= 0) {
      source = docked;
      inDock = true;
    } else {
      for (var index = 0; index < grid.slots.length; index++) {
        final item = grid.slots[index];
        if (item == null) continue;
        if (item.id == app.id ||
            item.folderApps.any((inside) => inside.id == app.id)) {
          source = index;
          inFolder = item.isFolder;
          break;
        }
      }
    }
    _closeDrawer();
    drag.start(
      item: app,
      source: source,
      inFolder: inFolder,
      inDock: inDock,
      fromDrawer: true,
      tileRect: Rect.fromCenter(
        center: iconRect.center,
        width: HomeTileMetrics.iconBox,
        height: HomeTileMetrics.iconBox,
      ),
      global: start,
    );
  }

  /// Tells the system Back action what home has open, innermost first.
  void _syncBack() {
    final VoidCallback? back = _menu.value != null
        ? () => _menu.value = null
        : _drawerShown
        ? _closeDrawer
        : folders.open.value != null
        ? folders.close
        : null;
    // Providers change outside the frame that changed home.
    scheduleMicrotask(() {
      if (mounted) ref.read(homeBackProvider.notifier).set(back);
    });
  }

  void _focusChanged() {
    final context = FocusManager.instance.primaryFocus?.context;
    _editing.value =
        context != null &&
        context.mounted &&
        context.findAncestorWidgetOfExactType<EditableText>() != null &&
        context.findAncestorStateOfType<_HomeSurfaceState>() == this;
  }

  bool get _canPullDrawer =>
      !drag.active && !resize.active && folders.open.value == null;

  void _drawerDragUpdate(DragUpdateDetails details) {
    if (!_canPullDrawer) return;
    _pullDrawer(details.primaryDelta ?? 0);
  }

  void _drawerDragEnd(DragEndDetails details) {
    if (!_drawerShown) return;
    _releaseDrawer(details.primaryVelocity ?? 0, opening: true);
  }

  // Input --------------------------------------------------------------------

  void _pointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _swallowTap = false;
    if (_menu.value != null && !_onMenu(event.position)) {
      // A press away from the menu only closes it.
      _menu.value = null;
      _swallowTap = true;
    }
    if (resize.active && !_onResizeFrame(event.position)) {
      resize.exit();
      _swallowTap = true;
    }
    final onBackground =
        !_swallowTap &&
        !resize.active &&
        !_drawerShown &&
        folders.open.value == null &&
        !_onItem(event.position);
    _taps.down(event, onBackground: onBackground);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _taps.move(event);
    final menuHold = _menuHold;
    if (menuHold != null && (event.position - menuHold).distance > _menuSlop) {
      final drawerHold = _drawerHold;
      _clearHold();
      _menu.value = null;
      if (drawerHold != null) {
        _dragFromDrawer(drawerHold.app, drawerHold.iconRect, menuHold);
      }
    }
    final held = _heldWidget;
    if (held != null &&
        !drag.active &&
        (event.position - held.start).distance > _widgetDragSlop) {
      _heldWidget = null;
      resize.exit();
      drag.start(
        item: held.item,
        source: held.index,
        inFolder: false,
        tileRect: held.rect,
        global: held.start,
      );
    }
    drag.move(event.position);
  }

  void _pointerUp(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _heldWidget = null;
    // A hold released where it began keeps its menu open, and the icon
    // goes back to its place.
    final keepsMenu = _menuHold != null;
    final pending = _pendingMenu;
    _clearHold();
    if (keepsMenu && pending != null && _menu.value == null) {
      _openMenu(pending);
    }
    if (drag.active) {
      if (!keepsMenu) drag.move(event.position);
      drag.end(cancelled: keepsMenu || event is PointerCancelEvent);
    }
    if (event is PointerUpEvent) {
      _taps.up(event);
    } else {
      _taps.reset();
    }
  }

  bool _onItem(Offset global) {
    if (dock?.bounds.contains(global) ?? false) return true;
    final grid = this.grid;
    final geometry = _geometry;
    if (grid == null || geometry == null) return false;
    final cell = geometry.cellAt(globalToGrid(global), grid.page);
    return cell != null &&
        HomeGridLayout.anchorForCell(cell, grid.slots) != null;
  }

  bool _onResizeFrame(Offset global) {
    final index = resize.target.value;
    final grid = this.grid;
    final geometry = _geometry;
    final item = index == null || grid == null ? null : grid.slots[index];
    if (geometry == null || item == null) return false;
    return gridToGlobal(geometry.itemRect(index!, item))
        .inflate(HomeResizeFrame.handleExtent / 2)
        .contains(global);
  }

  void _sleepFromDoubleTap() =>
      ref.read(referenceShellProvider.notifier).blankDisplays();

  void _pageChanged(int page) {
    resize.exit();
    gridController.setPage(page);
    drag.refresh();
  }

  void _layout(HomeGridGeometry geometry) {
    _geometry = geometry;
    if (geometry.orientation == HomeOrientation.portrait) {
      _uprightColumns = geometry.columns;
    }
    final grid = this.grid;
    if (grid == null || drag.active) return;
    if (geometry.orientation != gridController.orientation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          gridController.arrange(geometry.orientation, geometry.pageSize);
        }
      });
      return;
    }
    final last =
        HomeGridLayout.pageCountForSlots(grid.slots, geometry.pageSize) - 1;
    if (grid.page > last) {
      // The last page emptied: return to the one before it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) gridController.setPage(last);
      });
    }
  }

  /// The icon a window transition starts or ends on: in the open folder, or
  /// on the current page.
  HomeIconTarget? _iconFor(DenialWindow window) {
    final grid = this.grid;
    final geometry = _geometry;
    if (grid == null || geometry == null) return null;
    final launcher = ref.read(appLauncherProvider);
    bool shows(HomeGridItem app) =>
        launcherAppShowsWindow(app, window, launcher);

    final open = folders.open.value;
    final layout = folders.layout;
    if (open != null && layout != null) {
      final folder = grid.slots
          .where((item) => item?.id == open.id)
          .firstOrNull;
      final apps = folder?.folderApps ?? const <HomeGridItem>[];
      final position = apps.indexWhere(shows);
      if (position >= 0) {
        return HomeIconTarget(
          item: apps[position],
          rect: HomeTileMetrics.iconRectIn(layout.tileRect(position)),
        );
      }
    }

    final dock = this.dock;
    final docked = grid.dock.indexWhere(shows);
    if (dock != null && docked >= 0) {
      return HomeIconTarget(
        item: grid.dock[docked],
        rect: dock.iconRect(docked, grid.dock.length),
      );
    }

    final start = grid.page * geometry.pageSize;
    for (var index = start; index < start + geometry.pageSize; index++) {
      if (index >= grid.slots.length) break;
      final item = grid.slots[index];
      if (item == null) continue;
      if ((item.isApp && shows(item)) ||
          (item.isFolder && item.folderApps.any(shows))) {
        return HomeIconTarget(
          item: item,
          rect: gridToGlobal(
            HomeTileMetrics.iconRectIn(geometry.rectAt(index)),
          ),
        );
      }
    }
    return null;
  }

  // Building -----------------------------------------------------------------

  Widget? _content;
  List<HomeGridItem?>? _contentSlots;
  bool? _contentError;
  bool? _contentSideways;

  /// The same grid widget while its slots hold: visibility, interactivity and
  /// opacity changes then rebuild only the wrappers above it, not each tile.
  Widget _contentFor(
    List<HomeGridItem?>? slots,
    bool hasError, {
    required bool sideways,
  }) {
    if (_content == null ||
        !identical(slots, _contentSlots) ||
        hasError != _contentError ||
        sideways != _contentSideways) {
      _contentSlots = slots;
      _contentError = hasError;
      _contentSideways = sideways;
      final dock = HomeDock(key: _dockKey, capacity: _dockCapacity);
      _content = HomeInteractionScope(
        interactions: this,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: _contentPadding(sideways: sideways),
              child: HomePager(
                slots: slots,
                hasError: hasError,
                controller: _pages,
                viewportKey: _viewportKey,
                onLayout: _layout,
                onPageChanged: _pageChanged,
              ),
            ),
            Positioned.fill(
              child: HomeResizeFrame(
                geometry: () => _geometry,
                gridToLocal: _gridToSurface,
              ),
            ),
            if (sideways)
              Positioned(
                top: _top,
                bottom: _dockBottom,
                right: _dockSide,
                width: HomeDockGeometry.thickness,
                child: dock,
              )
            else
              Positioned(
                left: HomePager.inset - HomeDockGeometry.inset,
                right: HomePager.inset - HomeDockGeometry.inset,
                bottom: _dockBottom,
                height: HomeDockGeometry.thickness,
                child: dock,
              ),
            const Positioned.fill(child: HomeFolderPanel()),
            const Positioned.fill(child: HomeDragLayer()),
          ],
        ),
      );
    }
    return _content!;
  }

  @override
  Widget build(BuildContext context) {
    final contents = ref.watch(
      homeGridControllerProvider.select(
        (value) => (slots: value.asData?.value.slots, hasError: value.hasError),
      ),
    );
    final opacity = widget.contentOpacity;
    final size = MediaQuery.sizeOf(context);
    final content = _contentFor(
      contents.slots,
      contents.hasError,
      sideways: size.width > size.height,
    );
    final surface = Offstage(
      offstage: !widget.active,
      child: TickerMode(
        enabled: widget.active,
        child: IgnorePointer(
          ignoring: !widget.interactive,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            child: Stack(
              key: _surfaceKey,
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: HomeBackdropPainter(opacity: opacity)),
                // A swipe up anywhere on home pulls up the app drawer.
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragUpdate: _drawerDragUpdate,
                  onVerticalDragEnd: _drawerDragEnd,
                  child: opacity == null
                      ? content
                      : FadeSnapshot(opacity: opacity, child: content),
                ),
                HomeAppDrawer(
                  progress: _drawer,
                  onPull: _pullDrawer,
                  onRelease: (velocity) =>
                      _releaseDrawer(velocity, opening: false),
                  onLaunch: _launchFromDrawer,
                  onHold: _holdInDrawer,
                ),
                ValueListenableBuilder<HomeItemMenuRequest?>(
                  valueListenable: _menu,
                  builder: (context, request, _) {
                    final actions = request == null
                        ? const <HomeItemAction>[]
                        : _actionsFor(request);
                    if (request == null || actions.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return HomeItemMenu(
                      anchor: _globalToSurface(request.iconRect),
                      actions: actions,
                      onSelected: _select,
                      menuKey: _menuKey,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Home's own text fields type only while the shell takes the keyboard.
    return ValueListenableBuilder<bool>(
      valueListenable: _editing,
      builder: (context, editing, child) => ShellInputRegion(
        debugLabel: 'Home text field',
        active: editing,
        pointerPolicy: ShellPointerPolicy.none,
        keyboardPolicy: ShellKeyboardPolicy.capture,
        child: child!,
      ),
      child: surface,
    );
  }
}

/// A double tap on home's empty background locks the device and blanks the
/// screen.
class _BackgroundTaps {
  _BackgroundTaps({required this.onDoubleTap});

  final VoidCallback onDoubleTap;

  static const Duration _maxTapDuration = Duration(milliseconds: 260);
  static const Duration _maxInterval = Duration(milliseconds: 360);
  static const double _moveTolerance = 18;
  static const double _distanceTolerance = 72;

  Offset? _start;
  Duration? _startTime;
  bool _valid = false;
  Offset? _lastTap;
  Duration? _lastTapTime;
  DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);

  void down(PointerDownEvent event, {required bool onBackground}) {
    _start = event.position;
    _startTime = event.timeStamp;
    _valid = onBackground;
  }

  void move(PointerMoveEvent event) {
    final start = _start;
    if (start != null && (event.position - start).distance > _moveTolerance) {
      _valid = false;
    }
  }

  void up(PointerUpEvent event) {
    final startTime = _startTime;
    final isTap =
        _valid &&
        startTime != null &&
        event.timeStamp - startTime <= _maxTapDuration;
    _start = null;
    _startTime = null;
    _valid = false;
    if (!isTap) {
      _lastTap = null;
      _lastTapTime = null;
      return;
    }
    final lastTap = _lastTap;
    final lastTime = _lastTapTime;
    if (lastTap != null &&
        lastTime != null &&
        event.timeStamp - lastTime <= _maxInterval &&
        (event.position - lastTap).distance <= _distanceTolerance) {
      _lastTap = null;
      _lastTapTime = null;
      final now = DateTime.now();
      if (now.difference(_lastFired) >= const Duration(seconds: 1)) {
        _lastFired = now;
        onDoubleTap();
      }
      return;
    }
    _lastTap = event.position;
    _lastTapTime = event.timeStamp;
  }

  void reset() {
    _start = null;
    _startTime = null;
    _valid = false;
  }
}
