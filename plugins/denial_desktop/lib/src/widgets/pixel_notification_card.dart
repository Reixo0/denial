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

  /// A text action's inset: its label starts at 65 dp, as on EvolutionX.
  static const double actionInset = 9;

  /// Corners at the ends of the stack, and between neighbouring cards.
  static const double radius = 28;
  static const double innerRadius = 4;

  /// Between neighbouring cards of the stack.
  static const double divider = 2;

  /// surfaceEffect1's opacity (0x8a).
  static const double surfaceAlpha = 0x8a / 255;

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
    this.group,
    this.onExpandGroup,
    this.onOpen,
    this.onAction,
  });

  final DesktopNotification notification;
  final NotificationPreviewMode previewMode;
  final bool interactive;

  /// Full corners at the top or bottom: the card ends the stack there.
  final bool roundTop;
  final bool roundBottom;

  /// A folded group this card stands for; a tap runs [onExpandGroup].
  final DesktopNotificationGroup? group;
  final VoidCallback? onExpandGroup;

  final VoidCallback? onOpen;
  final ValueChanged<String>? onAction;

  @override
  State<PixelNotificationCard> createState() => _PixelNotificationCardState();
}

class _PixelNotificationCardState extends State<PixelNotificationCard> {
  bool _expanded = false;
  bool _pressed = false;

  void _toggle() => setState(() => _expanded = !_expanded);

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
    // Android's conversation layout: the app and age on top, the sender or
    // conversation under it, then the messages (named only when another
    // person wrote them).
    final conversation = full && group == null && messages.isNotEmpty;
    final shownMessages = _expanded || messages.length <= 1
        ? messages
        : messages.sublist(messages.length - 1);
    final text = !full
        ? l10n.notificationNew
        : conversation
        ? [
            for (final message in shownMessages)
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
    // Every notification expands on Android: the expanded template
    // (notification_2025_template_expanded_base.xml) adds a header with the
    // app and age above the title and the full text.
    // Expanded, a plain notification takes the conversation's arrangement:
    // app and age on top, then the title.
    final headed = conversation || (_expanded && full && group == null);
    final showActions =
        widget.interactive &&
        widget.onAction != null &&
        actions.isNotEmpty &&
        (_expanded || notification.incomingCall);
    final image =
        full &&
        group == null &&
        (notification.imageData != null || notification.imagePath.isNotEmpty);

    final info = TextStyle(
      color: scheme.onSurfaceVariant,
      fontSize: PixelNotificationMetrics.infoSize,
      height: 1.35,
    );
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: scheme.onSurface,
        fontSize: PixelNotificationMetrics.titleSize,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
    );
    final age = pixelNotificationAge(context, notification);
    final topLine = headed
        ? Text(
            '$appName · $age',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: info,
          )
        : Row(
            children: <Widget>[
              Flexible(child: titleText),
              Text(' · $age', style: info),
            ],
          );
    final body = <Widget>[
      if (headed) ...[const SizedBox(height: 4), titleText],
      if (group != null)
        for (final record in group.members.take(3))
          _PixelGroupLine(notification: record.notification, full: full)
      else if (text.isNotEmpty)
        Text(
          text,
          maxLines: _expanded ? 12 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: PixelNotificationMetrics.textSize,
            height: 1.43,
          ),
        ),
      if (full && notification.hasProgress) ...[
        const SizedBox(height: 8),
        _PixelProgress(value: notification.progress),
      ],
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
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
          ),
        ],
      ),
    );

    // Android 17 with row transparency paints surfaceEffect1 over the
    // shade's blur: on EvolutionX #8a111417, the surfaceContainerLow tone at
    // 54 % (`cmd overlay lookup android android:color/
    // system_surface_effect_1_dark`).
    var background = scheme.surfaceContainerLow.withValues(
      alpha: PixelNotificationMetrics.surfaceAlpha,
    );
    if (_pressed) {
      background = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.08),
        background,
      );
    }
    const big = Radius.circular(PixelNotificationMetrics.radius);
    const small = Radius.circular(PixelNotificationMetrics.innerRadius);
    final radius = BorderRadius.vertical(
      top: widget.roundTop ? big : small,
      bottom: widget.roundBottom ? big : small,
    );
    final VoidCallback? onTap = !widget.interactive
        ? null
        : group != null
        ? widget.onExpandGroup
        : opens
        ? widget.onOpen
        : _toggle;

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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(
            minHeight: PixelNotificationMetrics.minHeight,
          ),
          decoration: BoxDecoration(color: background, borderRadius: radius),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Motion.md3EmphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: Stack(
              children: <Widget>[
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    content,
                    if (showActions)
                      _PixelActions(
                        actions: actions,
                        onAction: widget.onAction!,
                      ),
                  ],
                ),
                PositionedDirectional(
                  start: PixelNotificationMetrics.margin,
                  top: PixelNotificationMetrics.margin,
                  // A picture (a sender's avatar, say) takes the app
                  // icon's place: Android shows one icon, never two.
                  child: _PixelAppIcon(
                    notification: notification,
                    picture: image,
                    badge: image && conversation,
                  ),
                ),
                PositionedDirectional(
                  end: 0,
                  top: 0,
                  child: _PixelExpandPill(
                    expanded: group == null && _expanded,
                    count: group?.members.length,
                    onTap: !widget.interactive
                        ? null
                        : group != null
                        ? widget.onExpandGroup
                        : _toggle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One more member of a folded group: its title and text on one line.
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
    final text = full ? plainNotificationBody(notification.body) : '';
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: title,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (text.isNotEmpty) TextSpan(text: '  ${text.split('\n').first}'),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: PixelNotificationMetrics.textSize,
        height: 1.43,
      ),
    );
  }
}

/// The expanded notification's actions: Android's row of text buttons.
class _PixelActions extends StatelessWidget {
  const _PixelActions({required this.actions, required this.onAction});

  final List<DesktopNotificationAction> actions;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: PixelNotificationMetrics.actionsStart,
        end: PixelNotificationMetrics.margin,
        bottom: PixelNotificationMetrics.actionsBottom,
      ),
      child: SizedBox(
        height: PixelNotificationMetrics.actionsHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: actions.length,
          // Labels about 26 dp apart, as on EvolutionX.
          separatorBuilder: (_, _) => const SizedBox(width: 8),
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
                    height: PixelNotificationMetrics.actionsHeight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: PixelNotificationMetrics.actionInset,
                    ),
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
