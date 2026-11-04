import 'dart:async';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../local_apps/local_flutter_application.dart';
import '../../platform/denial_bridge_provider.dart';
import '../../state/system_status.dart';
import '../launcher_providers.dart';
import '../models/desktop_app.dart';
import '../models/home_clock_info.dart';
import '../models/home_grid_item.dart';
import '../repositories/desktop_apps_repository.dart';
import '../repositories/home_layout_repository.dart';
import '../services/app_launcher.dart';
import 'home_grid_layout.dart';

final desktopAppsRepositoryProvider = Provider<DesktopAppsRepository>((ref) {
  return DesktopAppsRepository(paths: ref.watch(runtimePathsProvider));
});

final homeLayoutRepositoryProvider = Provider<HomeLayoutRepository>((ref) {
  return HomeLayoutRepository(paths: ref.watch(runtimePathsProvider));
});

final appLauncherProvider = Provider<AppLauncher>((ref) {
  return AppLauncher(bridge: ref.watch(denialBridgeProvider));
});

final homeGridControllerProvider =
    AsyncNotifierProvider<HomeGridController, HomeGridState>(
      HomeGridController.new,
    );

final homeClockProvider = Provider<HomeClockInfo>((ref) {
  final locale = HomeClockInfo.localeFromEnvironment(
    ref.watch(runtimePathsProvider).environment,
  );
  return HomeClockInfo.fromShell(
    now: ref.watch(clockProvider).value ?? DateTime.now(),
    locale: locale,
    power: ref.watch(effectivePowerStatusProvider),
  );
}, isAutoDispose: true);

class HomeGridState {
  HomeGridState({
    required List<HomeGridItem?> slots,
    List<HomeGridItem> dock = const [],
    Set<String> hidden = const {},
    List<HomeGridItem> catalog = const [],
    this.page = 0,
  }) : slots = List.unmodifiable(slots),
       dock = List.unmodifiable(dock),
       hidden = Set.unmodifiable(hidden),
       catalog = List.unmodifiable(catalog);

  HomeGridState._({
    required this.slots,
    required this.dock,
    required this.hidden,
    required this.catalog,
    required this.page,
  });

  final List<HomeGridItem?> slots;

  /// The apps in the dock below the pages, in order.
  final List<HomeGridItem> dock;

  /// The apps taken off home; the app drawer still lists them.
  final Set<String> hidden;

  /// Every installed app, on home or not.
  final List<HomeGridItem> catalog;
  final int page;

  /// Every application on home, folder contents and the dock included.
  Iterable<HomeGridItem> get apps sync* {
    yield* HomeGridLayout.appsIn(slots);
    yield* dock;
  }

  HomeGridState copyWith({
    List<HomeGridItem?>? slots,
    List<HomeGridItem>? dock,
    Set<String>? hidden,
    List<HomeGridItem>? catalog,
    int? page,
  }) {
    return HomeGridState._(
      slots: slots == null ? this.slots : List.unmodifiable(slots),
      dock: dock == null ? this.dock : List.unmodifiable(dock),
      hidden: hidden == null ? this.hidden : Set.unmodifiable(hidden),
      catalog: catalog == null ? this.catalog : List.unmodifiable(catalog),
      page: page ?? this.page,
    );
  }
}

class HomeGridController extends AsyncNotifier<HomeGridState> {
  static const Duration _periodicRefreshInterval = Duration(minutes: 5);
  static const Duration _visibleRefreshMinInterval = Duration(seconds: 45);
  static const Duration _filesystemRefreshDebounce = Duration(
    milliseconds: 200,
  );

  Timer? _desktopRefreshTimer;
  Timer? _activationRefreshTimer;
  Timer? _filesystemRefreshTimer;
  DesktopAppsWatcher? _desktopAppsWatcher;
  DateTime? _lastDesktopRefresh;
  bool _desktopRefreshInFlight = false;
  bool _desktopRefreshTriggersStarted = false;
  bool _desktopAppsDirty = false;
  bool _launcherActive = true;
  int _buildGeneration = 0;

  /// The orientation the slots are laid out for; null while they belong to
  /// whichever orientation the grid shows first.
  HomeOrientation? _orientation;

