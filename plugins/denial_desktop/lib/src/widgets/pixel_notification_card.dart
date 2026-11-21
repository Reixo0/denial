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

class _PixelNotificationCardState extends State<PixelNotificationCard> {
  bool _expanded = false;
  bool _pressed = false;

  /// A pull is growing the card (NotificationPullExpand) or settling it.
  bool _pulling = false;

  /// Showing the settings in place of the notification.
  bool _guts = false;

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
    // Collapsed, a heads-up conversation keeps the sender in the top line.
    final headed =
        (conversation && (!widget.headsUp || _expanded)) ||
        (_expanded && full && group == null);
    final showActions =
        widget.interactive &&
        widget.onAction != null &&
        actions.isNotEmpty &&
        (_expanded || widget.headsUp || notification.incomingCall);
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
              // alerted_icon: notification_2025_badge_size 14, margin 4.
              if (widget.headsUp) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.notifications_active,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ],
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
    // downward pull is taken; the list still scrolls up from the card.
    final pullable =
        widget.interactive && group == null && full && !_expanded && !_guts;
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
        onLongPress: canGuts && !_guts
            ? () {
                HapticFeedback.heavyImpact();
                _press(false);
                setState(() => _guts = true);
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(
            minHeight: PixelNotificationMetrics.minHeight,
          ),
          decoration: BoxDecoration(color: background, borderRadius: radius),
          child: AnimatedSize(
            // A pull moves the height itself.
            duration: _pulling
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Motion.md3EmphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: NotificationPullExpand(
              enabled: pullable,
              onStart: () {
                _press(false);
                setState(() {
                  _pulling = true;
                  _expanded = true;
                });
              },
              onSettled: (open) => setState(() {
                _pulling = false;
                _expanded = open;
              }),
              child: _guts
                  ? _PixelGuts(
                      notification: notification,
                      appName: appName,
                      onDismiss: widget.onDismiss,
                      onControl: widget.onControl,
                      onClose: () => setState(() => _guts = false),
                    )
                  : Stack(
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
          duration: const Duration(milliseconds: 200),
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
                  duration: const Duration(milliseconds: 200),
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

/// An open group as Android 17 draws it (NotificationChildrenContainer):
/// one card, the app's header row (its icon, the app line and the count
/// pill turned up) over the group's notifications, each a row of its own
/// (built by the list, [PixelNotificationCard] with `embedded`). Every row
/// is 72 dp collapsed, measured on EvolutionX.
class PixelNotificationGroupCard extends StatelessWidget {
  const PixelNotificationGroupCard({
    required this.group,
    required this.children,
    this.interactive = true,
    this.roundTop = true,
    this.roundBottom = true,
    this.onCollapse,
    super.key,
  });

  final DesktopNotificationGroup group;
  final List<Widget> children;
  final bool interactive;
  final bool roundTop;
  final bool roundBottom;

  /// A tap on the header or its pill folds the group again.
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final l10n = context.l10n;
    final notification = group.newest.notification;
    final appName = notificationAppName(notification, l10n);
    final age = pixelNotificationAge(context, notification);
    final collapse = interactive ? onCollapse : null;
    const big = Radius.circular(PixelNotificationMetrics.radius);
    const small = Radius.circular(PixelNotificationMetrics.innerRadius);
    // The header's line and pill sit on the icon's centre line.
    const centre =
        PixelNotificationMetrics.margin +
        PixelNotificationMetrics.iconCircle / 2;
    final header = Semantics(
      button: collapse != null,
      expanded: true,
      label: l10n.notificationGroupHeader(appName, group.members.length),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: collapse,
        child: SizedBox(
          height: PixelNotificationMetrics.minHeight,
          child: Stack(
            children: <Widget>[
              PositionedDirectional(
                start: PixelNotificationMetrics.margin,
                top: PixelNotificationMetrics.margin,
                child: _PixelAppIcon(notification: notification),
              ),
              PositionedDirectional(
                start: PixelNotificationMetrics.contentStart,
                end: PixelNotificationMetrics.contentEnd,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    '$appName · $age',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: PixelNotificationMetrics.infoSize,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                end: 0,
                top:
                    centre -
                    PixelNotificationMetrics.margin -
                    PixelNotificationMetrics.pillHeight / 2,
                child: _PixelExpandPill(
                  expanded: true,
                  count: group.members.length,
                  onTap: collapse,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceEffect1,
        borderRadius: BorderRadius.vertical(
          top: roundTop ? big : small,
          bottom: roundBottom ? big : small,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[header, ...children],
      ),
    );
  }
}
