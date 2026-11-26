part of 'notification_banner.dart';

/// Android 17's notification template sizes, in dp (the shade lays itself
/// out in Android's units; see `PixelShadeViewport`). From AOSP's
/// `notification_2025_template_collapsed_base.xml` and its dimens.
abstract final class PixelNotificationMetrics {
  static const double minHeight = 72;
  static const double margin = 16;
  static const double reducedMargin = 12;
  static const double iconCircle = 40;
  static const double contentStart = 72;

  /// Room the top line leaves for the expand pill.
  static const double contentEnd = 60;
  static const double rightIcon = 48;
  static const double pillWidth = 26;
  static const double pillHeight = 18;
  static const double actionsStart = 56;

  /// The action buttons' height and the space under them (AOSP's list is
  /// 48 dp at least; its buttons measure 40 dp on EvolutionX, 6 dp above
  /// the card's edge).
  static const double actionsHeight = 40;
  static const double actionsBottom = 6;

  /// The expanded template's list: 48 dp, its labels 30 dp above the card's
  /// end (EvolutionX's recording of 2026-11-22).
  static const double expandedActionsHeight = 48;
  static const double expandedActionInset = 14.5;

  /// The expanded template, on the same recording: from the app's line to
  /// the title, on to the text (notification_2025_text_margin_top), and
  /// above a sender's messages.
  static const double titleGap = 6.5;
  static const double textGap = 8;
  static const double messageGap = 16;

  /// A text action's inset: its label starts at 65 dp, as on EvolutionX.
  static const double actionInset = 9;

  /// Corners at the ends of the stack, and between neighbouring cards.
  static const double radius = 28;
  static const double innerRadius = 4;

  /// Between neighbouring cards of the stack.
  static const double divider = 2;

  static const double titleSize = 14;
  static const double textSize = 14;
  static const double infoSize = 12;
}

/// One notification, or a folded group, as Android 17 draws it in the
/// shade: the app's icon in a circle, a top line with title, app and age,
/// the text, an expand pill, and when expanded its actions.
class PixelNotificationCard extends StatefulWidget {
  const PixelNotificationCard({
    required this.notification,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.interactive = true,
    this.roundTop = true,
    this.roundBottom = true,
    this.headsUp = false,
    this.group,
    this.onExpandGroup,
    this.onOpen,
    this.onAction,
    this.onDismiss,
    this.onControl,
    this.embedded = false,
  });

  final DesktopNotification notification;

  /// A row inside an open group's card: no background or corners of its own.
  final bool embedded;
  final NotificationPreviewMode previewMode;
  final bool interactive;

  /// Full corners at the top or bottom: the card ends the stack there.
  final bool roundTop;
  final bool roundBottom;

  /// Shown over the apps as it arrives (AOSP's
  /// notification_2025_template_heads_up_base.xml): the collapsed template
  /// with its actions always under it, the alerted bell in the top line,
  /// on the opaque surfaceContainer (ActivatableNotificationView's
  /// mOpaqueColor; #151b20 on EvolutionX).
  final bool headsUp;

  /// A folded group this card stands for; a tap runs [onExpandGroup].
  final DesktopNotificationGroup? group;
  final VoidCallback? onExpandGroup;

  final VoidCallback? onOpen;
  final ValueChanged<String>? onAction;

  /// With [onControl], a long press opens the notification's settings (its
  /// "guts"): Dismiss runs this.
  final VoidCallback? onDismiss;

  /// Changes one of the sender's settings (see
  /// [DesktopNotification.controls]).
  final ValueChanged<String>? onControl;

  @override
  State<PixelNotificationCard> createState() => _PixelNotificationCardState();
}

