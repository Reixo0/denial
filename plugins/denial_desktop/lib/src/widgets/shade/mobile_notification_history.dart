import 'dart:async' show Timer;

import 'package:denial_desktop/src/state/notification_groups.dart';
import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/unlock_then.dart';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart'
    show
        DesktopNotification,
        DesktopNotificationUrgency,
        NotificationPreviewMode;
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/rendering.dart'
    show WindowBackdropCache, WindowBackdropMotion;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;

import '../notification_banner.dart';
import '../notification_open.dart' show openNotificationFromShade;
import '../notification_rows.dart';
import '../phone_scheme.dart';
import 'notification_footer.dart';
import 'notification_shade_list.dart';
import 'notification_shelf.dart';
import 'magnetic_notification_swipe.dart';
import 'shade_card_blur.dart';
import 'quick_settings_panel.dart' show PixelShadeViewport;
import 'shade_dismiss_gesture.dart';
import 'shade_expansion.dart';
import 'shade_expansion_motion.dart' show androidDuration;
import 'shade_launch.dart' show openPhoneSettingsFromShade;
import 'shade_stack_layout.dart' show ShadeListScroll;

/// A separate scrollable notification stack for the notification page.
/// Only a completed close rearms the staggered entrance, never a drag reversal.
class MobileNotificationHistory extends ConsumerStatefulWidget {
  const MobileNotificationHistory({
    required this.progress,
    required this.closed,
    this.active = true,
    required this.expansion,
    this.topPadding = 0,
    this.scroll,
    super.key,
  });

  /// Where the notifications rest below the top of the list, which is the
  /// screen's: they scroll up from there over the quick tiles.
  final double topPadding;

  /// Told how far they have.
  final ShadeListScroll? scroll;

  final Animation<double> progress;

  /// The shade a drag on the list moves while it cannot scroll.
  final ShadeExpansion expansion;

  /// The shell is in its closed state (neither open nor actively dragging).
  /// The animation must also reach zero before the next entrance is armed.
  final bool closed;
  final bool active;

  @override
  ConsumerState<MobileNotificationHistory> createState() =>
      _MobileNotificationHistoryState();
}

