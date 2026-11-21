import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../phone_scheme.dart';
import 'quick_settings_panel.dart' show PixelShadeViewport;

/// Icons in the dialogs, in the [PixelShadeViewport.screenshotWidth] units
/// they were measured in.
const double _iconSize = 20;

/// Shows one of Android 17's quick-settings dialogs, grown out of the tile
/// at [origin] (on screen). [builder] gets the dialog's close, which
/// shrinks it back into the tile.
void showQuickSettingsDialog(
  WidgetRef ref, {
  required String keyName,
  required String debugLabel,
  required Rect origin,
  required Widget Function(VoidCallback close) builder,
}) {
  ref
      .read(shellPopupControllerProvider.notifier)
      .show(
        keyName: keyName,
        debugLabel: debugLabel,
        // The dialog runs its own motion and scrim.
        transitionDuration: const Duration(milliseconds: 16),
        barrierColor: const Color(0x00000000),
        builder: (_, handle) => _QsDialogFrame(
          origin: origin,
          onClosed: handle.close,
          builder: builder,
        ),
      );
}

/// Android's dialog geometry, in dp.
abstract final class _QsDialog {
  static const double sideMargin = 14;
  static const double verticalMargin = 48;
  static const double radius = 28;
  static const double rowHeight = 64;
  static const Duration open = Duration(milliseconds: 320);
  static const Duration close = Duration(milliseconds: 200);
}

class _QsDialogFrame extends StatefulWidget {
  const _QsDialogFrame({
    required this.origin,
    required this.onClosed,
    required this.builder,
  });

  final Rect origin;
  final VoidCallback onClosed;
  final Widget Function(VoidCallback close) builder;

  @override
  State<_QsDialogFrame> createState() => _QsDialogFrameState();
}