class _PixelNotificationCardState extends State<PixelNotificationCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  bool _pressed = false;

  /// The settings are coming or going: the card's height follows.
  bool _sizing = false;

  /// Showing the settings in place of the notification.
  bool _guts = false;
  Offset? _gutsOrigin;
  Size? _gutsRevealSize;
  late final AnimationController _gutsController = AnimationController(
    vsync: this,
    duration: androidDuration(360),
  )..addStatusListener(_onGutsStatus);
  late final Animation<double> _gutsReveal = CurvedAnimation(
    parent: _gutsController,
    curve: const Cubic(0, 0, 0.2, 1),
    reverseCurve: const Cubic(0.4, 0, 1, 1).flipped,
  );

  void _onGutsStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.completed) {
      if (mounted) setState(() {});
    }
  }

  void _openGuts(Offset origin) {
    HapticFeedback.heavyImpact();
    _press(false);
    setState(() {
      _sizing = true;
      _guts = true;
      _gutsOrigin = origin;
      _gutsRevealSize = null;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _gutsController.value = 1;
    } else {
      _gutsController.forward(from: 0);
    }
  }

  void _closeGuts() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _gutsRevealSize = box.size;
    }
    setState(() {
      _sizing = true;
      _guts = false;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _gutsController.value = 0;
    } else {
      _gutsController.reverse();
    }
  }

  @override
  void dispose() {
    _gutsController
      ..removeStatusListener(_onGutsStatus)
      ..dispose();
    super.dispose();
  }

  void _toggle() => setState(() {
    _sizing = false;
    _expanded = !_expanded;
  });

  void _press(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    final notification = widget.notification;
    final group = widget.group?.stacked ?? false ? widget.group : null;
    final full = widget.previewMode == NotificationPreviewMode.full;
    final appName = notificationAppName(notification, l10n);
    final title = !full
        ? appName
        : group != null
        ? appName
        : notification.summary.isEmpty
        ? l10n.notificationGeneric
        : notification.summary;
    final messages = notification.messages;
    // A conversation shows its last message under the sender or its name,
    // and expanded all of them (named only when another person wrote them).
    final conversation = full && group == null && messages.isNotEmpty;
    final text = !full
        ? l10n.notificationNew
        : conversation
        ? [
            for (final message in messages)
              message.sender.isEmpty || message.sender == title
                  ? message.text
                  : l10n.notificationMessage(message.sender, message.text),
          ].join('\n')
        : plainNotificationBody(notification.body);
    final actions = <DesktopNotificationAction>[
      if (full && group == null)
        for (final action in notification.actions)
          if (action.key != 'default') action,
    ];
    final opens =
        widget.interactive &&
        full &&
        group == null &&
        widget.onOpen != null &&
        notification.opensApp;
    final image =
        full &&
        group == null &&
        (notification.imageData != null || notification.imagePath.isNotEmpty);

    final age = pixelNotificationAge(context, notification);
    final info = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: PixelNotificationMetrics.infoSize,
      height: 1.35,
    );
    final strong = TextStyle(
      color: scheme.onSurface,
      fontSize: PixelNotificationMetrics.titleSize,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );
    final plain = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: PixelNotificationMetrics.textSize,
      height: 1.43,
    );

    // One of the two layouts. Everything it draws is a MorphPart: pulled or
    // tapped, what both show moves from one to the other.
    Widget layout({required bool expanded}) {
      // Every notification expands on Android: the expanded template
      // (notification_2025_template_expanded_base.xml) adds a header with
      // the app and age above the title and the full text. Collapsed, the
      // title is in the top line.
      final headed = expanded && full && group == null;
      final showActions =
          widget.interactive &&
          widget.onAction != null &&
          actions.isNotEmpty &&
          (expanded || widget.headsUp || notification.incomingCall);
      final titlePart = MorphPart(
        id: 'title',
        same: title,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: strong,
        ),
      );
      final topLine = Row(
        children: <Widget>[
          Flexible(
            child: headed
                ? MorphPart(
                    id: 'app',
                    child: Text(
                      appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: info,
                    ),
                  )
                : titlePart,
          ),
          MorphPart(
            id: 'age',
            same: age,
            child: Text(' · $age', style: info),
          ),
          // alerted_icon: notification_2025_badge_size 14, margin 4.
          if (widget.headsUp && !headed)
            MorphPart(
              id: 'alerted',
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: Icon(
                  Icons.notifications_active,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      );
      final body = <Widget>[
        if (headed) ...[
          const SizedBox(height: PixelNotificationMetrics.titleGap),
          titlePart,
        ],
        if (group != null)
          for (final record in group.members.take(3))
            _PixelGroupLine(notification: record.notification, full: full)
        else if (conversation && expanded)
          ..._messages(messages, title, strong, plain)
        else if (conversation)
          _lastMessage(messages.last, title, strong, plain)
        else if (text.isNotEmpty) ...[
          if (headed) const SizedBox(height: PixelNotificationMetrics.textGap),
          MorphPart(
            id: 'text',
            same: text,
            child: Text(
              text,
              maxLines: expanded ? 12 : 1,
              overflow: TextOverflow.ellipsis,
              style: plain,
            ),
          ),
        ],
        if (full && notification.hasProgress)
          MorphPart(
            id: 'progress',
            kind: MorphKind.similar,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _PixelProgress(value: notification.progress),
            ),
          ),
      ];
      final content = Padding(
        // The action list follows the text directly (AOSP
        // notification_2025_template_expanded_base.xml).
        padding: EdgeInsetsDirectional.only(
          start: PixelNotificationMetrics.contentStart,
          top: PixelNotificationMetrics.reducedMargin + 4,
          bottom: showActions ? 0 : PixelNotificationMetrics.reducedMargin + 4,
          end: PixelNotificationMetrics.margin,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.only(
                end:
                    PixelNotificationMetrics.contentEnd -
                    PixelNotificationMetrics.margin,
              ),
              child: topLine,
            ),
            ...body,
          ],
        ),
      );
      return ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: PixelNotificationMetrics.minHeight,
        ),
        child: Stack(
          children: <Widget>[
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                content,
                if (showActions)
                  MorphPart(
                    id: 'actions',
                    kind: MorphKind.still,
                    child: _PixelActions(
                      actions: actions,
                      onAction: widget.onAction!,
                      expanded: expanded,
                    ),
                  ),
              ],
            ),
            PositionedDirectional(
              start: PixelNotificationMetrics.margin,
              top: PixelNotificationMetrics.margin,
              // A picture (a sender's avatar, say) takes the app
              // icon's place: Android shows one icon, never two.
              child: MorphPart(
                id: 'icon',
                same: 'icon',
                kind: MorphKind.picture,
                child: _PixelAppIcon(
                  notification: notification,
                  picture: image,
                  badge: image && conversation,
                ),
              ),
            ),
            PositionedDirectional(
              end: 0,
              top: 0,
              child: MorphPart(
                id: 'expander',
                kind: conversation ? MorphKind.similar : MorphKind.normal,
                child: _PixelExpandPill(
                  expanded: expanded,
                  count: group?.members.length,
                  onTap: !widget.interactive
                      ? null
                      : group != null
                      ? widget.onExpandGroup
                      : _toggle,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Android 17 with row transparency paints surfaceEffect1 over the
    // shade's blur: on EvolutionX #8a111417, the surfaceContainerLow tone at
    // 54 % (`cmd overlay lookup android android:color/
    // system_surface_effect_1_dark`).
    var background = widget.embedded
        ? const Color(0x00000000)
        : widget.headsUp
        ? scheme.surfaceContainer
        : scheme.surfaceEffect1;
    if (_pressed) {
      background = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.08),
        background,
      );
    }
    const big = Radius.circular(PixelNotificationMetrics.radius);
    const small = Radius.circular(PixelNotificationMetrics.innerRadius);
    final radius = widget.embedded
        ? BorderRadius.zero
        : BorderRadius.vertical(
            top: widget.roundTop ? big : small,
            bottom: widget.roundBottom ? big : small,
          );
    final canGuts =
        widget.interactive &&
        full &&
        (widget.onControl != null || widget.onDismiss != null);
    final VoidCallback? onTap = !widget.interactive || _guts
        ? null
        : group != null
        ? widget.onExpandGroup
        : opens
        ? widget.onOpen
        : _toggle;

    // Android's ExpandHelper: pulling a collapsed notification down grows
    // it with the finger into its expanded layout (actions and all). Only a
    // downward pull is taken; the list still scrolls up from the card. A
    // heads-up's pull goes to the shade instead (NotificationPanelView-
    // Controller lets HeadsUpTouchHelper intercept before the list).
    final pullable =
        widget.interactive &&
        !widget.headsUp &&
        group == null &&
        full &&
        !_expanded &&
        !_guts;
    return Semantics(
      container: true,
      expanded: _expanded,
      label: text.isEmpty
          ? l10n.notificationSemantics(appName, title)
          : l10n.notificationSemanticsWithBody(appName, title, text),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTap == null ? null : (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: onTap,
        onLongPressStart: canGuts && !_guts
            ? (details) => _openGuts(details.localPosition)
            : null,
        child: AnimatedContainer(
          duration: androidDuration(120),
          decoration: BoxDecoration(color: background, borderRadius: radius),
          child: AnimatedSize(
            // Opening and closing move the height themselves.
            duration: _sizing ? androidDuration(360) : Duration.zero,
            curve: Curves.fastOutSlowIn,
            alignment: Alignment.topCenter,
            child: _buildGutsTransition(
              notification: notification,
              appName: appName,
              pullable: pullable,
              layout: layout,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGutsTransition({
    required DesktopNotification notification,
    required String appName,
    required bool pullable,
    required Widget Function({required bool expanded}) layout,
  }) {
    final showGuts = _guts || !_gutsController.isDismissed;
    final gutsFull = _guts && _gutsController.isCompleted;
    Widget buildContent() => NotificationPullExpand(
      enabled: pullable,
      open: _expanded,
      onStart: () {
        _press(false);
        setState(() => _sizing = false);
      },
      onOpen: (open) => setState(() => _expanded = open),
      builder: (context, motion) => NotificationMorph(
        motion: motion,
        collapsed: motion.showsCollapsed ? layout(expanded: false) : null,
        expanded: motion.showsExpanded ? layout(expanded: true) : null,
      ),
    );
    if (!showGuts) return buildContent();

    final guts = _PixelGuts(
      notification: notification,
      appName: appName,
      onDismiss: widget.onDismiss,
      onControl: widget.onControl,
      onClose: _closeGuts,
    );
    if (gutsFull) return guts;

    Widget clippedContent(Widget child) => ClipPath(
      clipper: _GutsRevealClipper(
        progress: _gutsReveal,
        origin: _gutsOrigin,
        revealSize: _gutsRevealSize,
        invert: true,
      ),
      child: child,
    );
    final gutsLayer = ClipPath(
      clipper: _GutsRevealClipper(
        progress: _gutsReveal,
        origin: _gutsOrigin,
        revealSize: _gutsRevealSize,
        invert: false,
      ),
      child: guts,
    );
    if (_guts) {
      return Stack(
        alignment: Alignment.topCenter,
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: clippedContent(
                Align(alignment: Alignment.topCenter, child: buildContent()),
              ),
            ),
          ),
          gutsLayer,
        ],
      );
    }
    return Stack(
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        clippedContent(buildContent()),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(child: gutsLayer),
        ),
      ],
    );
  }

  /// Collapsed, a conversation's last message, after its sender.
  Widget _lastMessage(
    DesktopNotificationMessage message,
    String title,
    TextStyle strong,
    TextStyle plain,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        if (_named(message, title))
          MorphPart(
            id: 'sender0',
            kind: MorphKind.similar,
            linear: true,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: Text(
                '${message.sender}:',
                maxLines: 1,
                style: strong.copyWith(height: plain.height),
              ),
            ),
          ),
        Flexible(
          child: MorphPart(
            id: 'message0',
            same: message.text,
            linear: true,
            child: Text(
              message.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: plain,
            ),
          ),
        ),
      ],
    );
  }

  static bool _named(DesktopNotificationMessage message, String title) =>
      message.sender.isNotEmpty && message.sender != title;

  /// Expanded, a conversation's messages, each sender's under their name
  /// (notification_2025_messaging_group.xml). Counted from the last one, the
  /// one the collapsed layout shows.
  List<Widget> _messages(
    List<DesktopNotificationMessage> messages,
    String title,
    TextStyle strong,
    TextStyle plain,
  ) {
    final shown = messages.length > 7
        ? messages.sublist(messages.length - 7)
        : messages;
    final rows = <Widget>[];
    var senders = 0;
    for (var i = 0; i < shown.length; i++) {
      final message = shown[i];
      final fromLast = shown.length - 1 - i;
      final first = i == 0 || shown[i - 1].sender != message.sender;
      if (first) {
        senders++;
        rows.add(
          SizedBox(
            height: _named(message, title)
                ? PixelNotificationMetrics.messageGap
                : PixelNotificationMetrics.textGap,
          ),
        );
        if (_named(message, title)) {
          // The last sender's name is the one of the collapsed layout.
          final last = shown
              .skip(i)
              .every((other) => other.sender == message.sender);
          rows.add(
            MorphPart(
              id: last ? 'sender0' : 'sender$fromLast',
              kind: last ? MorphKind.similar : MorphKind.normal,
              linear: true,
              group: last ? null : senders,
              child: Text(
                message.sender,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: strong.copyWith(height: plain.height),
              ),
            ),
          );
        }
      }
      rows.add(
        MorphPart(
          id: 'message$fromLast',
          same: message.text,
          linear: true,
          group: fromLast == 0 ? null : senders,
          child: Text(
            message.text,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: plain,
          ),
        ),
      );
    }
    return rows;
  }
}