class _MobileNotificationHistoryState
    extends ConsumerState<MobileNotificationHistory>
    with TickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  final _rowMotion = _RowMotion();
  late final _HistoryScrollPhysics _physics = _HistoryScrollPhysics(
    _ListShadeDrag(expansion: () => widget.expansion, scale: () => _scale),
  );
  late final NotificationClearAll _clearAll;
  late final MagneticNotificationSwipeManager _magnetic =
      MagneticNotificationSwipeManager(this);
  final GlobalKey _listKey = GlobalKey();
  int _rowCount = 0;
  NotificationShelfGeometry? _shelfGeometry;

  /// The same one while the shade's progress is.
  NotificationShelfGeometry get _shelf {
    final shelf = _shelfGeometry;
    if (shelf != null && identical(shelf.progress, widget.progress)) {
      return shelf;
    }
    return _shelfGeometry = NotificationShelfGeometry(
      list: () => _listKey.currentContext?.findRenderObject() as RenderBox?,
      rows: () => _clearAll.boxes,
      count: () => _rowCount,
      progress: widget.progress,
      topPadding: () => widget.topPadding,
      keyguard: _keyguardEnd,
      lastKept: _lastKept,
    );
  }

  /// Opening over the lock screen: 1 while the stack still ends as the lock
  /// screen's, down to 0 once the shade is open ([NotificationShelfGeometry.keyguard]).
  late final AnimationController _keyguardEnd = AnimationController(
    vsync: this,
  );

  /// The rows and groups of the last build.
  List<NotificationHistoryRow> _rows = const <NotificationHistoryRow>[];
  List<DesktopNotificationGroup> _groups = const <DesktopNotificationGroup>[];

  /// The last row the lock screen shows as a card, read when needed: the
  /// lock screen tells which after it has laid out, maybe after this built.
  int? _lastKept() {
    final kept = LockShadeHandover.kept;
    if (kept.isEmpty) return null;
    int? last;
    for (final (index, row) in _rows.indexed) {
      final shows = switch (row) {
        NotificationGroupRow(:final group) => kept.contains(group.key),
        NotificationRow(:final record) => _groups.any(
          (group) =>
              kept.contains(group.key) && identical(group.newest, record),
        ),
        NotificationGroupHeaderRow() => false,
      };
      if (shows) last = index;
    }
    return last;
  }

  Animation<double>? _motionProgress;
  Listenable? _motion;
  bool _armed = true;

  /// Bumped each time the shade closes. The rows start collapsed again:
  /// Android resets what the user expanded and folds the groups then.
  int _generation = 0;
  bool _acknowledgeScheduled = false;

  @override
  void initState() {
    super.initState();
    _clearAll = NotificationClearAll(this);
    widget.scroll?.attach(_scroll);
    widget.progress.addListener(_observeProgress);
  }

  /// Android closes the shade 200 ms after the rows have left.
  void _closeAfterClear() {
    Future<void>.delayed(androidDuration(200), () {
      if (!mounted) return;
      ref.read(referenceShellProvider.notifier).closeQuickSettings();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observeProgress();
  }

  @override
  void didUpdateWidget(covariant MobileNotificationHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scroll, widget.scroll)) {
      oldWidget.scroll?.detach(_scroll);
      widget.scroll?.attach(_scroll);
    }
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_observeProgress);
      widget.progress.addListener(_observeProgress);
    }
    _observeProgress();
  }

  void _observeProgress() {
    final p = widget.progress.value;
    LockShadeHandover.follow(p);
    if (LockShadeHandover.active) {
      if (_keyguardEnd.value != 1) _keyguardEnd.value = 1;
    } else if (p <= 0) {
      if (_keyguardEnd.value != 0) _keyguardEnd.value = 0;
    } else if (p >= 1 && _keyguardEnd.value > 0 && !_keyguardEnd.isAnimating) {
      // In the locked shade: the rest come out of the shelf.
      _keyguardEnd.animateTo(
        0,
        duration: androidDuration(448),
        curve: Curves.fastOutSlowIn,
      );
    }
    if (widget.closed && widget.progress.value <= 0) {
      if (!_armed) _collapseOnClose();
      _armed = true;
    }
    if (_armed && widget.progress.value > 0) {
      _armed = false;
    }
    _scheduleAcknowledgement();
  }

  /// The notifications' bottom, the panel's travel. The list keeps what
  /// Android's stack leaves at the screen's bottom in its own extent.
  void _onExtent(double bottom) => widget.expansion.contentBottom =
      (bottom - NotificationShelfGeometry.bottomMargin) * _scale;

  /// Logical pixels per dp.
  double _scale = 1;

  void _collapseOnClose() {
    // Not during a build: the groups are shared state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _magnetic.reset();
      ref.read(expandedNotificationGroupsProvider.notifier).collapseAll();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      setState(() => _generation++);
    });
  }

  /// Android's isShadeFullyExpanded.
  bool get _fullyOpen => widget.active && widget.progress.value >= 0.999;

  void _scheduleAcknowledgement() {
    // The seen time starts over each time the shade opens fully.
    if (!_fullyOpen) {
      _seenTimer?.cancel();
      _seenTimer = null;
    }
    if (_acknowledgeScheduled || !widget.active || widget.progress.value <= 0) {
      return;
    }
    _acknowledgeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _acknowledgeScheduled = false;
      // Over the lock screen too: Android counts what the locked shade
      // showed as seen.
      if (!mounted || !widget.active || widget.progress.value <= 0) {
        return;
      }
      final state = ref.read(desktopNotificationsProvider);
      final controller = ref.read(desktopNotificationsProvider.notifier);
      // A notification already shown in the drawer must not pop up again
      // when the drawer closes. Its history and active actions remain intact.
      for (final id in state.bannerQueue) {
        controller.hideBanner(id);
      }
      // LockScreenMinimalismCoordinator: what the shade showed fully open
      // for SHADE_VISIBLE_SEEN_TIMEOUT (0.25 s) has been seen.
      if (!_fullyOpen) return;
      _seenTimer ??= Timer(const Duration(milliseconds: 250), () {
        _seenTimer = null;
        if (mounted && _fullyOpen) {
          ref.read(desktopNotificationsProvider.notifier).markAllRead();
        }
      });
    });
  }

  Timer? _seenTimer;

  /// Everything that moves a card on screen without repainting it, for the
  /// cached glass slices: the shade, the entrance, scrolling, and row layout
  /// or dismissal. The same merge while the shade progress is unchanged.
  Listenable _motionFor(Animation<double> progress) {
    if (!identical(progress, _motionProgress)) {
      _motionProgress = progress;
      _motion = Listenable.merge([
        progress,
        _scroll,
        _rowMotion,
        _magnetic,
        _keyguardEnd,
      ]);
    }
    return _motion!;
  }

  @override
  Widget build(BuildContext context) {
    _scale = PixelShadeViewport.scaleOf(context);
    final state = ref.watch(desktopNotificationsProvider);
    final cachedGlass =
        context.shellTheme.effectivePanelOpacity < 1 &&
        WindowBackdropCache.maybeOf(context) != null;
    final controller = ref.read(desktopNotificationsProvider.notifier);
    final locked = ref.watch(
      referenceShellProvider.select((state) => state.lockLayerVisible),
    );
    final preview = locked ? state.lockPreview : NotificationPreviewMode.full;
    final groups = preview == NotificationPreviewMode.hidden
        ? const <DesktopNotificationGroup>[]
        : state.groups;
    // Locked, the shade's rows work as on an unlocked phone (Android's
    // SHADE_LOCKED is not on the keyguard): they swipe away, groups open,
    // and Clear all shows. Whatever opens something asks for the unlock
    // first and then carries on from the shade.
    final expandedGroups = ref.watch(expandedNotificationGroupsProvider);
    final unlockThen = ref.read(unlockThenProvider.notifier);
    // Android's sections: alerting notifications first, then the silent
    // ones (Droidloom passes Android's low importance as low urgency) under
    // their heading, each section its own stack.
    bool silent(DesktopNotificationGroup group) => group.members.every(
      (record) => record.notification.urgency == DesktopNotificationUrgency.low,
    );
    // An open group stays one row, drawn as Android's one card.
    final alertingRows = notificationHistoryRows(
      groups.where((group) => !silent(group)).toList(),
      const <String>{},
    );
    final silentRows = notificationHistoryRows(
      groups.where(silent).toList(),
      const <String>{},
    );
    // The app grows out of the row (startActivityDismissingKeyguard with
    // the row's launch animation, after the unlock on a locked phone).
    void open(DesktopNotificationRecord record) => unlockThen.run(
      () => openNotificationFromShade(ref, record.notification.id),
    );

    // An app's action may open it, so a locked phone unlocks first
    // (StatusBarRemoteInputCallback asks for the unlock for activities;
    // Denial cannot tell them apart).
    void action(DesktopNotificationRecord record, String key) => unlockThen.run(
      () => controller.invokeAction(record.notification.id, key),
    );

    void control(DesktopNotificationRecord record, String control) =>
        unlockThen.run(() {
          controller.invokeControl(record.notification.id, control);
          // The app's settings open over the apps.
          if (control == 'x-denial-settings') {
            ref.read(referenceShellProvider.notifier).closeQuickSettings();
          }
        });

    // One notification inside an open group's card.
    Widget member(DesktopNotificationRecord record) {
      final clearable = record.notification.clearable;
      return MagneticSingleSwipeRow(
        key: ValueKey<Object>(('member', record.notification.id)),
        clearable: clearable,
        onDismiss: () => controller.dismissFromHistory(record.notification.id),
        child: PixelNotificationCard(
          notification: record.notification,
          embedded: true,
          previewMode: preview,
          onOpen: () => open(record),
          onAction: (key) => action(record, key),
          onDismiss: clearable
              ? () => controller.dismissFromHistory(record.notification.id)
              : null,
          onControl: (value) => control(record, value),
        ),
      );
    }

    final rows = <NotificationHistoryRow>[...alertingRows, ...silentRows];
    final silentStart = silentRows.isEmpty ? -1 : alertingRows.length;
    _rows = rows;
    _groups = groups;
    _magnetic.syncSections([
      for (var i = 0; i < rows.length; i++)
        if (rows[i] is! NotificationGroupHeaderRow)
          (i, silentStart >= 0 && i >= silentStart ? 1 : 0),
    ]);
    final silentAllClearable = groups
        .where(silent)
        .every((group) => group.clearable);
    _rowCount = rows.length;
    final indices = <Object, int>{
      for (var i = 0; i < rows.length; i++) rows[i].key: i,
    };
    _scheduleAcknowledgement();
    // Clamping physics only installs a scroll drag recognizer when content
    // actually overflows. Otherwise the parent moves the shade with the finger.
    return ShadeDismissGesture(
      expansion: widget.expansion,
      canDrag: () =>
          _scroll.hasClients &&
          _scroll.position.hasContentDimensions &&
          _scroll.position.maxScrollExtent <= _scroll.position.minScrollExtent,
      child: WindowBackdropMotion(
        motion: _motionFor(widget.progress),
        child: Stack(
          key: _listKey,
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: <Widget>[
            ClipRect(
              clipper: NotificationShelfClipper(
                _shelf,
                motion: _motionFor(widget.progress),
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: _physics.drag.onScroll,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: CustomScrollView(
                    key: const PageStorageKey('mobile-notification-history'),
                    controller: _scroll,
                    physics: _physics,
                    primary: false,
                    clipBehavior: Clip.none,
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.only(top: widget.topPadding),
                        sliver: NotificationShadeList(
                          topPadding: widget.topPadding,
                          progress: widget.progress,
                          entrance: kAlwaysCompleteAnimation,
                          opaqueRows: cachedGlass,
                          onRowsMoved: _rowMotion.moved,
                          onExtent: _onExtent,
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              if (index == rows.length) {
                                return Padding(
                                  // EvolutionX: the pill starts 18 dp below the last
                                  // row, whose own gap is 8 dp; 4 dp are the pill's.
                                  padding: const EdgeInsets.only(
                                    top: 6,
                                    bottom: 16,
                                  ),
                                  child: Builder(
                                    builder: (context) =>
                                        NotificationReveal.revealed(
                                          context,
                                          NotificationFooterFade(
                                            geometry: _shelf,
                                            motion: _motionFor(widget.progress),
                                            child: NotificationFooter(
                                              clearAll: _clearAll,
                                              onSettings: () => ref
                                                  .read(
                                                    unlockThenProvider.notifier,
                                                  )
                                                  .run(
                                                    () =>
                                                        openPhoneSettingsFromShade(
                                                          ref,
                                                          'notifications',
                                                        ),
                                                  ),
                                              onCleared: _closeAfterClear,
                                            ),
                                          ),
                                        ),
                                  ),
                                );
                              }
                              final row = rows[index];
                              final key = ValueKey<Object>((
                                row.key,
                                _generation,
                              ));
                              // Neighbouring cards form one stack, as Android's do.
                              bool card(int i) =>
                                  i >= 0 &&
                                  i < rows.length &&
                                  rows[i] is! NotificationGroupHeaderRow;
                              final roundTop =
                                  !card(index - 1) || index == silentStart;
                              final roundBottom =
                                  !card(index + 1) || index + 1 == silentStart;
                              final Widget entry = switch (row) {
                                NotificationGroupHeaderRow(:final group) =>
                                  _HistoryGroupHeader(
                                    key: key,
                                    group: group,
                                    onCollapse: () => ref
                                        .read(
                                          expandedNotificationGroupsProvider
                                              .notifier,
                                        )
                                        .collapse(group.key),
                                  ),
                                NotificationGroupRow(:final group) =>
                                  _HistoryNotification(
                                    key: key,
                                    expansion: widget.progress,
                                    shelf: _shelf,
                                    motion: _motionFor(widget.progress),
                                    magnetic: _magnetic,
                                    section:
                                        silentStart >= 0 && index >= silentStart
                                        ? 1
                                        : 0,
                                    index: index,
                                    record: group.newest,
                                    group: group,
                                    roundTop: roundTop,
                                    roundBottom: roundBottom,
                                    preview: preview,
                                    interactive: true,
                                    onDismiss: () => controller
                                        .dismissGroupFromHistory(group.key),
                                    expanded: expandedGroups.contains(
                                      group.key,
                                    ),
                                    member: member,
                                    onExpand: () => ref
                                        .read(
                                          expandedNotificationGroupsProvider
                                              .notifier,
                                        )
                                        .expand(group.key),
                                    onCollapse: () => ref
                                        .read(
                                          expandedNotificationGroupsProvider
                                              .notifier,
                                        )
                                        .collapse(group.key),
                                  ),
                                NotificationRow(:final record) =>
                                  _HistoryNotification(
                                    key: key,
                                    expansion: widget.progress,
                                    shelf: _shelf,
                                    motion: _motionFor(widget.progress),
                                    magnetic: _magnetic,
                                    section:
                                        silentStart >= 0 && index >= silentStart
                                        ? 1
                                        : 0,
                                    index: index,
                                    record: record,
                                    roundTop: roundTop,
                                    roundBottom: roundBottom,
                                    preview: preview,
                                    interactive: true,
                                    onDismiss: () =>
                                        controller.dismissFromHistory(
                                          record.notification.id,
                                        ),
                                    onOpen: () => open(record),
                                    onAction: (key) => action(record, key),
                                    onControl: (value) =>
                                        control(record, value),
                                  ),
                              };
                              final clearable = switch (row) {
                                NotificationGroupHeaderRow() => false,
                                NotificationGroupRow(:final group) =>
                                  group.clearable,
                                NotificationRow(:final record) =>
                                  record.notification.clearable,
                              };
                              final slide = NotificationClearSlide(
                                key: ValueKey<Object>((
                                  'slide',
                                  row.key,
                                  _generation,
                                )),
                                clearAll: _clearAll,
                                index: index,
                                clearable: clearable,
                                child: entry,
                              );
                              return index == silentStart
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        // Leaves with the section when all of it goes.
                                        NotificationClearFade(
                                          clearAll: _clearAll,
                                          fades: silentAllClearable,
                                          child: const _SilentSectionHeader(),
                                        ),
                                        slide,
                                      ],
                                    )
                                  : slide;
                            },
                            childCount: rows.length + (rows.isNotEmpty ? 1 : 0),
                            findChildIndexCallback: (key) =>
                                key is ValueKey &&
                                    indices.containsKey(key.value)
                                ? indices[key.value]
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            NotificationShelf(
              geometry: _shelf,
              motion: _motionFor(widget.progress),
              notifications: <DesktopNotification>[
                for (final row in rows)
                  switch (row) {
                    NotificationGroupHeaderRow(:final group) =>
                      group.newest.notification,
                    NotificationGroupRow(:final group) =>
                      group.newest.notification,
                    NotificationRow(:final record) => record.notification,
                  },
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _seenTimer?.cancel();
    widget.progress.removeListener(_observeProgress);
    widget.scroll?.detach(_scroll);
    _clearAll.dispose();
    _magnetic.dispose();
    _scroll.dispose();
    _rowMotion.dispose();
    _keyguardEnd.dispose();
    super.dispose();
  }
}

class _RowMotion extends ChangeNotifier {
  void moved() => notifyListeners();
}

class _HistoryNotification extends StatelessWidget {
  const _HistoryNotification({
    required this.expansion,
    required this.shelf,
    required this.motion,
    required this.magnetic,
    required this.section,
    required this.index,
    required this.record,
    required this.preview,
    required this.interactive,
    required this.onDismiss,
    this.roundTop = true,
    this.roundBottom = true,
    this.onOpen,
    this.onAction,
    this.onControl,
    this.group,
    this.expanded = false,
    this.member,
    this.onExpand,
    this.onCollapse,
    super.key,
  });

  /// The shade's expansion: below 1 the card shows only
  /// [AndroidStackExpansion.squish] of its height, as Android's rows do.
  final Animation<double> expansion;

  /// Where the stack ends, and everything that moves the rows against it.
  final NotificationShelfGeometry shelf;
  final Listenable motion;
  final MagneticNotificationSwipeManager magnetic;
  final int section;
  final int index;
  final DesktopNotificationRecord record;
  final bool roundTop;
  final bool roundBottom;
  final NotificationPreviewMode preview;
  final bool interactive;
  final bool Function() onDismiss;
  final VoidCallback? onOpen;
  final ValueChanged<String>? onAction;
  final ValueChanged<String>? onControl;

  /// A stacked group this row stands for, collapsed; a tap runs [onExpand].
  final DesktopNotificationGroup? group;

  /// The [group] is open: one card with a row per notification ([member]).
  final bool expanded;
  final Widget Function(DesktopNotificationRecord record)? member;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final notification = record.notification;
    final group = this.group;
    // A pull on a folded group opens it with the finger (ExpandHelper on a
    // group: its lines turn into its rows); so does a tap.
    final Widget content =
        group != null &&
            group.stacked &&
            member != null &&
            preview == NotificationPreviewMode.full
        ? PixelNotificationGroupCard(
            group: group,
            row: member!,
            open: expanded,
            onOpen: (open) => (open ? onExpand : onCollapse)?.call(),
            interactive: interactive,
            roundTop: roundTop,
            roundBottom: roundBottom,
          )
        : PixelNotificationCard(
            notification: notification,
            interactive: interactive,
            previewMode: preview,
            roundTop: roundTop,
            roundBottom: roundBottom,
            group: group,
            onExpandGroup: onExpand,
            onOpen: onOpen,
            onAction: onAction,
            onDismiss: group == null && interactive && notification.clearable
                ? onDismiss
                : null,
            onControl: group == null ? onControl : null,
          );
    final clearable =
        interactive && (group?.clearable ?? notification.clearable);
    final clipper = _SquishClipper(
      expansion,
      BorderRadius.vertical(
        top: Radius.circular(
          roundTop
              ? PixelNotificationMetrics.radius
              : PixelNotificationMetrics.innerRadius,
        ),
        bottom: Radius.circular(
          roundBottom
              ? PixelNotificationMetrics.radius
              : PixelNotificationMetrics.innerRadius,
        ),
      ),
      shelf,
      index,
      magnetic: magnetic,
      motion: motion,
    );
    return MagneticSwipeRow(
      manager: magnetic,
      index: index,
      section: section,
      clearable: clearable,
      onDismiss: onDismiss,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: roundBottom ? 8 : PixelNotificationMetrics.divider,
        ),
        child: Semantics(
          onDismiss: clearable
              ? () {
                  onDismiss();
                }
              : null,
          child: ShadeCard(
            shape: clipper.getClip,
            motion: motion,
            child: ClipRRect(clipper: clipper, child: content),
          ),
        ),
      ),
    );
  }
}

/// A card cut to [AndroidStackExpansion.squish] of its height, keeping its
/// corners: Android shortens a row's actual height while the shade moves.
/// Near the stack's end the shelf rounds and cuts it.
class _SquishClipper extends CustomClipper<RRect> {
  _SquishClipper(
    this.expansion,
    this.radius,
    this.shelf,
    this.index, {
    required this.magnetic,
    required Listenable motion,
  }) : super(reclip: motion);

  final Animation<double> expansion;
  final BorderRadius radius;
  final NotificationShelfGeometry shelf;
  final int index;
  final MagneticNotificationSwipeManager magnetic;

  @override
  RRect getClip(Size size) {
    final top = magnetic.topRadiusFor(index, radius.topLeft.x);
    final bottom = magnetic.bottomRadiusFor(index, radius.bottomLeft.x);
    final resolved = BorderRadius.vertical(
      top: Radius.circular(top),
      bottom: Radius.circular(bottom),
    );
    final frame = shelf.read();
    if (frame != null) return frame.clipRow(index, size, resolved);
    final squish = AndroidStackExpansion.squish(expansion.value);
    return resolved.toRRect(
      Offset.zero & Size(size.width, size.height * squish),
    );
  }

  @override
  bool shouldReclip(_SquishClipper oldClipper) =>
      oldClipper.radius != radius ||
      oldClipper.expansion != expansion ||
      oldClipper.shelf != shelf ||
      oldClipper.index != index ||
      !identical(oldClipper.magnetic, magnetic);
}

/// Android's "Silent" heading over the low-importance stack (SystemUI's
/// status_bar_notification_section_header.xml: 48 dp, 14 sp
/// title-small-emphasized in onSurface; the label sits about 13 dp in, as
/// on EvolutionX).
class _SilentSectionHeader extends StatelessWidget {
  const _SilentSectionHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    // 48 dp, plus 14 dp so the gap from the stack above is EvolutionX's
    // 70 dp, the label centred 45 dp below it.
    return SizedBox(
      height: 62,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 14, top: 12),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            context.l10n.notificationSectionSilent,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Above an opened group's members: its app and count, and a button that
/// folds it back into one card.
class _HistoryGroupHeader extends StatelessWidget {
  const _HistoryGroupHeader({
    required this.group,
    required this.onCollapse,
    super.key,
  });

  final DesktopNotificationGroup group;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final appName = notificationAppName(group.newest.notification, l10n);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 16, top: 4),
      child: Builder(
        builder: (context) => NotificationReveal.revealed(
          context,
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.notificationGroupHeader(appName, group.members.length),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShellText.base.copyWith(
                    color: context.shellColors.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ),
              _HistoryButton(
                label: l10n.notificationGroupCollapse(appName),
                icon: Icons.expand_less_rounded,
                onPressed: onCollapse,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              icon,
              color: context.shellColors.textSecondary,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

/// Avoid inheriting an always-scrollable platform physics for a short history.
/// The presence of a vertical scroll recognizer must match actual overflow.
/// A drag on the list that moves the shade instead, as Android's panel
/// takes it over: up from the list's end it closes the shade
/// (canCollapsePanelOnTouch), down past its top it opens the full quick
/// settings. Pushed past its end by a scroll the list gives a little and
/// springs back.
class _ListShadeDrag {
  _ListShadeDrag({required this.expansion, required this.scale});

  final ShadeExpansion Function() expansion;

  /// Logical pixels per dp of the list.
  final double Function() scale;

  bool _first = true;
  bool _closing = false;
  bool _holds = false;

  bool onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _first = true;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails == null &&
        notification.overscroll > 0) {
      expansion().flingOverscroll(notification.velocity);
    }
    return false;
  }

  /// The finger moved [offset] dp (down is positive); what of it scrolls.
  double move(ScrollMetrics position, double offset) {
    if (offset == 0) return 0;
    final shade = expansion();
    final first = _first;
    _first = false;
    if (_holds) {
      if (_closing || offset > 0 || shade.qs.value > 0) {
        shade.dragBy(offset * scale());
        return 0;
      }
      // The quick settings are back: the list scrolls on.
      _release(0);
      return offset;
    }
    final fromEnd = position.pixels >= position.maxScrollExtent - 0.5;
    if (offset < 0) {
      if (first && fromEnd && shade.beginDrag()) {
        _holds = true;
        _closing = true;
        shade.dragBy(offset * scale());
        return 0;
      }
      final past = position.pixels - offset - position.maxScrollExtent;
      if (past <= 0) return offset;
      shade.overscrollBy(past);
      return offset + past;
    }
    if (shade.overscroll.value > 0) {
      final left = shade.takeOverscroll(offset);
      if (left <= 0) return 0;
      offset = left;
    }
    if (position.pixels <= position.minScrollExtent && shade.beginDrag()) {
      _holds = true;
      _closing = false;
      shade.dragBy(offset * scale());
      return 0;
    }
    return offset;
  }

  void _release(double velocity) {
    _holds = false;
    expansion().endDrag(velocity * scale());
  }

  /// Let go at [velocity] dp/s, up is positive; true when the list is not
  /// to go on by itself.
  bool end(ScrollMetrics position, double velocity) {
    if (_holds) {
      _release(-velocity);
      return true;
    }
    final shade = expansion();
    if (shade.overscroll.value > 0 && !shade.overscroll.isAnimating) {
      if (velocity > 0) {
        shade.flingOverscroll(velocity, pushed: true);
        return true;
      }
      shade.releaseOverscroll();
    }
    return false;
  }
}

class _HistoryScrollPhysics extends ClampingScrollPhysics {
  const _HistoryScrollPhysics(this.drag, {super.parent});

  final _ListShadeDrag drag;

  @override
  _HistoryScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _HistoryScrollPhysics(drag, parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      position.maxScrollExtent > position.minScrollExtent;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      super.applyPhysicsToUserOffset(position, drag.move(position, offset));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => drag.end(position, velocity)
      ? null
      : super.createBallisticSimulation(position, velocity);
}