class _QsDialogFrameState extends State<_QsDialogFrame>
    with SingleTickerProviderStateMixin {
  final GlobalKey _screen = GlobalKey();
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: _QsDialog.open,
    reverseDuration: _QsDialog.close,
  );
  late final Animation<double> _grow = CurvedAnimation(
    parent: _motion,
    curve: Motion.md3EmphasizedDecelerate,
    reverseCurve: Motion.md3EmphasizedAccelerate,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_motion.forward());
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _motion.reverse().whenCompleteOrCancel(() {
      if (mounted) widget.onClosed();
    });
  }

  /// The tile in the dialog's own (dp) coordinates.
  Rect _originIn(RenderBox screen) => Rect.fromPoints(
    screen.globalToLocal(widget.origin.topLeft),
    screen.globalToLocal(widget.origin.bottomRight),
  );

  @override
  Widget build(BuildContext context) {
    return PixelShadeViewport(
      width: PixelShadeViewport.screenshotWidth,
      child: Builder(
        builder: (context) {
          final scheme = phoneSchemeOf(context);
          final size = MediaQuery.sizeOf(context);
          final padding = MediaQuery.paddingOf(context);
          final card = DecoratedBox(
            decoration: BoxDecoration(color: scheme.surfaceContainer),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 16,
                height: 1.25,
                decoration: TextDecoration.none,
              ),
              child: FadeTransition(
                // The content shows once the card has nearly grown.
                opacity: CurvedAnimation(
                  parent: _motion,
                  curve: const Interval(0.55, 1, curve: Curves.easeOut),
                  reverseCurve: const Interval(0.6, 1),
                ),
                child: widget.builder(_close),
              ),
            ),
          );
          return Stack(
            key: _screen,
            fit: StackFit.expand,
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: FadeTransition(
                  opacity: _grow,
                  child: const ColoredBox(color: Color(0x73000000)),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  _QsDialog.sideMargin + padding.left,
                  _QsDialog.verticalMargin + padding.top,
                  _QsDialog.sideMargin + padding.right,
                  _QsDialog.verticalMargin + padding.bottom,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: math.min(420, size.width),
                    ),
                    child: AnimatedBuilder(
                      animation: _grow,
                      child: card,
                      builder: (context, card) => ClipRRect(
                        clipper: _GrowClipper(
                          progress: _grow.value,
                          origin: () {
                            final screen = _screen.currentContext
                                ?.findRenderObject();
                            return screen is RenderBox
                                ? _originIn(screen)
                                : null;
                          },
                          screenSize: size,
                        ),
                        child: GestureDetector(
                          // Taps on the card stay on it.
                          behavior: HitTestBehavior.opaque,
                          onTap: () {},
                          child: card,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Clips the card to the tile it grows from, then to itself.
class _GrowClipper extends CustomClipper<RRect> {
  _GrowClipper({
    required this.progress,
    required this.origin,
    required this.screenSize,
  });

  final double progress;
  final Rect? Function() origin;
  final Size screenSize;

  @override
  RRect getClip(Size size) {
    final full = Offset.zero & size;
    final radius = Radius.circular(_QsDialog.radius);
    if (progress >= 1) return RRect.fromRectAndRadius(full, radius);
    // The card is centred on the screen.
    final topLeft = Offset(
      (screenSize.width - size.width) / 2,
      (screenSize.height - size.height) / 2,
    );
    final from =
        origin()?.shift(-topLeft) ??
        Rect.fromCenter(center: full.center, width: 0, height: 0);
    final rect = Rect.lerp(from, full, progress)!;
    final r =
        _QsDialog.radius +
        (from.height / 2 - _QsDialog.radius) * (1 - progress);
    return RRect.fromRectAndRadius(rect, Radius.circular(math.max(0, r)));
  }

  @override
  bool shouldReclip(_GrowClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.screenSize != screenSize;
}

// Parts ----------------------------------------------------------------------

class _DialogHeader extends StatelessWidget {
  const _DialogHeader({
    required this.title,
    required this.subtitle,
    required this.busy,
  });

  final String title;
  final String subtitle;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 24,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _ScanBar(busy: busy),
        ],
      ),
    );
  }
}

/// Android's thin progress line under the title: moving while it scans.
class _ScanBar extends StatefulWidget {
  const _ScanBar({required this.busy});

  final bool busy;

  @override
  State<_ScanBar> createState() => _ScanBarState();
}

class _ScanBarState extends State<_ScanBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) unawaited(_sweep.repeat());
  }

  @override
  void didUpdateWidget(covariant _ScanBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !_sweep.isAnimating) {
      unawaited(_sweep.repeat());
    } else if (!widget.busy && _sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    const width = 136.0;
    return SizedBox(
      width: width,
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: widget.busy
              ? AnimatedBuilder(
                  animation: _sweep,
                  builder: (context, _) {
                    final t = Curves.easeInOut.transform(_sweep.value);
                    return Stack(
                      children: <Widget>[
                        Positioned(
                          left: -40 + (width + 40) * t,
                          top: 0,
                          bottom: 0,
                          width: 40,
                          child: ColoredBox(color: scheme.primary),
                        ),
                      ],
                    );
                  },
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// A row with a label and Android's switch.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onChanged();
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.38,
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PhoneSwitch(value: value),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Material 3's switch, drawn without Material: a 52×32 track, a thumb of
/// 24 dp on and 16 dp off.
class PhoneSwitch extends StatelessWidget {
  const PhoneSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    const duration = Duration(milliseconds: 200);
    final thumb = value ? 24.0 : 16.0;
    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOutCubic,
      width: 52,
      height: 32,
      decoration: BoxDecoration(
        color: value ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: value ? scheme.primary : scheme.outline,
          width: 2,
        ),
      ),
      child: AnimatedAlign(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: value ? 2 : 6),
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            width: thumb,
            height: thumb,
            decoration: BoxDecoration(
              color: value ? scheme.onPrimary : scheme.outline,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// A network or device: icon, name and state, an optional trailing button.
/// [highlighted] is Android's connected pill.
class _ItemRow extends StatefulWidget {
  const _ItemRow({
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.highlighted = false,
    this.trailing,
    this.dimmed = false,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final bool highlighted;
  final bool dimmed;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final foreground = widget.highlighted
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final subtitle = widget.subtitle;
    var background = widget.highlighted
        ? scheme.primaryContainer
        : const Color(0x00000000);
    if (_pressed) {
      background = Color.alphaBlend(
        foreground.withValues(alpha: 0.10),
        background,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Semantics(
        button: widget.onTap != null,
        label: widget.title,
        value: subtitle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.onTap == null ? null : (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            constraints: const BoxConstraints(minHeight: _QsDialog.rowHeight),
            padding: const EdgeInsetsDirectional.only(start: 20, end: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(_QsDialog.rowHeight / 2),
            ),
            child: Row(
              children: <Widget>[
                IconTheme(
                  data: IconThemeData(
                    color: widget.dimmed
                        ? foreground.withValues(alpha: 0.6)
                        : foreground,
                    size: _iconSize,
                  ),
                  child: widget.leading,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: foreground, fontSize: 16),
                        ),
                        if (subtitle != null && subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: widget.highlighted
                                  ? foreground
                                  : scheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.trailing case final trailing?)
                  IconTheme(
                    data: IconThemeData(color: foreground, size: _iconSize),
                    child: trailing,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round 48 dp button with an icon, such as a row's settings gear.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(dimension: 48, child: Icon(icon)),
    ),
  );
}

/// Android's filled "Done" button, at the dialog's end.
class _DialogButtons extends StatelessWidget {
  const _DialogButtons({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Semantics(
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDone,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                context.l10n.quickSettingsDone,
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rows between the header and the buttons, scrolling when the screen
/// is short.
class _DialogBody extends StatelessWidget {
  const _DialogBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Flexible(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

// Wi-Fi ----------------------------------------------------------------------

/// Android's Internet dialog: the Wi-Fi switch, nearby networks with the
/// connected one first, and the way to Phone Settings.
class QuickSettingsWifiDialog extends ConsumerStatefulWidget {
  const QuickSettingsWifiDialog({
    super.key,
    required this.onClose,
    required this.onOpenSettings,
  });

  static const int _shown = 4;

  final VoidCallback onClose;

  /// Closes the shade and opens the Wi-Fi page in Phone Settings.
  final VoidCallback onOpenSettings;

  @override
  ConsumerState<QuickSettingsWifiDialog> createState() =>
      _QuickSettingsWifiDialogState();
}

class _QuickSettingsWifiDialogState
    extends ConsumerState<QuickSettingsWifiDialog> {
  @override
  void initState() {
    super.initState();
    // Fresh results, as Android scans while the dialog is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(networkConnectivityProvider);
      if (state.snapshot.wirelessEnabled && !state.scanning) {
        unawaited(ref.read(networkConnectivityProvider.notifier).scan());
      }
    });
  }

  void _activate(WifiNetwork network, NetworkConnectivityState state) {
    final controller = ref.read(networkConnectivityProvider.notifier);
    if (network.connected) {
      widget.onOpenSettings();
    } else if (!network.saved && network.security.requiresPassword) {
      // The password is asked for on the Wi-Fi page.
      widget.onOpenSettings();
    } else if (network.connectable) {
      unawaited(controller.connect(network));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(networkConnectivityProvider);
    final snapshot = state.snapshot;
    final controller = ref.read(networkConnectivityProvider.notifier);
    final radioEnabled =
        !state.initializing &&
        snapshot.serviceAvailable &&
        snapshot.wifiDeviceAvailable &&
        snapshot.wirelessHardwareEnabled &&
        snapshot.radioPermission != NetworkPermission.denied &&
        !state.radioChanging;
    final networks = snapshot.wirelessEnabled
        ? ([...snapshot.networks]..sort((a, b) {
                // Connected first, then saved, then by strength.
                int rank(WifiNetwork n) => n.connected
                    ? 0
                    : n.saved
                    ? 1
                    : 2;
                final byRank = rank(a).compareTo(rank(b));
                return byRank != 0 ? byRank : b.strength.compareTo(a.strength);
              }))
              .take(QuickSettingsWifiDialog._shown)
              .toList()
        : const <WifiNetwork>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DialogHeader(
          title: l10n.commonWifi,
          subtitle: l10n.quickSettingsWifiHint,
          busy: state.scanning || state.radioChanging,
        ),
        _DialogBody(
          children: <Widget>[
            _SwitchRow(
              label: l10n.quickSettingsUseWifi,
              value: snapshot.wirelessEnabled,
              enabled: radioEnabled,
              onChanged: controller.toggleWireless,
            ),
            for (final network in networks) _wifiRow(context, network, state),
            if (snapshot.wirelessEnabled)
              _ItemRow(
                leading: const Icon(Icons.chevron_right_rounded),
                title: l10n.quickSettingsSeeAll,
                onTap: widget.onOpenSettings,
              ),
          ],
        ),
        _DialogButtons(onDone: widget.onClose),
      ],
    );
  }

  Widget _wifiRow(
    BuildContext context,
    WifiNetwork network,
    NetworkConnectivityState state,
  ) {
    final l10n = context.l10n;
    final busy = state.busyNetworks.contains(network.identity);
    final status = busy
        ? l10n.commonConnecting
        : network.connected
        ? l10n.settingsConnected
        : network.saved
        ? l10n.quickSettingsSaved
        : null;
    return _ItemRow(
      leading: Icon(_wifiIcon(network.strength)),
      title: network.ssid,
      subtitle: status,
      highlighted: network.connected,
      dimmed: !network.connected,
      onTap: busy ? null : () => _activate(network, state),
      trailing: network.connected
          ? _IconAction(
              icon: Icons.settings_outlined,
              label: l10n.quickSettingsItemSettings(network.ssid),
              onTap: widget.onOpenSettings,
            )
          : network.security.requiresPassword
          ? const SizedBox.square(
              dimension: 48,
              child: Icon(Icons.lock_outline_rounded),
            )
          : null,
    );
  }

  static IconData _wifiIcon(int strength) => strength >= 75
      ? Icons.wifi_rounded
      : strength >= 50
      ? Icons.network_wifi_3_bar_rounded
      : strength >= 25
      ? Icons.network_wifi_2_bar_rounded
      : Icons.network_wifi_1_bar_rounded;
}

// Bluetooth ------------------------------------------------------------------

/// Android's Bluetooth dialog: the switch, saved devices to connect or
/// disconnect, and pairing in Phone Settings.
class QuickSettingsBluetoothDialog extends ConsumerWidget {
  const QuickSettingsBluetoothDialog({
    super.key,
    required this.onClose,
    required this.onOpenSettings,
  });

  static const int _shown = 4;

  final VoidCallback onClose;

  /// Closes the shade and opens the Bluetooth page in Phone Settings.
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = phoneSchemeOf(context);
    final state = ref.watch(bluetoothProvider);
    final controller = ref.read(bluetoothProvider.notifier);
    final usable =
        !state.initializing &&
        state.serviceAvailable &&
        state.available &&
        !state.powerChanging;
    final devices = state.powered
        ? ([...state.devices.where((device) => device.paired)]..sort(
                (a, b) => (b.connected ? 1 : 0).compareTo(a.connected ? 1 : 0),
              ))
              .take(_shown)
              .toList()
        : const <BluetoothDeviceInfo>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DialogHeader(
          title: l10n.commonBluetooth,
          subtitle: l10n.quickSettingsBluetoothHint,
          busy: state.scanning || state.powerChanging,
        ),
        _DialogBody(
          children: <Widget>[
            _SwitchRow(
              label: l10n.quickSettingsUseBluetooth,
              value: state.powered,
              enabled: usable,
              onChanged: controller.togglePower,
            ),
            for (final device in devices)
              _deviceRow(context, scheme, state, controller, device),
            if (state.powered)
              _ItemRow(
                leading: const Icon(Icons.add_rounded),
                title: l10n.quickSettingsPairNewDevice,
                onTap: onOpenSettings,
              ),
          ],
        ),
        _DialogButtons(onDone: onClose),
      ],
    );
  }

  Widget _deviceRow(
    BuildContext context,
    ColorScheme scheme,
    BluetoothState state,
    BluetoothController controller,
    BluetoothDeviceInfo device,
  ) {
    final l10n = context.l10n;
    final busy = state.busyDevices.contains(device.objectPath);
    final name = device.name.isEmpty ? device.address : device.name;
    return _ItemRow(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: device.connected
              ? scheme.onPrimaryContainer
              : scheme.tertiaryContainer,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          _deviceIcon(device.icon),
          size: 18,
          color: device.connected
              ? scheme.primaryContainer
              : scheme.onTertiaryContainer,
        ),
      ),
      title: name,
      subtitle: busy
          ? l10n.commonConnecting
          : device.connected
          ? l10n.settingsConnected
          : l10n.quickSettingsSaved,
      highlighted: device.connected,
      onTap: busy ? null : () => unawaited(controller.toggleConnection(device)),
      trailing: _IconAction(
        icon: Icons.settings_outlined,
        label: l10n.quickSettingsItemSettings(name),
        onTap: onOpenSettings,
      ),
    );
  }

  static IconData _deviceIcon(String icon) {
    if (icon.contains('audio') || icon.contains('headset')) {
      return Icons.headphones_rounded;
    }
    if (icon.contains('input') || icon.contains('keyboard')) {
      return Icons.keyboard_rounded;
    }
    if (icon.contains('mouse')) return Icons.mouse_rounded;
    if (icon.contains('phone')) return Icons.smartphone_rounded;
    if (icon.contains('computer')) return Icons.computer_rounded;
    if (icon.contains('watch')) return Icons.watch_rounded;
    return Icons.bluetooth_rounded;
  }
}