/// A notification's age as Android writes it: now, 5m, 2h, 3d.
String pixelNotificationAge(
  BuildContext context,
  DesktopNotification notification,
) {
  final l10n = context.l10n;
  final time = DateTime.fromMillisecondsSinceEpoch(notification.timeMs);
  final age = DateTime.now().difference(time);
  if (notification.timeMs <= 0 || age.inMinutes < 1) {
    return l10n.notificationTimeNow;
  }
  if (age.inHours < 1) return l10n.notificationTimeMinutes(age.inMinutes);
  if (age.inDays < 1) return l10n.notificationTimeHours(age.inHours);
  return l10n.notificationTimeDays(age.inDays);
}

/// The app's icon in Android's 40 dp circle.
class _PixelAppIcon extends StatelessWidget {
  const _PixelAppIcon({
    required this.notification,
    this.picture = false,
    this.badge = false,
  });

  final DesktopNotification notification;

  /// Show the notification's own picture, filling the circle.
  final bool picture;

  /// With [picture], the app's icon in a small badge at its corner, as on
  /// Android's conversations.
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    if (picture) {
      final avatar = ClipOval(
        child: NotificationArtwork(
          notification: notification,
          size: PixelNotificationMetrics.iconCircle,
        ),
      );
      if (!badge) return avatar;
      return SizedBox.square(
        dimension: PixelNotificationMetrics.iconCircle,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            avatar,
            PositionedDirectional(
              end: -3,
              bottom: -3,
              child: Container(
                width: 20,
                height: 20,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: ClipOval(
                  child: NotificationAppIcon(notification: notification),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      width: PixelNotificationMetrics.iconCircle,
      height: PixelNotificationMetrics.iconCircle,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(7),
      child: NotificationAppIcon(notification: notification),
    );
  }
}

/// Android's expand pill at the card's top end: a chevron, with the count
/// on a folded group.
class _PixelExpandPill extends StatelessWidget {
  const _PixelExpandPill({
    required this.expanded,
    required this.onTap,
    this.count,
  });

  final bool expanded;
  final int? count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final count = this.count;
    return Semantics(
      button: onTap != null,
      expanded: expanded,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          // The pill's touch target is its padding, as Android's.
          padding: const EdgeInsets.all(PixelNotificationMetrics.margin),
          child: Container(
            constraints: const BoxConstraints(
              minWidth: PixelNotificationMetrics.pillWidth,
              minHeight: PixelNotificationMetrics.pillHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(
                PixelNotificationMetrics.pillHeight / 2,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (count != null) ...[
                  Text(
                    '$count',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 11,
                      height: 16 / 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: scheme.onSurface,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A member of a folded group: its title and text on one line
/// (notification_2025_hybrid.xml).
class _PixelGroupLine extends StatelessWidget {
  const _PixelGroupLine({required this.notification, required this.full});

  final DesktopNotification notification;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    final title = !full
        ? l10n.notificationNew
        : notification.summary.isEmpty
        ? l10n.notificationGeneric
        : notification.summary;
    final messages = notification.messages;
    final text = !full
        ? ''
        : messages.isNotEmpty
        ? messages.last.text
        : plainNotificationBody(notification.body);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: PixelNotificationMetrics.contentStart,
        end: PixelNotificationMetrics.margin,
      ),
      child: Row(
        children: <Widget>[
          Flexible(
            // The title keeps its width as far as it goes.
            flex: text.isEmpty ? 1 : 0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: MorphPart(
                id: 'title',
                same: title,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: PixelNotificationMetrics.titleSize,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(width: 6),
            Expanded(
              child: MorphPart(
                id: 'text',
                child: Text(
                  text.split('\n').first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: PixelNotificationMetrics.textSize,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The expanded notification's actions: Android's row of text buttons.
class _PixelActions extends StatelessWidget {
  const _PixelActions({
    required this.actions,
    required this.onAction,
    this.expanded = false,
  });

  final List<DesktopNotificationAction> actions;
  final ValueChanged<String> onAction;

  /// In the expanded template, whose labels start with the text.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final height = expanded
        ? PixelNotificationMetrics.expandedActionsHeight
        : PixelNotificationMetrics.actionsHeight;
    final inset = expanded
        ? PixelNotificationMetrics.expandedActionInset
        : PixelNotificationMetrics.actionInset;
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: expanded
            ? PixelNotificationMetrics.contentStart - inset
            : PixelNotificationMetrics.actionsStart,
        end: PixelNotificationMetrics.margin,
        bottom: PixelNotificationMetrics.actionsBottom,
      ),
      child: SizedBox(
        height: height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: actions.length,
          // Labels about 26 dp apart (29 expanded), as on EvolutionX.
          separatorBuilder: (_, _) => SizedBox(width: expanded ? 0 : 8),
          itemBuilder: (context, index) {
            final action = actions[index];
            return Center(
              child: Semantics(
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onAction(action.key),
                  // Android's actions are coloured text, without a fill.
                  child: Container(
                    height: height,
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    alignment: Alignment.center,
                    child: Text(
                      action.label,
                      maxLines: 1,
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PixelProgress extends StatelessWidget {
  const _PixelProgress({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: scheme.surfaceContainerHighest),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: (value / 100).clamp(0.0, 1.0),
              child: ColoredBox(color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A notification's settings on a long press, in its card (AOSP's
/// notification_2025_info.xml): the app and channel with the settings gear,
/// Default or Silent, then Dismiss, Turn off and Done. The choice applies
/// on Done, as Android's does.
class _PixelGuts extends StatefulWidget {
  const _PixelGuts({
    required this.notification,
    required this.appName,
    required this.onClose,
    this.onDismiss,
    this.onControl,
  });

  final DesktopNotification notification;
  final String appName;
  final VoidCallback onClose;
  final VoidCallback? onDismiss;
  final ValueChanged<String>? onControl;

  @override
  State<_PixelGuts> createState() => _PixelGutsState();
}

class _PixelGutsState extends State<_PixelGuts> {
  static const _alerting = 'x-denial-alerting';
  static const _silent = 'x-denial-silent';
  static const _turnOff = 'x-denial-turn-off';
  static const _settings = 'x-denial-settings';

  late bool _quiet = _wasQuiet;

  bool get _wasQuiet =>
      widget.notification.urgency == DesktopNotificationUrgency.low;

  bool _takes(String control) =>
      widget.onControl != null &&
      widget.notification.controls.contains(control);

  void _control(String control) => widget.onControl?.call(control);

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    final notification = widget.notification;
    final configurable = _takes(_alerting) && _takes(_silent);
    final channel = notification.channel;
    const margin = PixelNotificationMetrics.margin;
    final strong = TextStyle(
      color: scheme.onSurface,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 20 / 14,
    );
    final plain = TextStyle(
      color: scheme.onSurface,
      fontSize: 14,
      height: 20 / 14,
    );
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: margin),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // header: pkg_icon, names, app_settings.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  top: margin,
                  end: margin,
                ),
                child: _PixelAppIcon(notification: notification),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: margin),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: PixelNotificationMetrics.iconCircle,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          channel.isEmpty ? widget.appName : channel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: strong,
                        ),
                        if (channel.isNotEmpty)
                          Text(
                            widget.appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: plain,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_takes(_settings))
                Semantics(
                  button: true,
                  label: l10n.notificationGutsSettings,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _control(_settings);
                      widget.onClose();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(margin),
                      child: Icon(
                        Icons.settings_outlined,
                        size: 24,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(width: margin),
            ],
          ),
          const SizedBox(height: margin),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: margin),
            child: configurable
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _GutsChoice(
                        icon: Icons.notifications_active_outlined,
                        label: l10n.notificationGutsDefault,
                        summary: l10n.notificationGutsDefaultSummary,
                        selected: !_quiet,
                        onTap: () => setState(() => _quiet = false),
                      ),
                      // notification_importance_button_separation.
                      const SizedBox(height: 8),
                      _GutsChoice(
                        icon: Icons.notifications_off_outlined,
                        label: l10n.notificationGutsSilent,
                        summary: l10n.notificationGutsSilentSummary,
                        selected: _quiet,
                        onTap: () => setState(() => _quiet = true),
                      ),
                    ],
                  )
                : Text(l10n.notificationGutsNotConfigurable, style: plain),
          ),
          // bottom_buttons: notification_2025_guts_button_size high.
          Padding(
            padding: const EdgeInsetsDirectional.only(
              top: 12,
              end: margin,
              bottom: 6,
            ),
            child: SizedBox(
              height: 56,
              child: Row(
                children: <Widget>[
                  if (widget.onDismiss != null && notification.clearable) ...[
                    _GutsButton(
                      label: l10n.notificationGutsDismiss,
                      onTap: () {
                        widget.onClose();
                        widget.onDismiss!();
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_takes(_turnOff))
                    _GutsButton(
                      label: l10n.notificationGutsTurnOff,
                      onTap: () {
                        _control(_turnOff);
                        widget.onClose();
                      },
                    ),
                  const Spacer(),
                  _GutsButton(
                    label: l10n.notificationGutsDone,
                    filled: true,
                    onTap: () {
                      if (configurable && _quiet != _wasQuiet) {
                        _control(_quiet ? _silent : _alerting);
                      }
                      widget.onClose();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Default or Silent (notification_2025_guts_priority_button_bg): chosen,
/// secondaryContainer with a 1 dp outline at 28 dp corners and its summary
/// under the label; otherwise clear with a 1 dp outlineVariant at 16 dp.
class _GutsChoice extends StatelessWidget {
  const _GutsChoice({
    required this.icon,
    required this.label,
    required this.summary,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String summary;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: androidDuration(200),
          curve: Curves.fastOutSlowIn,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? scheme.secondaryContainer
                : scheme.secondaryContainer.withValues(alpha: 0),
            border: Border.all(
              color: selected ? scheme.outline : scheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(selected ? 28 : 16),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 24, color: scheme.onSurface),
              const SizedBox(width: PixelNotificationMetrics.margin),
              Expanded(
                child: AnimatedSize(
                  duration: androidDuration(200),
                  curve: Curves.fastOutSlowIn,
                  alignment: Alignment.topCenter,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 20 / 14,
                        ),
                      ),
                      if (selected)
                        Text(
                          summary,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 14,
                            height: 20 / 14,
                          ),
                        ),
                    ],
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

/// Widget.Dialog.Button: a pill, filled with primary, or outlined
/// (BorderButton).
class _GutsButton extends StatelessWidget {
  const _GutsButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? scheme.primary : null,
            border: filled ? null : Border.all(color: scheme.outline),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: filled ? scheme.onPrimary : scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 20 / 14,
            ),
          ),
        ),
      ),
    );
  }
}

/// A group as Android 17 draws it (NotificationChildrenContainer): one card,
/// the app's header row (its icon, the app line and the count pill) over its
/// notifications. Folded, the first two are one line each; open, every one is
/// a row of its own ([row], a [PixelNotificationCard] with `embedded`).
///
/// A pull grows it with the finger and a tap on the header plays the same
/// change: the lines turn into their rows, the header's line goes to the
/// middle of its row and the other notifications follow. Sizes measured on
/// EvolutionX.
class PixelNotificationGroupCard extends StatelessWidget {
  const PixelNotificationGroupCard({
    required this.group,
    required this.row,
    required this.open,
    required this.onOpen,
    this.interactive = true,
    this.roundTop = true,
    this.roundBottom = true,
    super.key,
  });

  final DesktopNotificationGroup group;
  final Widget Function(DesktopNotificationRecord record) row;
  final bool open;

  /// It was opened or folded: by a pull, the header or a tap when folded.
  final ValueChanged<bool> onOpen;
  final bool interactive;
  final bool roundTop;
  final bool roundBottom;

  /// AOSP's NUMBER_OF_CHILDREN_WHEN_COLLAPSED and _WHEN_CHILDREN_EXPANDED.
  static const int folded = 2;
  static const int most = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    final notification = group.newest.notification;
    final appName = notificationAppName(notification, l10n);
    final age = pixelNotificationAge(context, notification);
    const big = Radius.circular(PixelNotificationMetrics.radius);
    const small = Radius.circular(PixelNotificationMetrics.innerRadius);
    final info = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: PixelNotificationMetrics.infoSize,
      height: 1.35,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceEffect1,
        borderRadius: BorderRadius.vertical(
          top: roundTop ? big : small,
          bottom: roundBottom ? big : small,
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: interactive && !open ? () => onOpen(true) : null,
        child: NotificationPullExpand(
          enabled: interactive,
          open: open,
          onOpen: (value) {
            if (value != open) onOpen(value);
          },
          builder: (context, motion) {
            final toggle = interactive ? () => onOpen(!motion.open) : null;
            final members = group.members
                .take(motion.showsExpanded ? most : folded)
                .toList();
            return _PixelGroupBody(
              motion: motion,
              children: <Widget>[
                Semantics(
                  button: toggle != null,
                  expanded: motion.open,
                  label: l10n.notificationGroupHeader(
                    appName,
                    group.members.length,
                  ),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: toggle,
                    child: const SizedBox.expand(),
                  ),
                ),
                IgnorePointer(child: _PixelAppIcon(notification: notification)),
                IgnorePointer(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          appName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: info,
                        ),
                      ),
                      Text(' · $age', style: info),
                    ],
                  ),
                ),
                _PixelExpandPill(
                  expanded: motion.open,
                  count: group.members.length,
                  onTap: toggle,
                ),
                for (final (index, record) in members.indexed)
                  NotificationMorph(
                    key: ValueKey<Object>(record.notification.id),
                    fromLine: true,
                    collapsed: index < folded && motion.showsCollapsed
                        ? _PixelGroupLine(
                            notification: record.notification,
                            full: true,
                          )
                        : null,
                    expanded: motion.showsExpanded ? row(record) : null,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Lays out a [PixelNotificationGroupCard]: its header's touch area, icon,
/// line and pill, then its notifications.
class _PixelGroupBody extends MultiChildRenderObjectWidget {
  const _PixelGroupBody({required this.motion, required super.children});

  final NotificationExpandMotion motion;

  @override
  _RenderPixelGroup createRenderObject(BuildContext context) =>
      _RenderPixelGroup(motion, Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, _RenderPixelGroup group) {
    group
      ..motion = motion
      ..direction = Directionality.of(context);
  }
}

class _PixelGroupParentData extends ContainerBoxParentData<RenderBox> {
  double shown = 0;
  double alpha = 1;
  final clip = LayerHandle<ClipRectLayer>();
  final opacity = LayerHandle<OpacityLayer>();
}

class _RenderPixelGroup extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PixelGroupParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PixelGroupParentData> {
  _RenderPixelGroup(this._motion, this._direction);

  NotificationExpandMotion _motion;
  set motion(NotificationExpandMotion value) {
    if (identical(value, _motion)) return;
    if (attached) _motion.removeListener(markNeedsLayout);
    _motion = value;
    if (attached) _motion.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  TextDirection _direction;
  set direction(TextDirection value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsLayout();
  }

  /// Folded, the first line's top (getContentMarginTop: 16 + 10 + 12), the
  /// space between lines (notification_children_padding) and under the last
  /// (notification_children_collapsed_bottom_padding).
  static const double _linesTop = 38;
  static const double _linesGap = 8;
  static const double _linesBottom = 16;

  /// Open: the header's height and the hairline over each row.
  static const double _header = 72;
  static const double _divider = 0.5;

  /// The header's line and pill: their centres folded and open.
  static const double _lineFolded = 24.3;
  static const double _pillFolded = 25;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PixelGroupParentData) {
      child.parentData = _PixelGroupParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _motion.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _PixelGroupParentData;
      data.clip.layer = null;
      data.opacity.layer = null;
    }
    super.dispose();
  }

  void _put(RenderBox child, Offset offset) =>
      (child.parentData! as _PixelGroupParentData).offset =
          _direction == TextDirection.rtl
          ? Offset(size.width - offset.dx - child.size.width, offset.dy)
          : offset;

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final touch = firstChild!;
    final icon = childAfter(touch)!;
    final line = childAfter(icon)!;
    final pill = childAfter(line)!;
    touch.layout(
      BoxConstraints.tightFor(width: width, height: _header),
      parentUsesSize: true,
    );
    icon.layout(const BoxConstraints(), parentUsesSize: true);
    pill.layout(const BoxConstraints(), parentUsesSize: true);
    line.layout(
      BoxConstraints(
        maxWidth: math.max(
          0,
          width -
              PixelNotificationMetrics.contentStart -
              PixelNotificationMetrics.contentEnd,
        ),
      ),
      parentUsesSize: true,
    );
    final rows = <RenderNotificationMorph>[];
    for (
      var child = childAfter(pill);
      child != null;
      child = childAfter(child)
    ) {
      child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      rows.add(child as RenderNotificationMorph);
    }

    const folded = PixelNotificationGroupCard.folded;
    final lines = math.min(folded, rows.length);
    var foldedHeight = _linesTop;
    var openHeight = _header;
    var rowsOfLines = 0.0;
    for (var i = 0; i < rows.length; i++) {
      if (i < lines) {
        foldedHeight += rows[i].collapsedHeight + (i > 0 ? _linesGap : 0);
        rowsOfLines += rows[i].expandedHeight;
      }
      openHeight += rows[i].expandedHeight + _divider;
    }
    foldedHeight = math.max(_header, foldedHeight + _linesBottom);

    final moving = _motion.active;
    final byHand = _motion.byHand;
    var progress = _motion.open ? 1.0 : 0.0;
    var height = _motion.open ? openHeight : foldedHeight;
    if (moving) {
      _motion.range = math.max(0, openHeight - foldedHeight);
      height = foldedHeight + _motion.grown;
      if (byHand) {
        // getGroupExpandFraction: 1 once the lines are full rows.
        final lined = _header + _divider + rowsOfLines;
        progress = lined <= foldedHeight
            ? 1
            : ((height - foldedHeight) / (lined - foldedHeight)).clamp(
                0.0,
                1.0,
              );
      } else {
        progress = _motion.progress;
      }
    }
    size = constraints.constrain(Size(width, height));

    _put(touch, Offset.zero);
    _put(
      icon,
      const Offset(
        PixelNotificationMetrics.margin,
        PixelNotificationMetrics.margin,
      ),
    );
    _put(
      line,
      Offset(
        PixelNotificationMetrics.contentStart,
        lerpDouble(_lineFolded, _header / 2, progress)! - line.size.height / 2,
      ),
    );
    _put(
      pill,
      Offset(
        width - pill.size.width,
        lerpDouble(_pillFolded, _header / 2, progress)! - pill.size.height / 2,
      ),
    );

    // Where each row is while folded, open, and on the way.
    var foldedY = _linesTop;
    var openY = _header + _divider;
    var pulledY = _linesTop;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final data = row.parentData! as _PixelGroupParentData;
      final isLine = i < lines;
      final full = row.expandedHeight;
      double y;
      double shown;
      var alpha = 1.0;
      if (!moving) {
        y = _motion.open ? openY : foldedY;
        shown = row.size.height;
      } else if (byHand) {
        pulledY += i == 0
            ? (_header - _linesTop + _divider) * progress
            : lerpDouble(_linesGap, _divider, progress)!;
        shown = isLine
            ? lerpDouble(row.collapsedHeight, full, progress)!
            : full;
        y = pulledY;
        // The rest show by how much of them the card has reached.
        if (!isLine) {
          alpha = progress < 1 || full <= 0
              ? 0
              : ((height - y) / full).clamp(0.0, 1.0);
        }
        pulledY += shown;
      } else {
        y = lerpDouble(foldedY, openY, progress)!;
        shown = isLine
            ? lerpDouble(row.collapsedHeight, full, progress)!
            : full;
        if (!isLine) alpha = progress;
      }
      if (row.morphing) {
        row.drive(
          amount: byHand ? progress : _motion.amount,
          toExpanded: _motion.toExpanded,
          byHand: byHand,
          extent: shown,
        );
      }
      data
        ..shown = shown
        ..alpha = alpha;
      _put(row, Offset(0, y));
      final lineHeight = isLine || rows.isEmpty
          ? row.collapsedHeight
          : rows.first.collapsedHeight;
      foldedY += lineHeight + _linesGap;
      openY += full + _divider;
    }
    if (moving) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_motion.active) {
      defaultPaint(context, offset);
      return;
    }
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _PixelGroupParentData;
      if (child is! RenderNotificationMorph) {
        context.paintChild(child, offset + data.offset);
        continue;
      }
      final alpha = (data.alpha * 255).round();
      final left = math.min(data.shown, size.height - data.offset.dy);
      if (alpha <= 0 || left <= 0) {
        data.clip.layer = null;
        data.opacity.layer = null;
        continue;
      }
      data.clip.layer = context.pushClipRect(
        child.needsCompositing || alpha < 255,
        offset + data.offset,
        Offset.zero & Size(size.width, left),
        (context, offset) {
          if (alpha >= 255) {
            data.opacity.layer = null;
            context.paintChild(child!, offset);
            return;
          }
          data.opacity.layer = context.pushOpacity(
            offset,
            alpha,
            (context, offset) => context.paintChild(child!, offset),
            oldLayer: data.opacity.layer,
          );
        },
        oldLayer: data.clip.layer,
      );
    }
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_motion.active) return false;
    return defaultHitTestChildren(result, position: position);
  }
}

/// Circular reveal clip matching AOSP `NotificationGuts.animateOpen/Close`.
class _GutsRevealClipper extends CustomClipper<Path> {
  _GutsRevealClipper({
    required this.progress,
    required this.origin,
    required this.revealSize,
    required this.invert,
  }) : super(reclip: progress);

  final Animation<double> progress;
  final Offset? origin;
  final Size? revealSize;
  final bool invert;

  @override
  Path getClip(Size size) {
    final target = revealSize ?? size;
    final center = origin ?? target.center(Offset.zero);
    final horz = math.max(target.width - center.dx, center.dx);
    final vert = math.max(target.height - center.dy, center.dy);
    final radius =
        math.sqrt(horz * horz + vert * vert) * progress.value.clamp(0.0, 1.0);
    final circle = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    if (!invert) return circle;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(circle, Offset.zero);
  }

  @override
  bool shouldReclip(_GutsRevealClipper oldClipper) =>
      !identical(oldClipper.progress, progress) ||
      oldClipper.origin != origin ||
      oldClipper.revealSize != revealSize ||
      oldClipper.invert != invert;
}