  /// Every orientation's saved layout, the shown one as of its last save.
  Map<HomeOrientation, List<HomeLayoutSlot?>> _layouts = {};

  @override
  Future<HomeGridState> build() async {
    final generation = ++_buildGeneration;
    _desktopRefreshTimer = null;
    _activationRefreshTimer = null;
    _filesystemRefreshTimer = null;
    _desktopAppsWatcher = null;
    _lastDesktopRefresh = null;
    _desktopRefreshInFlight = false;
    _desktopRefreshTriggersStarted = false;
    _desktopAppsDirty = false;
    _launcherActive = true;
    ref.onDispose(() {
      if (_buildGeneration == generation) {
        _buildGeneration++;
      }
      _activationRefreshTimer?.cancel();
      _activationRefreshTimer = null;
      _desktopRefreshTimer?.cancel();
      _desktopRefreshTimer = null;
      _filesystemRefreshTimer?.cancel();
      _filesystemRefreshTimer = null;
      unawaited(_desktopAppsWatcher?.dispose());
      _desktopAppsWatcher = null;
      _desktopRefreshTriggersStarted = false;
    });
    final appsRepository = ref.watch(desktopAppsRepositoryProvider);
    final layoutRepository = ref.watch(homeLayoutRepositoryProvider);
    final localApps = ref
        .watch(localFlutterApplicationRegistryProvider)
        .applications
        .toList(growable: false);
    try {
      final apps = await _loadApplications(appsRepository, reason: 'initial');
      final saved = await layoutRepository.readSavedLayouts();
      // Portrait first, which is where a phone starts.
      final orientation = HomeOrientation.values
          .where(saved.layouts.containsKey)
          .firstOrNull;
      final savedLayout = orientation == null
          ? saved.unassigned
          : saved.layouts[orientation];
      final catalog = HomeGridLayout.catalogFor(apps, localApps);
      final dock = HomeGridLayout.dockForApps(apps, localApps, saved.dock);
      final hidden = _installed(saved.hidden, catalog).difference(_idsOf(dock));
      final slots = HomeGridLayout.initialSlotsForApps(
        apps,
        localApps,
        savedLayout,
        exclude: {..._idsOf(dock), ...hidden},
      );
      HomeGridState loaded() => HomeGridState(
        slots: slots,
        dock: dock,
        hidden: hidden,
        catalog: catalog,
      );
      if (!_isBuildActive(generation)) {
        return loaded();
      }
      _orientation = orientation;
      _layouts = {...saved.layouts};
      _lastDesktopRefresh = DateTime.now();
      if (dock.length != saved.dock.length ||
          hidden.length != saved.hidden.length ||
          _savedLayoutNeedsRefresh(apps, localApps, savedLayout, slots, [
            ...dock,
            for (final id in hidden) ?_find(catalog, id),
          ])) {
        _save(slots, dock, hidden);
      }
      unawaited(_startDesktopRefreshTriggers(generation, appsRepository));
      return loaded();
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> refreshDesktopApps({String reason = 'manual'}) async {
    if (state.asData?.value == null) {
      return;
    }

    if (!_launcherActive && reason != 'manual') {
      return;
    }

    final lastRefresh = _lastDesktopRefresh;
    if (reason == 'launcher-visible' &&
        lastRefresh != null &&
        // A complete watcher already reports every top-level change, so
        // returning home spends no isolate rescanning unchanged entries.
        ((_desktopAppsWatcher?.complete ?? false) ||
            DateTime.now().difference(lastRefresh) <
                _visibleRefreshMinInterval)) {
      return;
    }

    if (_desktopRefreshInFlight) {
      return;
    }

    final generation = _buildGeneration;
    _desktopAppsDirty = false;
    _desktopRefreshInFlight = true;
    try {
      final apps = await _loadApplications(
        ref.read(desktopAppsRepositoryProvider),
        reason: reason,
      );
      if (!_isBuildActive(generation)) {
        return;
      }
      _lastDesktopRefresh = DateTime.now();
      final current = state.asData?.value;
      if (current == null) {
        return;
      }

      final currentApps = _appsByGridId(current.catalog);
      final refreshedApps = _appsByGridId(apps.map(HomeGridItem.app));

      final addedIds = refreshedApps.keys
          .where((id) => !currentApps.containsKey(id))
          .toList(growable: false);
      final removedIds = currentApps.keys
          .where((id) => !refreshedApps.containsKey(id))
          .toList(growable: false);
      final updatedIds = refreshedApps.keys
          .where(
            (id) =>
                currentApps.containsKey(id) &&
                !_sameDesktopApp(currentApps[id]!, refreshedApps[id]!),
          )
          .toList(growable: false);

      if (addedIds.isEmpty && removedIds.isEmpty && updatedIds.isEmpty) {
        return;
      }

      final localApps = ref
          .read(localFlutterApplicationRegistryProvider)
          .applications;
      final catalog = HomeGridLayout.catalogFor(apps, localApps);
      final dock = HomeGridLayout.dockForApps(
        apps,
        localApps,
        current.dock.map((app) => app.id),
      );
      final hidden = _installed(current.hidden, catalog);
      final slots = HomeGridLayout.refreshSlotsForApps(
        current.slots,
        apps,
        localApps,
        exclude: {..._idsOf(dock), ...hidden},
      );
      state = AsyncData(
        current.copyWith(
          slots: slots,
          dock: dock,
          hidden: hidden,
          catalog: catalog,
        ),
      );
      _save(slots, dock, hidden);
    } finally {
      if (_isBuildActive(generation)) {
        _desktopRefreshInFlight = false;
        if (_desktopAppsDirty && _launcherActive) {
          _scheduleFilesystemRefresh();
        }
      }
    }
  }

  void setLauncherActive(bool active) {
    if (_launcherActive == active) {
      return;
    }

    _launcherActive = active;
    _activationRefreshTimer?.cancel();
    _activationRefreshTimer = null;
    if (active) {
      if (_desktopAppsDirty) {
        _scheduleFilesystemRefresh();
        return;
      }
      final generation = _buildGeneration;
      _activationRefreshTimer = Timer(const Duration(milliseconds: 750), () {
        if (!_isBuildActive(generation)) {
          return;
        }
        _activationRefreshTimer = null;
        unawaited(refreshDesktopApps(reason: 'launcher-visible'));
      });
    }
  }

  Future<void> _startDesktopRefreshTriggers(
    int generation,
    DesktopAppsRepository repository,
  ) async {
    try {
      if (_desktopRefreshTriggersStarted) {
        return;
      }
      _desktopRefreshTriggersStarted = true;
      _desktopRefreshTimer = Timer.periodic(_periodicRefreshInterval, (_) {
        if (!_isBuildActive(generation) || !_launcherActive) {
          return;
        }
        unawaited(refreshDesktopApps(reason: 'timer'));
      });
      final watcher = await repository.watchApplications(
        onChanged: () {
          if (!_isBuildActive(generation)) {
            return;
          }
          _desktopAppsDirty = true;
          if (_launcherActive) {
            _scheduleFilesystemRefresh();
          }
        },
      );
      if (!_isBuildActive(generation) || !_desktopRefreshTriggersStarted) {
        await watcher.dispose();
        return;
      }
      _desktopAppsWatcher = watcher;
    } on Object {
      // Filesystem notifications are best effort. Keep the periodic timer as
      // the fallback when the platform cannot establish a watcher.
    }
  }

  void _scheduleFilesystemRefresh() {
    _filesystemRefreshTimer?.cancel();
    _filesystemRefreshTimer = Timer(_filesystemRefreshDebounce, () {
      _filesystemRefreshTimer = null;
      unawaited(refreshDesktopApps(reason: 'filesystem'));
    });
  }

  bool _isBuildActive(int generation) =>
      ref.mounted && generation == _buildGeneration;

  Future<List<DesktopApp>> _loadApplications(
    DesktopAppsRepository repository, {
    required String reason,
  }) {
    return Isolate.run(
      repository.loadApplications,
      debugName: 'denia-launcher-desktop-$reason',
    );
  }

  /// The orientation the grid shows, null before it first lays out.
  HomeOrientation? get orientation => _orientation;

  /// Lays the grid out for [orientation], in pages of [pageSize]: its saved
  /// layout, or the shown one reflowed into the new pages when it has none.
  void arrange(HomeOrientation orientation, int pageSize) {
    final current = state.asData?.value;
    final shown = _orientation;
    if (current == null || orientation == shown) {
      return;
    }
    _orientation = orientation;
    if (shown == null) {
      // The slots are this orientation's layout from now on.
      _save(current.slots, current.dock, current.hidden);
      return;
    }

    _layouts[shown] = _layoutOf(current.slots);
    final saved = _layouts[orientation];
    final slots = saved == null
        ? HomeGridLayout.reflowSlots(current.slots, pageSize)
        : HomeGridLayout.initialSlotsForApps(
            [for (final item in current.apps) ?item.app],
            ref.read(localFlutterApplicationRegistryProvider).applications,
            saved,
            exclude: {..._idsOf(current.dock), ...current.hidden},
          );
    state = AsyncData(current.copyWith(slots: slots));
    _save(slots, current.dock, current.hidden);
  }

  void setPage(int page) {
    final current = state.asData?.value;
    if (current == null || current.page == page) {
      return;
    }

    state = AsyncData(current.copyWith(page: page));
  }

  bool canMoveSlot(int fromIndex, int toIndex, int pageSize) {
    final slots = state.asData?.value.slots;
    return slots != null &&
        HomeGridLayout.canMoveSlot(slots, fromIndex, toIndex, pageSize);
  }

  void moveSlot(int fromIndex, int toIndex, int pageSize) {
    _update(
      (slots) => HomeGridLayout.moveSlot(slots, fromIndex, toIndex, pageSize),
    );
  }

  bool canResizeSlot(
    int index,
    int anchor,
    int colSpan,
    int rowSpan,
    int pageSize,
  ) {
    final slots = state.asData?.value.slots;
    return slots != null &&
        HomeGridLayout.canResizeSlot(
          slots,
          index,
          anchor,
          colSpan,
          rowSpan,
          pageSize,
        );
  }

  void resizeSlot(
    int index,
    int anchor,
    int colSpan,
    int rowSpan,
    int pageSize,
  ) {
    _update(
      (slots) => HomeGridLayout.resizeSlot(
        slots,
        index,
        anchor,
        colSpan,
        rowSpan,
        pageSize,
      ),
    );
  }

  bool canMerge(int fromIndex, int targetIndex) {
    final slots = state.asData?.value.slots;
    return slots != null &&
        HomeGridLayout.canMerge(slots, fromIndex, targetIndex);
  }

  /// Drops the app at [fromIndex] on the app or folder at [targetIndex]. A
  /// new folder is named [folderName].
  void merge(int fromIndex, int targetIndex, {required String folderName}) {
    _update(
      (slots) => HomeGridLayout.merge(
        slots,
        fromIndex,
        targetIndex,
        folderId: HomeGridLayout.newFolderId(slots),
        folderName: folderName,
      ),
    );
  }

  void moveOutOfFolder(
    int folderIndex,
    String appId,
    int toIndex,
    int pageSize,
  ) {
    _update(
      (slots) => HomeGridLayout.moveOutOfFolder(
        slots,
        folderIndex,
        appId,
        toIndex,
        pageSize,
      ),
    );
  }

  void moveFromFolderInto(
    int folderIndex,
    String appId,
    int targetIndex, {
    required String folderName,
  }) {
    _update(
      (slots) => HomeGridLayout.moveFromFolderInto(
        slots,
        folderIndex,
        appId,
        targetIndex,
        folderId: HomeGridLayout.newFolderId(slots),
        folderName: folderName,
      ),
    );
  }

  void reorderFolder(int folderIndex, String appId, int position) {
    _update(
      (slots) =>
          HomeGridLayout.reorderFolder(slots, folderIndex, appId, position),
    );
  }

  void renameFolder(int folderIndex, String name) {
    _update((slots) => HomeGridLayout.renameFolder(slots, folderIndex, name));
  }

  /// Moves the app at grid [fromIndex] into the dock at [position]; a full
  /// dock of [capacity] trades it for the app there.
  void moveToDock(int fromIndex, int position, int capacity) {
    _updateWithDock(
      (slots, dock) =>
          HomeGridLayout.moveToDock(slots, dock, fromIndex, position, capacity),
    );
  }

  void moveFromFolderToDock(
    int folderIndex,
    String appId,
    int position,
    int capacity,
  ) {
    _updateWithDock(
      (slots, dock) => HomeGridLayout.moveFromFolderToDock(
        slots,
        dock,
        folderIndex,
        appId,
        position,
        capacity,
      ),
    );
  }

  void reorderDock(int from, int to) {
    _updateWithDock((slots, dock) {
      final next = HomeGridLayout.reorderDock(dock, from, to);
      return next == null ? null : (slots: slots, dock: next);
    });
  }

  void moveFromDock(int position, int toIndex) {
    _updateWithDock(
      (slots, dock) =>
          HomeGridLayout.moveFromDock(slots, dock, position, toIndex),
    );
  }

  /// Drops the dock's app at [position] on the app or folder at
  /// [targetIndex]. A new folder is named [folderName].
  void mergeFromDock(
    int position,
    int targetIndex, {
    required String folderName,
  }) {
    _updateWithDock(
      (slots, dock) => HomeGridLayout.mergeFromDock(
        slots,
        dock,
        position,
        targetIndex,
        folderId: HomeGridLayout.newFolderId(slots),
        folderName: folderName,
      ),
    );
  }

  /// Takes the app, or the folder and its apps, [id] off home. Its apps stay
  /// in the app drawer.
  void removeFromHome(String id) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    final next = HomeGridLayout.removeFromHome(current.slots, current.dock, id);
    if (next == null) {
      return;
    }
    final hidden = {...current.hidden, ...next.removed};
    state = AsyncData(
      current.copyWith(slots: next.slots, dock: next.dock, hidden: hidden),
    );
    _save(next.slots, next.dock, hidden);
  }

  /// Puts the app [id], taken off home before, back on its first free cell
  /// from [fromIndex] on.
  void addToHome(String id, int fromIndex) {
    final current = state.asData?.value;
    final app = current == null ? null : _find(current.catalog, id);
    if (current == null || app == null || !current.hidden.contains(id)) {
      return;
    }
    final slots = HomeGridLayout.placeItemAfter(current.slots, fromIndex, app);
    final hidden = {...current.hidden}..remove(id);
    state = AsyncData(current.copyWith(slots: slots, hidden: hidden));
    _save(slots, current.dock, hidden);
  }

  /// Puts the app [id], taken off home, on the free grid cell [index].
  void addToHomeAt(String id, int index) {
    _addHidden(id, (slots, dock, app) {
      final placed = HomeGridLayout.placeItemAt(slots, index, app);
      return identical(placed, slots) ? null : (slots: placed, dock: dock);
    });
  }

  /// Puts the app [id], taken off home, in the dock at [position], when the
  /// dock has room below [capacity].
  void addToDock(String id, int position, int capacity) {
    _addHidden(id, (slots, dock, app) {
      if (dock.length >= capacity) return null;
      return (
        slots: slots,
        dock: [...dock]..insert(position.clamp(0, dock.length), app),
      );
    });
  }

  /// Drops the app [id], taken off home, on the app or folder at
  /// [targetIndex]. A new folder is named [folderName].
  void addIntoFolder(String id, int targetIndex, {required String folderName}) {
    _addHidden(id, (slots, dock, app) {
      final next = HomeGridLayout.mergeFromDock(
        slots,
        [app],
        0,
        targetIndex,
        folderId: HomeGridLayout.newFolderId(slots),
        folderName: folderName,
      );
      return next == null ? null : (slots: next.slots, dock: dock);
    });
  }

  void _addHidden(
    String id,
    ({List<HomeGridItem?> slots, List<HomeGridItem> dock})? Function(
      List<HomeGridItem?> slots,
      List<HomeGridItem> dock,
      HomeGridItem app,
    )
    place,
  ) {
    final current = state.asData?.value;
    final app = current == null ? null : _find(current.catalog, id);
    if (current == null || app == null || !current.hidden.contains(id)) {
      return;
    }
    final next = place(current.slots, current.dock, app);
    if (next == null) {
      return;
    }
    final hidden = {...current.hidden}..remove(id);
    state = AsyncData(
      current.copyWith(slots: next.slots, dock: next.dock, hidden: hidden),
    );
    _save(next.slots, next.dock, hidden);
  }

  /// Applies one layout operation and saves its result; a null result is a
  /// change that was not possible.
  void _update(List<HomeGridItem?>? Function(List<HomeGridItem?> slots) edit) {
    _updateWithDock((slots, dock) {
      final next = edit(slots);
      return next == null ? null : (slots: next, dock: dock);
    });
  }

  void _updateWithDock(
    ({List<HomeGridItem?> slots, List<HomeGridItem> dock})? Function(
      List<HomeGridItem?> slots,
      List<HomeGridItem> dock,
    )
    edit,
  ) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    final next = edit(current.slots, current.dock);
    if (next == null) {
      return;
    }
    state = AsyncData(current.copyWith(slots: next.slots, dock: next.dock));
    _save(next.slots, next.dock, current.hidden);
  }

