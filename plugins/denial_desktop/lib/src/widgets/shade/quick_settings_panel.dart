import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/quick_settings.dart';
import '../../state/reference_shell_presentation.dart';
import '../../state/reference_shell_profile.dart';

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart'
    show WindowBackdropCache, WindowBackdropSlice;
import 'package:denial_flutter_sdk/shell_theme.dart';

import '../connectivity/bluetooth_detail_surface.dart';
import '../connectivity/wifi_detail_surface.dart';
import '../connectivity/mobile_data_tile.dart';
import '../phone_scheme.dart';
import '../session/power_session_surface.dart';

import 'package:denial_flutter_sdk/effects.dart';

import 'quick_settings_dialogs.dart';
import 'quick_settings_tiles.dart';

import 'mobile_notification_history.dart';
import 'shade_backdrop_scene.dart';
import 'shade_dismiss_gesture.dart';
import 'shade_expansion_motion.dart';
import 'shade_reference_geometry.dart';
import 'status_glyphs.dart';
import '../../state/phone_desk.dart';

/// Which state an opened shade starts in: Android's first pull
/// ([notifications]: a row of tiles over the notifications) or the full
/// quick settings.
enum ShadePage { notifications, quickSettings }

/// The scene's backdrop frosted once, when the translucent shade can show it
/// in place of live material.
WindowBackdropCache? _frostedShadeBackdrop(BuildContext context) =>
    context.shellTheme.effectivePanelOpacity < 1
    ? WindowBackdropCache.maybeOf(context)
    : null;

final _blurFraction = Animatable<double>.fromCallback(
  ColorOsShadeMotion.blurFraction,
);

EdgeInsets _divideInsets(EdgeInsets insets, double divisor) => EdgeInsets.only(
  left: insets.left / divisor,
  top: insets.top / divisor,
  right: insets.right / divisor,
  bottom: insets.bottom / divisor,
);

/// Android 17's notification shade and quick settings. [progress] is `0`
/// when hidden and `1` when open. [page] picks the state it opens in; a
/// vertical drag on the tiles moves between the two.
class QuickSettingsShade extends ConsumerWidget {
  const QuickSettingsShade({
    super.key,
    required this.progress,
    this.active = true,
    this.closed = false,
    this.page = ShadePage.quickSettings,
    this.onPageChanged,
  });

  final Animation<double> progress;
  final bool active;
  final bool closed;
  final ShadePage page;
  final ValueChanged<ShadePage>? onPageChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(referenceShellProvider.notifier);

