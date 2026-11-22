import 'package:denial_desktop/src/state/notification_groups.dart';
import 'package:denial_desktop/src/state/reference_shell_controller.dart';

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
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart'
    show WindowBackdropCache, WindowBackdropMotion;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;

import '../notification_banner.dart';
import '../notification_pull_expand.dart';
import '../notification_rows.dart';
import '../phone_scheme.dart';
import 'notification_footer.dart';
import 'notification_shade_list.dart';
import 'notification_shelf.dart';
import 'shade_dismiss_gesture.dart';
import 'shade_expansion.dart';
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
  late final AnimationController _entrance;
  final ScrollController _scroll = ScrollController();
  final _rowMotion = _RowMotion();
  late final NotificationClearAll _clearAll;
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
    );
  }

  Animation<double>? _motionProgress;
  Listenable? _motion;
  bool _armed = true;

  /// Bumped each time the shade closes. The rows start collapsed again:
  /// Android resets what the user expanded and folds the groups then.
  int _generation = 0;
  bool _reducedMotion = false;
  bool _acknowledgeScheduled = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration:
          Motion.notificationHistorySlide +
          Motion.notificationHistoryStagger *
              Motion.notificationHistoryMaxStagger,
    );
    _clearAll = NotificationClearAll(this);
    widget.scroll?.attach(_scroll);
    widget.progress.addListener(_observeProgress);
  }

  /// Android closes the shade 200 ms after the rows have left.
  void _closeAfterClear() {
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      ref.read(referenceShellProvider.notifier).closeQuickSettings();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) _entrance.value = 1;
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
    if (widget.closed && widget.progress.value <= 0) {
      if (!_armed) _collapseOnClose();
      _armed = true;
    }
    if (_armed && widget.progress.value > 0) {
      _armed = false;
      if (_reducedMotion) {
        _entrance.value = 1;
      } else {
        _entrance.forward(from: 0);
      }
    }
    _scheduleAcknowledgement();
  }

  void _collapseOnClose() {
    // Not during a build: the groups are shared state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(expandedNotificationGroupsProvider.notifier).collapseAll();
      setState(() => _generation++);
    });
  }

  void _scheduleAcknowledgement() {
    if (_acknowledgeScheduled || !widget.active || widget.progress.value <= 0) {
      return;
    }
    _acknowledgeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _acknowledgeScheduled = false;
      if (!mounted ||
          !widget.active ||
          widget.progress.value <= 0 ||
          ref.read(referenceShellProvider).lockLayerVisible) {
        return;
      }
      final state = ref.read(desktopNotificationsProvider);
      final controller = ref.read(desktopNotificationsProvider.notifier);
      // A notification already shown in the drawer must not pop up again
      // when the drawer closes. Its history and active actions remain intact.
      for (final id in state.bannerQueue) {
        controller.hideBanner(id);
      }
      if (widget.progress.value >= 1) controller.markAllRead();
    });
  }

  /// Everything that moves a card on screen without repainting it, for the
  /// cached glass slices: the shade, the entrance, scrolling, and row layout
  /// or dismissal. The same merge while the shade progress is unchanged.
  Listenable _motionFor(Animation<double> progress) {
    if (!identical(progress, _motionProgress)) {
      _motionProgress = progress;
      _motion = Listenable.merge([progress, _entrance, _scroll, _rowMotion]);
    }
    return _motion!;
  }

  @override
  Widget build(BuildContext context) {
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
    // Locked, groups stay folded and history only shows.
    final expandedGroups = locked
        ? const <String>{}
        : ref.watch(expandedNotificationGroupsProvider);
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
    void open(DesktopNotificationRecord record) {
      if (openNotification(ref, record.notification.id)) {
        ref.read(referenceShellProvider.notifier).closeQuickSettings();
      }
    }

    void control(DesktopNotificationRecord record, String control) {
      controller.invokeControl(record.notification.id, control);
      // The app's settings open over the apps.
      if (control == 'x-denial-settings') {
        ref.read(referenceShellProvider.notifier).closeQuickSettings();
      }
    }

    // One notification inside an open group's card.
    Widget member(DesktopNotificationRecord record) {
      final clearable = !locked && record.notification.clearable;
      return Dismissible(
        key: ValueKey<Object>(('member', record.notification.id)),
        direction: clearable
            ? DismissDirection.horizontal
            : DismissDirection.none,
        confirmDismiss: (_) async {
          controller.dismissFromHistory(record.notification.id);
          return false;
        },
        child: PixelNotificationCard(
          notification: record.notification,
          embedded: true,
          interactive: !locked,
          previewMode: preview,
          onOpen: () => open(record),
          onAction: (key) =>
              controller.invokeAction(record.notification.id, key),
          onDismiss: clearable
              ? () => controller.dismissFromHistory(record.notification.id)
              : null,
          onControl: (value) => control(record, value),
        ),
      );
    }

    final rows = <NotificationHistoryRow>[...alertingRows, ...silentRows];
    final silentStart = silentRows.isEmpty ? -1 : alertingRows.length;
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
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: CustomScrollView(
                  key: const PageStorageKey('mobile-notification-history'),
                  controller: _scroll,
                  physics: const _HistoryScrollPhysics(),
                  primary: false,
                  clipBehavior: Clip.none,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.only(top: widget.topPadding),
                      sliver: NotificationShadeList(
                        topPadding: widget.topPadding,
                        progress: widget.progress,
                        entrance: _entrance,
                        opaqueRows: cachedGlass,
                        onRowsMoved: _rowMotion.moved,
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index == rows.length) {
                              return _ColorOsNotificationReveal(
                                reveal: _revealOf(index),
                                index: index,
                                cachedGlass: cachedGlass,
                                child: Padding(
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
                                              onSettings: () {
                                                ref
                                                    .read(
                                                      referenceShellProvider
                                                          .notifier,
                                                    )
                                                    .closeQuickSettings();
                                                ref
                                                    .read(denialBridgeProvider)
                                                    .launchApplication(
                                                      const <String>[
                                                        'denial-phone-settings',
                                                        'notifications',
                                                      ],
                                                    );
                                              },
                                              onCleared: _closeAfterClear,
                                            ),
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
                                  index: index,
                                  record: group.newest,
                                  group: group,
                                  roundTop: roundTop,
                                  roundBottom: roundBottom,
                                  preview: preview,
                                  interactive: !locked,
                                  onDismiss: () => controller
                                      .dismissGroupFromHistory(group.key),
                                  expanded: expandedGroups.contains(group.key),
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
                                  index: index,
                                  record: record,
                                  roundTop: roundTop,
                                  roundBottom: roundBottom,
                                  preview: preview,
                                  interactive: !locked,
                                  onDismiss: () =>
                                      controller.dismissFromHistory(
                                        record.notification.id,
                                      ),
                                  onOpen: () => open(record),
                                  onAction: (key) => controller.invokeAction(
                                    record.notification.id,
                                    key,
                                  ),
                                  onControl: (value) => control(record, value),
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
                              clearable: clearable && !locked,
                              child: entry,
                            );
                            return _ColorOsNotificationReveal(
                              reveal: _revealOf(index),
                              index: index,
                              cachedGlass: cachedGlass,
                              child: index == silentStart
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
                                  : slide,
                            );
                          },
                          childCount:
                              rows.length +
                              (rows.isNotEmpty && !locked ? 1 : 0),
                          findChildIndexCallback: (key) =>
                              key is ValueKey && indices.containsKey(key.value)
                              ? indices[key.value]
                              : null,
                        ),
                      ),
                    ),
                  ],
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

  /// Android shows the rows with the shade itself (its stages fade them):
  /// no ColorOS stagger.
  Animation<double> _revealOf(int index) => kAlwaysCompleteAnimation;

  // ignore: unused_element
  Animation<double> _colorOsRevealOf(int index) {
    final stagger = index.clamp(0, Motion.notificationHistoryMaxStagger);
    return _reveals[stagger] ??= _entrance.drive(
      Animatable.fromCallback(
        (entrance) => _ColorOsNotificationReveal.revealAt(entrance, stagger),
      ),
    );
  }

  final _reveals = <int, Animation<double>>{};

  @override
  void dispose() {
    widget.progress.removeListener(_observeProgress);
    widget.scroll?.detach(_scroll);
    _clearAll.dispose();
    _entrance.dispose();
    _scroll.dispose();
    _rowMotion.dispose();
    super.dispose();
  }
}