  /// Saves [slots] as the shown orientation's layout, beside the others,
  /// and the [dock] and [hidden] apps they share.
  void _save(
    List<HomeGridItem?> slots,
    List<HomeGridItem> dock,
    Set<String> hidden,
  ) {
    final layout = _layoutOf(slots);
    final dockIds = [for (final app in dock) app.id];
    final hiddenIds = hidden.toList(growable: false);
    final orientation = _orientation;
    if (orientation != null) {
      _layouts[orientation] = layout;
    }
    unawaited(
      ref
          .read(homeLayoutRepositoryProvider)
          .saveLayouts(
            orientation == null
                ? HomeSavedLayouts(
                    unassigned: layout,
                    dock: dockIds,
                    hidden: hiddenIds,
                  )
                : HomeSavedLayouts(
                    layouts: {..._layouts},
                    dock: dockIds,
                    hidden: hiddenIds,
                  ),
          ),
    );
  }
}

HomeGridItem? _find(List<HomeGridItem> catalog, String id) =>
    catalog.where((app) => app.id == id).firstOrNull;

/// The apps of [ids] still installed.
Set<String> _installed(Iterable<String> ids, List<HomeGridItem> catalog) {
  final installed = {for (final app in catalog) app.id};
  return {
    for (final id in ids)
      if (installed.contains(id)) id,
  };
}