    // Blur what the shade covers, the app included, as Android does, not
    // the wallpaper frosted once: a null backdrop keeps the shade and its
    // cards on the live, shared blur, which grows as the shade opens.
    return WindowBackdropCache(
      backdrop: null,
      motion: const AlwaysStoppedAnimation<double>(0),
      child: IgnorePointer(
        ignoring: !active,
        child: ShadeBackdropScene(
          progress: progress,
          cached: false,
          child: BackdropGroup(
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ShadeDismissGesture(
                    progress: progress,
                    child: const SizedBox.expand(),
                  ),
                  _FullScreenShade(
                    progress: progress,
                    child: Focus(
                      autofocus: active,
                      canRequestFocus: active,
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.escape) {
                          controller.closeQuickSettings();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: PixelShadeViewport(
                        child: _PixelShade(
                          progress: progress,
                          closed: closed,
                          active: active,
                          page: page,
                          onPageChanged: onPageChanged,
                        ),
                      ),
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

class _FullScreenShade extends StatelessWidget {
  const _FullScreenShade({required this.progress, required this.child});

  final Animation<double> progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final background = AnimatedBuilder(
      animation: progress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: theme.panelGradient(
            context.shellColors.panelBackground,
            context.shellColors.panelBackgroundBottom,
          ),
        ),
      ),
      builder: (context, background) => Opacity(
        opacity: ColorOsShadeMotion.blurFraction(progress.value),
        child: background,
      ),
    );
    final cache = _frostedShadeBackdrop(context);
    if (cache != null) {
      final fade = progress.drive(_blurFraction);
      return RepaintBoundary(
        child: ShadeBackdropRegion(
          occludesNotifications: false,
          borderRadius: BorderRadius.zero,
          child: WindowBackdropCache(
            backdrop: cache.backdrop,
            motion: cache.motion,
            overlayColor: ShadeBackdropScene.dim,
            overlayOpacity: fade,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Builder(
                  builder: (context) {
                    final dimmed = WindowBackdropCache.maybeOf(context);
                    return dimmed == null
                        ? const SizedBox.expand()
                        : WindowBackdropSlice(
                            cache: dimmed,
                            glass: theme.windowGlassShading,
                            opacity: fade,
                          );
                  },
                ),
                background,
                WindowBackdropCache(
                  backdrop: cache.backdrop,
                  motion: cache.motion,
                  overlayColor: Color.alphaBlend(
                    theme.panelColor(
                      Color.lerp(
                        context.shellColors.panelBackground,
                        context.shellColors.panelBackgroundBottom,
                        0.5,
                      )!,
                    ),
                    ShadeBackdropScene.dim,
                  ),
                  overlayOpacity: fade,
                  child: child,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return RepaintBoundary(
      child: ShadeBackdropRegion(
        occludesNotifications: false,
        borderRadius: BorderRadius.zero,
        child: AnimatedBuilder(
          animation: progress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: background),
              child,
            ],
          ),
          builder: (context, composedShade) {
            final blur = ColorOsShadeMotion.blurFraction(progress.value);
            return ShellBackdropBlur(
              grouped: true,
              blur:
                  !ShadeBackdropScene.sharesBlur(context) &&
                  theme.effectivePanelOpacity < 1.0,
              strength: blur,
              separateChild: true,
              borderRadius: BorderRadius.zero,
              edgeless: true,
              child: composedShade!,
            );
          },
        ),
      ),
    );
  }
}

/// Lays the shade out in Android's dp: the phone's short side is taken as
/// [shortSide] dp (Android's width on this phone), and the whole shade,
/// text included, is scaled to fill the real screen.
class PixelShadeViewport extends StatelessWidget {
  const PixelShadeViewport({super.key, required this.child});

  static const double shortSide = 374;

  final Widget child;

  /// The viewport's dp-to-pixel scale for widgets inside it.
  static double scaleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PixelScale>()?.scale ?? 1;

  static double scaleFor(Size size) {
    final side = size.shortestSide;
    if (!side.isFinite || side <= 0) return 1;
    return math.max(1.0, side / shortSide);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = scaleFor(viewport);
        final size = viewport / scale;
        final media = MediaQuery.of(context);
        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: size,
                child: MediaQuery(
                  data: media.copyWith(
                    size: size,
                    textScaler: phoneTextScaler(media),
                    devicePixelRatio: media.devicePixelRatio * scale,
                    padding: _divideInsets(media.padding, scale),
                    viewPadding: _divideInsets(media.viewPadding, scale),
                    viewInsets: _divideInsets(media.viewInsets, scale),
                    systemGestureInsets: _divideInsets(
                      media.systemGestureInsets,
                      scale,
                    ),
                  ),
                  child: _PixelScale(scale: scale, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PixelScale extends InheritedWidget {
  const _PixelScale({required this.scale, required super.child});

  final double scale;

  @override
  bool updateShouldNotify(_PixelScale oldWidget) => scale != oldWidget.scale;
}

/// How a drag on the shade is being used.
enum _DragMode { expansion, closing, none }

class _PixelShade extends ConsumerStatefulWidget {
  const _PixelShade({
    required this.progress,
    required this.closed,
    required this.active,
    required this.page,
    required this.onPageChanged,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;
  final ShadePage page;
  final ValueChanged<ShadePage>? onPageChanged;

  @override
  ConsumerState<_PixelShade> createState() => _PixelShadeState();
}

class _PixelShadeState extends ConsumerState<_PixelShade>
    with SingleTickerProviderStateMixin {
  /// Status row of the first pull, and the full header with its clock.
  static const double _collapsedHeader = 36;
  static const double _expandedHeader = 92;

  /// Drag distance, in dp, that opens the full quick settings.
  static const double _expansionTravel = 320;

  late final AnimationController _expansion = AnimationController(
    vsync: this,
    value: widget.page == ShadePage.quickSettings ? 1 : 0,
  );
  _DragMode? _drag;
  double _closeDistance = 0;

  /// The shade reached fully open since it was last closed: moving back
  /// down its progress is closing, which runs the stages backwards.
  bool _wasOpen = false;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_trackOpen);
    _trackOpen();
  }

  void _trackOpen() {
    final p = widget.progress.value;
    if (p >= 0.999) {
      _wasOpen = true;
    } else if (p <= 0.001) {
      _wasOpen = false;
    }
  }

  @override
  void didUpdateWidget(covariant _PixelShade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_trackOpen);
      widget.progress.addListener(_trackOpen);
      _trackOpen();
    }
    final target = widget.page == ShadePage.quickSettings ? 1.0 : 0.0;
    if (widget.closed || !widget.active) {
      // Closed: every pull starts on the notifications, as Android's does.
      _expansion.stop();
      _expansion.value = 0;
      _drag = null;
      if (widget.page != ShadePage.notifications) {
        final onPageChanged = widget.onPageChanged;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => onPageChanged?.call(ShadePage.notifications),
        );
      }
    } else if (oldWidget.page != widget.page && _drag == null) {
      _settle(target);
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_trackOpen);
    _expansion.dispose();
    super.dispose();
  }

  void _settle(double target, {double velocity = 0}) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 380);
    _expansion
        .animateTo(
          target,
          duration: duration,
          curve: Motion.md3EmphasizedDecelerate,
        )
        .whenComplete(() {
          if (!mounted) return;
          final page = target >= 1
              ? ShadePage.quickSettings
              : ShadePage.notifications;
          if (page != widget.page) widget.onPageChanged?.call(page);
        });
  }

  void _dragStart(DragStartDetails _) {
    _drag = null;
    _closeDistance = 0;
    _expansion.stop();
  }

  void _dragUpdate(DragUpdateDetails details) => _dragBy(details.delta.dy);

  /// Starts moving the shade itself (closing it) with the drag.
  void _startClosing() {
    _drag = _DragMode.closing;
    ref
        .read(referenceShellProvider.notifier)
        .startQuickSettingsDrag(progress: widget.progress.value);
  }

  void _dragBy(double dy) {
    final controller = ref.read(referenceShellProvider.notifier);
    if (_drag == null) {
      if (dy > 0) {
        _drag = _expansion.value < 1 ? _DragMode.expansion : _DragMode.none;
      } else if (dy < 0) {
        if (_expansion.value > 0) {
          _drag = _DragMode.expansion;
        } else {
          _startClosing();
        }
      } else {
        return;
      }
    }
    switch (_drag!) {
      case _DragMode.expansion:
        final next = _expansion.value + dy / _expansionTravel;
        if (next >= 0) {
          _expansion.value = next;
          break;
        }
        // Pushed past the first pull: the same drag closes the shade.
        _expansion.value = 0;
        _startClosing();
        _dragBy(next * _expansionTravel);
      case _DragMode.closing:
        _closeDistance += dy;
        final scale = PixelShadeViewport.scaleOf(context);
        controller.updateQuickSettingsDrag(
          Offset(
            0,
            dy *
                scale *
                ReferenceShellMetrics.quickSettingsDragScale(
                  MediaQuery.sizeOf(context) * scale,
                ),
          ),
        );
      case _DragMode.none:
        break;
    }
  }

  void _dragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final controller = ref.read(referenceShellProvider.notifier);
    switch (_drag) {
      case _DragMode.expansion:
        final target = velocity > 300
            ? 1.0
            : velocity < -300
            ? 0.0
            : (_expansion.value >= 0.5 ? 1.0 : 0.0);
        _settle(target, velocity: velocity);
      case _DragMode.closing:
        if (_closeDistance <= -32 || velocity <= -500) {
          controller.closeQuickSettings(releaseVelocity: velocity);
        } else {
          controller.endQuickSettingsDrag(velocity);
        }
      case _DragMode.none || null:
        break;
    }
    _drag = null;
  }

  /// A scrolling notification list pulled down past its top opens the
  /// full quick settings, as a drag on the rest of the shade does.
  bool _onListScroll(ScrollNotification notification) {
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        (notification.overscroll < 0 || _drag != null)) {
      if (_drag == null) _dragStart(DragStartDetails());
      _dragBy(-notification.overscroll);
    } else if (notification is ScrollEndNotification && _drag != null) {
      _dragEnd(
        DragEndDetails(
          primaryVelocity: notification.dragDetails?.primaryVelocity ?? 0,
        ),
      );
    }
    return false;
  }

  void _openSettingsPage(String page) {
    ref.read(referenceShellProvider.notifier).closeQuickSettings();
    ref.read(denialBridgeProvider).launchApplication(<String>[
      'denial-phone-settings',
      page,
    ]);
  }

  List<Widget> _tiles(BuildContext context) {
    final ref = this.ref;
    final l10n = context.l10n;
    final profile = ref.watch(
      quickSettingsProvider.select((state) => state.profile),
    );
    final network = ref.watch(networkConnectivityProvider);
    final networkController = ref.read(networkConnectivityProvider.notifier);
    final bluetooth = ref.watch(bluetoothProvider);
    final bluetoothController = ref.read(bluetoothProvider.notifier);
    final doNotDisturb = ref.watch(
      desktopNotificationsProvider.select((state) => state.doNotDisturb),
    );
    final settingsReady =
        ref.watch(shellSettingsSyncStatusProvider).phase ==
        ShellSettingsSyncPhase.ready;
    final rotationLock = ref.watch(rotationLockProvider);
    final recording = ref.watch(screenRecordingProvider);
    final presentation = ref.watch(referenceShellPresentationProvider);
    final singleOutput =
        (ref
                .watch(sceneDisplayLayoutProvider(ShellPart.of(context)))
                ?.outputs
                .length ??
            0) <=
        1;
    final snapshot = network.snapshot;
    return <Widget>[
      QuickTile(
        icon: Icons.wifi_rounded,
        onSettings: () => _openSettingsPage('wifi'),
        title: l10n.commonWifi,
        subtitle: wifiStatusLabel(network, l10n),
        active: snapshot.wirelessEnabled && snapshot.wifiDeviceAvailable,
        enabled:
            !network.initializing &&
            snapshot.serviceAvailable &&
            snapshot.wifiDeviceAvailable &&
            snapshot.wirelessHardwareEnabled &&
            snapshot.radioPermission != NetworkPermission.denied &&
            !network.radioChanging,
        busy: network.radioChanging,
        wide: true,
        onTap: networkController.toggleWireless,
        onDetails: (origin) => showQuickSettingsDialog(
          ref,
          keyName: 'wifi-details',
          debugLabel: 'Wi-Fi details',
          origin: origin,
          builder: (close) => QuickSettingsWifiDialog(
            onClose: close,
            onOpenSettings: () {
              close();
              _openSettingsPage('wifi');
            },
          ),
        ),
      ),
      QuickTile(
        icon: Icons.bluetooth_rounded,
        onSettings: () => _openSettingsPage('bluetooth'),
        title: l10n.commonBluetooth,
        subtitle: bluetoothStatusLabel(bluetooth, l10n),
        active: bluetooth.powered && bluetooth.available,
        enabled:
            !bluetooth.initializing &&
            bluetooth.serviceAvailable &&
            bluetooth.available &&
            !bluetooth.powerChanging,
        busy: bluetooth.powerChanging,
        wide: true,
        onTap: bluetoothController.togglePower,
        onDetails: (origin) => showQuickSettingsDialog(
          ref,
          keyName: 'bluetooth-details',
          debugLabel: 'Bluetooth details',
          origin: origin,
          builder: (close) => QuickSettingsBluetoothDialog(
            onClose: close,
            onOpenSettings: () {
              close();
              _openSettingsPage('bluetooth');
            },
          ),
        ),
      ),
      QuickTile(
        icon: Icons.do_not_disturb_on_rounded,
        onSettings: () => _openSettingsPage('notifications'),
        title: l10n.quickSettingsSilent,
        active: doNotDisturb,
        enabled: settingsReady,
        onTap: ref
            .read(desktopNotificationsProvider.notifier)
            .toggleDoNotDisturb,
      ),
      if (rotationLock.supported)
        QuickTile(
          icon: rotationLock.locked
              ? Icons.screen_lock_rotation_rounded
              : Icons.screen_rotation_rounded,
          title: l10n.quickSettingsAutoRotate,
          onSettings: () => _openSettingsPage('display'),
          active: !rotationLock.locked,
          enabled: !rotationLock.busy,
          busy: rotationLock.busy,
          onTap: () => ref.read(rotationLockProvider.notifier).toggle(),
        ),
      QuickTile(
        icon: profileIcon(profile),
        onSettings: () => _openSettingsPage('battery'),
        title: profileLabel(profile, l10n),
        active: profile != PowerProfile.balanced,
        onTap: ref.read(quickSettingsProvider.notifier).cycleProfile,
      ),
      if (recording.available)
        QuickTile(
          icon: recording.recording
              ? Icons.stop_circle_rounded
              : Icons.radio_button_checked_rounded,
          title: recording.recording
              ? l10n.quickSettingsRecording
              : l10n.quickSettingsScreenRecording,
          active: recording.recording,
          enabled: !recording.busy,
          busy: recording.busy,
          onTap: () => ref.read(screenRecordingProvider.notifier).toggle(),
        ),
      MobileDataTile(onSettings: () => _openSettingsPage('mobile')),
      if (singleOutput)
        QuickTile(
          icon: Icons.desktop_windows_rounded,
          onSettings: () => _openSettingsPage('monitor'),
          title: l10n.shellPresentationDesktop,
          active: presentation == ReferenceShellProfile.desktop,
          onTap: () {
            ref.read(referenceShellProvider.notifier).closeQuickSettings();
            ref.read(referenceShellPresentationProvider.notifier).toggle();
          },
        ),
    ];
  }

  /// Rows the grid needs for [tiles] (wide tiles take two columns).
  static int _rows(List<Widget> tiles) {
    var rows = 0;
    var used = PixelQs.columns;
    for (final tile in tiles) {
      final span = tile is QuickTile && !tile.wide ? 1 : 2;
      if (used + span > PixelQs.columns) {
        rows++;
        used = 0;
      }
      used += span;
    }
    return rows;
  }

  static double _gridHeight(int rows) =>
      rows <= 0 ? 0 : rows * PixelQs.tileHeight + (rows - 1) * PixelQs.gap;

  void _openSettings() {
    ref.read(referenceShellProvider.notifier).closeQuickSettings();
    ref.read(denialBridgeProvider).launchApplication(const <String>[
      'denial-phone-settings',
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final top = math.max(8.0, padding.top);
    final tiles = _tiles(context);
    final rows = _rows(tiles);
    final fullHeight = _gridHeight(rows);
    final oneRow = _gridHeight(math.min(1, rows));
    final twoRows = _gridHeight(math.min(2, rows));
    final motion = Listenable.merge(<Listenable>[_expansion, widget.progress]);
    final handlers = ShadeDragHandlers(
      onStart: _dragStart,
      onUpdate: _dragUpdate,
      onEnd: _dragEnd,
    );
    final tilesArea = RepaintBoundary(
      child: AnimatedBuilder(
        animation: motion,
        builder: (context, _) {
          final e = _expansion.value;
          final stages = _ShadeStages(widget.progress.value, closing: _wasOpen);
          // The first pull shows one tile row, then unfolds the second.
          final firstHeight = oneRow + (twoRows - oneRow) * stages.secondRow;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height:
                    _collapsedHeader + (_expandedHeader - _collapsedHeader) * e,
                child: _PixelHeader(expansion: e),
              ),
              // The brightness slider grows in above the tiles.
              ClipRect(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: e,
                  child: Opacity(
                    opacity: e,
                    child: const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: _BrightnessSlider(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // The full grid, cut to its first two rows on the first pull.
              ClipRect(
                child: SizedBox(
                  height: firstHeight + (fullHeight - firstHeight) * e,
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: fullHeight,
                    maxHeight: fullHeight,
                    child: PixelTileGrid(tiles: tiles),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: ref.read(referenceShellProvider.notifier).closeQuickSettings,
      onVerticalDragStart: _dragStart,
      onVerticalDragUpdate: _dragUpdate,
      onVerticalDragEnd: _dragEnd,
      onVerticalDragCancel: () => _dragEnd(DragEndDetails(primaryVelocity: 0)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          PixelQs.margin + padding.left,
          top,
          PixelQs.margin + padding.right,
          0,
        ),
        child: AnimatedBuilder(
          animation: motion,
          child: tilesArea,
          builder: (context, tilesArea) {
            final e = _expansion.value;
            final stages = _ShadeStages(
              widget.progress.value,
              closing: _wasOpen,
            );
            final height = MediaQuery.sizeOf(context).height;
            // Closing, the notifications go up with the finger.
            final lift = -stages.lift * height * 0.5;
            final notificationsShown = stages.notifications * (1 - e * 1.4);
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // Revealed from the top while settling down into place.
                    ClipRect(
                      clipper: _RevealClipper(stages.header),
                      child: Transform.translate(
                        offset: Offset(0, -24 * (1 - stages.header)),
                        child: Opacity(
                          opacity: stages.header,
                          child: tilesArea,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Notifications below the first pull's tiles; the full
                    // quick settings push them away.
                    Expanded(
                      child: IgnorePointer(
                        ignoring: e > 0.01,
                        child: Opacity(
                          opacity: notificationsShown.clamp(0.0, 1.0),
                          child: Transform.translate(
                            offset: Offset(
                              0,
                              120 * e + lift + 12 * (1 - stages.notifications),
                            ),
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _onListScroll,
                              child: _Notifications(
                                progress: widget.progress,
                                closed: widget.closed,
                                active: widget.active && e < 0.01,
                                drag: handlers,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // The full quick settings' footer, at the bottom of the screen.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: math.max(16.0, padding.bottom + 8),
                  child: IgnorePointer(
                    ignoring: e < 0.99,
                    child: Opacity(
                      opacity: ((e - 0.5) * 2).clamp(0.0, 1.0),
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: ShadeActions(
                          onOpenPower: () => showPowerSessionSurface(ref),
                          onOpenSettings: _openSettings,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The shade's header: the status row (time, date, status icons) on the
/// first pull; on the full quick settings a large clock with the date and
/// the network's name.
class _PixelHeader extends ConsumerWidget {
  const _PixelHeader({required this.expansion});

  final double expansion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = phoneSchemeOf(context);
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final time = localizedTime(context, now);
    // Android's short date ("Sat, 21 Nov"), which always fits.
    final date = localizedShortDate(context, now);
    final battery = ref.watch(batteryProvider);
    final operator = ref.watch(mobileNetworkProvider).value?.operatorName ?? '';
    final e = expansion;
    final text = TextStyle(
      color: scheme.onSurface,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    // The cluster is drawn in Denial's units; in dp it would come out
    // larger than Android's.
    final icons = StatusCluster(
      battery: battery,
      color: scheme.onSurface,
      scale: 0.82,
    );
    final collapsed = Row(
      children: <Widget>[
        Text(time, style: text),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            date,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text,
          ),
        ),
        icons,
      ],
    );
    final expanded = Column(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              time,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 40,
                fontWeight: FontWeight.w500,
                height: 1,
              ),
            ),
            const Spacer(),
            if (operator.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(operator.toUpperCase(), style: text),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                date,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text,
              ),
            ),
            icons,
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
    // The owner keeps the header's time, date and status text at their
    // full size: undo the shade's text scale here.
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) / phoneTextScale,
        ),
      ),
      child: _headerStack(e, collapsed, expanded),
    );
  }

  Widget _headerStack(double e, Widget collapsed, Widget expanded) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (e < 1)
            Opacity(
              opacity: (1 - e * 2).clamp(0.0, 1.0),
              child: Align(alignment: Alignment.topCenter, child: collapsed),
            ),
          if (e > 0)
            Opacity(
              opacity: ((e - 0.4) / 0.6).clamp(0.0, 1.0),
              child: ClipRect(child: expanded),
            ),
        ],
      ),
    );
  }
}

class _BrightnessSlider extends ConsumerWidget {
  const _BrightnessSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(
      sceneDisplayLayoutProvider(ShellPart.of(context))
          .select((layout) => layout?.mainOutput),
    );
    final brightness = ref.watch(
      displayBrightnessProvider.select(
        (state) => state.levels[output?.monitorId] ?? 0.72,
      ),
    );
    final controller = ref.read(displayBrightnessProvider.notifier);
    return PixelBrightnessSlider(
      value: brightness,
      onChanged: (value) {
        if (output != null) controller.setLevel(output, value);
      },
      onChangeEnd: (value) {
        if (output != null) controller.commitLevel(output, value);
      },
    );
  }
}

class _Notifications extends ConsumerWidget {
  const _Notifications({
    required this.progress,
    required this.closed,
    required this.active,
    required this.drag,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;
  final ShadeDragHandlers drag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empty = ref.watch(
      desktopNotificationsProvider.select((state) => state.history.isEmpty),
    );
    if (empty) return const _EmptyNotifications();
    return _DenialNotificationScale(
      child: MobileNotificationHistory(
        progress: progress,
        closed: closed,
        active: active,
        drag: drag,
      ),
    );
  }
}

class _EmptyNotifications extends StatelessWidget {
  const _EmptyNotifications();

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.6),
        child: Text(
          context.l10n.notificationsNone,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Draws Denial's own notification cards at the size they had before the
/// shade moved to Android's dp (they were laid out for the ColorOS reference
/// geometry). Goes when the cards are redone in Android's style.
class _DenialNotificationScale extends StatelessWidget {
  const _DenialNotificationScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = PixelShadeViewport.scaleOf(context);
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final native = Size(
          constraints.maxWidth * scale,
          constraints.maxHeight * scale,
        );
        final screenWidth = (constraints.maxWidth + PixelQs.margin * 2) * scale;
        final reference = colorOsShadeScaleForViewport(
          Size(screenWidth, screenWidth * 2),
        );
        final referenceSize = native / reference;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: native.width,
            maxWidth: native.width,
            minHeight: native.height,
            maxHeight: native.height,
            child: Transform.scale(
              scale: reference / scale,
              alignment: Alignment.topLeft,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: referenceSize.width,
                maxWidth: referenceSize.width,
                minHeight: referenceSize.height,
                maxHeight: referenceSize.height,
                child: MediaQuery(
                  data: media.copyWith(
                    size: referenceSize,
                    devicePixelRatio:
                        media.devicePixelRatio / scale * reference,
                    textScaler: TextScaler.linear(1 / reference),
                    padding: EdgeInsets.zero,
                    viewPadding: EdgeInsets.zero,
                  ),
                  child: ShadeReferenceGeometry(scale: reference, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Where each part of the shade is along Android's pull, from the shade's
/// progress (the finger's share of the screen height). Opening, the blur
/// comes first, then the header and the first tile row are revealed from the
/// top, the notifications fade in and the second tile row unfolds. Closing an
/// open shade runs the same stages backwards over the first part of the
/// push, so the shade answers the finger at once.
class _ShadeStages {
  factory _ShadeStages(double progress, {required bool closing}) {
    final p = progress.clamp(0.0, 1.0);
    double stage(double begin, double end) =>
        Curves.easeOut.transform(((p - begin) / (end - begin)).clamp(0.0, 1.0));
    return closing
        ? _ShadeStages._(
            header: stage(0.45, 0.72),
            notifications: stage(0.76, 0.97),
            secondRow: stage(0.66, 0.9),
            lift: 1 - p,
          )
        : _ShadeStages._(
            header: stage(0.15, 0.35),
            notifications: stage(0.33, 0.5),
            secondRow: stage(0.45, 0.6),
            lift: 0,
          );
  }

  const _ShadeStages._({
    required this.header,
    required this.notifications,
    required this.secondRow,
    required this.lift,
  });

  final double header;
  final double notifications;
  final double secondRow;

  /// The finger's travel since an open shade started closing, as a share of
  /// the screen height.
  final double lift;
}

/// Shows the top [fraction] of its child.
class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height * fraction);

  @override
  bool shouldReclip(_RevealClipper oldClipper) =>
      oldClipper.fraction != fraction;
}