class _RowMotion extends ChangeNotifier {
  void moved() => notifyListeners();
}

/// Separate notification rows reveal with alpha, scale, and negative vertical
/// spacing. This mirrors ColorOS' NotificationPanelSeparateAnimation instead
/// of treating the notification center as a horizontally sliding drawer.
class _ColorOsNotificationReveal extends StatelessWidget {
  const _ColorOsNotificationReveal({
    required this.reveal,
    required this.index,
    required this.cachedGlass,
    required this.child,
  });

  /// The row's eased reveal: [revealAt] its stagger.
  final Animation<double> reveal;
  final int index;

  /// Over cached glass the row fades through [NotificationReveal], without
  /// an opacity layer, and its text scales as an image.
  final bool cachedGlass;
  final Widget child;

  /// The row's eased reveal at [entrance], after its stagger.
  static double revealAt(double entrance, int index) {
    final staggerIndex = index.clamp(0, Motion.notificationHistoryMaxStagger);
    final duration = Motion.notificationHistorySlide.inMilliseconds;
    final stagger = Motion.notificationHistoryStagger.inMilliseconds;
    final total = duration + stagger * Motion.notificationHistoryMaxStagger;
    final phase = ((entrance * total - staggerIndex * stagger) / duration)
        .clamp(0.0, 1.0)
        .toDouble();
    return Curves.easeOutCubic.transform(phase);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: reveal,
      child: cachedGlass
          ? NotificationReveal(reveal: reveal, child: child)
          : child,
      builder: (context, child) {
        final staggerIndex = index.clamp(
          0,
          Motion.notificationHistoryMaxStagger,
        );
        final value = reveal.value;
        final initialScale = (0.85 - staggerIndex * 0.1)
            .clamp(0.0, 1.0)
            .toDouble();
        final baseSpacing = -30.0 * staggerIndex;
        final initialSpacing =
            baseSpacing - (1 - initialScale) * baseSpacing.abs();
        final moved = Transform.translate(
          offset: Offset(0, initialSpacing * (1 - value)),
          child: Transform.scale(
            scale: initialScale + (1 - initialScale) * value,
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
        return cachedGlass ? moved : Opacity(opacity: value, child: moved);
      },
    );
  }
}

class _HistoryNotification extends StatelessWidget {
  const _HistoryNotification({
    required this.expansion,
    required this.shelf,
    required this.motion,
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
    Widget openGroup(BuildContext context) => PixelNotificationGroupCard(
      group: group!,
      interactive: interactive,
      roundTop: roundTop,
      roundBottom: roundBottom,
      onCollapse: onCollapse,
      children: <Widget>[for (final record in group.members) member!(record)],
    );
    final Widget card = PixelNotificationCard(
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
    final stackedGroup = group != null && group.stacked && member != null;
    // A pull on a folded group opens it with the finger (ExpandHelper on a
    // group: its summary lines give way to its rows).
    // A tap on the pill or header plays the same change (NotificationPullExpand
    // follows [expanded]).
    final Widget content = !stackedGroup
        ? card
        : NotificationPullExpand(
            enabled: interactive && preview == NotificationPreviewMode.full,
            open: expanded,
            expanded: openGroup,
            onSettled: (open) {
              if (open) onExpand?.call();
            },
            child: card,
          );
    final clearable =
        interactive && (group?.clearable ?? notification.clearable);
    return Padding(
      padding: EdgeInsets.only(
        bottom: roundBottom ? 8 : PixelNotificationMetrics.divider,
      ),
      child: Dismissible(
        key: ValueKey(notification.id),
        direction: clearable
            ? DismissDirection.horizontal
            : DismissDirection.none,
        onUpdate: (_) => NotificationShadeList.invalidateOcclusion(context),
        confirmDismiss: (_) async {
          // The controller removes the row only if the request succeeds.
          // Do not leave a dismissed widget in the tree on bridge failure.
          onDismiss();
          return false;
        },
        child: Semantics(
          onDismiss: clearable
              ? () {
                  onDismiss();
                }
              : null,
          child: ClipRRect(
            clipper: _SquishClipper(
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
              motion: motion,
            ),
            child: content,
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
    required Listenable motion,
  }) : super(reclip: motion);

  final Animation<double> expansion;
  final BorderRadius radius;
  final NotificationShelfGeometry shelf;
  final int index;

  @override
  RRect getClip(Size size) {
    final frame = shelf.read();
    if (frame != null) return frame.clipRow(index, size, radius);
    final squish = AndroidStackExpansion.squish(expansion.value);
    return radius.toRRect(Offset.zero & Size(size.width, size.height * squish));
  }

  @override
  bool shouldReclip(_SquishClipper oldClipper) =>
      oldClipper.radius != radius ||
      oldClipper.expansion != expansion ||
      oldClipper.shelf != shelf ||
      oldClipper.index != index;
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
class _HistoryScrollPhysics extends ClampingScrollPhysics {
  const _HistoryScrollPhysics({super.parent});

  @override
  _HistoryScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _HistoryScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      position.maxScrollExtent > position.minScrollExtent;
}