Set<String> _idsOf(List<HomeGridItem> dock) => {for (final app in dock) app.id};

List<HomeLayoutSlot?> _layoutOf(List<HomeGridItem?> slots) => [
  for (final slot in slots) slot == null ? null : HomeLayoutSlot.of(slot),
];

Map<String, DesktopApp> _appsByGridId(Iterable<HomeGridItem> items) {
  return <String, DesktopApp>{for (final item in items) item.id: ?item.app};
}

bool _sameDesktopApp(DesktopApp a, DesktopApp b) {
  if (a.id != b.id ||
      a.name != b.name ||
      a.exec != b.exec ||
      a.desktopPath != b.desktopPath ||
      a.icon != b.icon ||
      a.iconPath != b.iconPath ||
      a.startupWmClass != b.startupWmClass ||
      a.categories.length != b.categories.length ||
      a.keywords.length != b.keywords.length) {
    return false;
  }

  for (var index = 0; index < a.categories.length; index += 1) {
    if (a.categories[index] != b.categories[index]) {
      return false;
    }
  }
  for (var index = 0; index < a.keywords.length; index += 1) {
    if (a.keywords[index] != b.keywords[index]) {
      return false;
    }
  }
  return true;
}

bool _savedLayoutNeedsRefresh(
  List<DesktopApp> apps,
  Iterable<LocalFlutterApplication> localApps,
  List<HomeLayoutSlot?>? savedLayout,
  List<HomeGridItem?> slots,
  List<HomeGridItem> dock,
) {
  if (savedLayout == null || savedLayout.length != slots.length) {
    return true;
  }

  final savedIds = <String>{
    for (final app in dock) app.id,
    for (final slot in savedLayout) ...?slot?.children,
    for (final slot in savedLayout) ?slot?.id,
  };
  if (savedIds.contains('widget:frame-time') ||
      savedIds.contains('widget:battery-discharge')) {
    return true;
  }

  final currentAppIds = <String>{
    for (final app in apps) 'app:${app.id}',
    for (final app in localApps) 'local:${app.id}',
  };
  if (!savedIds.containsAll(currentAppIds)) {
    return true;
  }

  return savedIds
      .where((id) => id.startsWith('app:') || id.startsWith('local:'))
      .any((id) => !currentAppIds.contains(id));
}
