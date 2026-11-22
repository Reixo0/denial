import 'package:denial_desktop/src/state/reference_shell_controller.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/flashlight.dart';
import '../../state/quick_settings.dart';
import '../../state/reference_shell_presentation.dart';
import '../../state/reference_shell_profile.dart';

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
import 'quick_settings_editor.dart';
import 'quick_settings_tiles.dart';
import '../../state/qs_tile_layout.dart';

import 'mobile_notification_history.dart';
import 'shade_backdrop_scene.dart';
import 'pixel_media_card.dart';
import 'shade_dismiss_gesture.dart';
import 'shade_expansion.dart';
import 'shade_expansion_motion.dart';
import 'shade_stack_layout.dart';
import 'status_glyphs.dart';
import '../../state/phone_desk.dart';

/// The scene's backdrop frosted once, when the translucent shade can show it
/// in place of live material.
WindowBackdropCache? _frostedShadeBackdrop(BuildContext context) =>
    context.shellTheme.effectivePanelOpacity < 1
    ? WindowBackdropCache.maybeOf(context)
    : null;

final _blurFraction = Animatable<double>.fromCallback(
  AospShadeInterpolation.scrimAlpha,
);

EdgeInsets _divideInsets(EdgeInsets insets, double divisor) => EdgeInsets.only(
  left: insets.left / divisor,
  top: insets.top / divisor,
  right: insets.right / divisor,
  bottom: insets.bottom / divisor,
);

/// Android 17's notification shade and quick settings, moved by their
/// [ShadeExpansion]: its panel fraction (0 hidden, 1 open) and its quick
/// settings fraction (the quick tiles over the notifications, or the full
/// quick settings).
class QuickSettingsShade extends ConsumerWidget {
  const QuickSettingsShade({
    super.key,
    required this.expansion,
    this.active = true,
    this.closed = false,
  });

  final ShadeExpansion expansion;
  final bool active;
  final bool closed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(referenceShellProvider.notifier);
    final progress = expansion.panel;

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
          blur: expansion.blur,
          cached: false,
          child: BackdropGroup(
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ShadeDismissGesture(
                    expansion: expansion,
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
                          expansion: expansion,
                          closed: closed,
                          active: active,
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
    // Android's shade panel over its scrim (SystemUI ShadeColors).
    final panel = phoneShadePanel(phoneSchemeOf(context));
    final background = AnimatedBuilder(
      animation: progress,
      child: ColoredBox(color: panel),
      builder: (context, background) => Opacity(
        opacity: AospShadeInterpolation.scrimAlpha(progress.value),
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
                  overlayColor: Color.alphaBlend(panel, ShadeBackdropScene.dim),
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
            final blur = AospShadeInterpolation.scrimAlpha(progress.value);
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
/// [width] dp, and the whole shade, text included, is scaled to fill the
/// real screen.
class PixelShadeViewport extends StatelessWidget {
  const PixelShadeViewport({
    super.key,
    this.width = androidWidth,
    required this.child,
  });

  /// Android's width on this phone, in dp: 1216 px at EvolutionX's density
  /// of 468 dpi (`wm density`), 2.925 px per dp.
  static const double androidWidth = 1216 * 160 / 468;

  /// The width the first Pixel-style parts were measured in, from
  /// screenshots, before Android's density was known. Parts not yet checked
  /// against Android's code (the quick settings dialogs) still use it.
  static const double screenshotWidth = 374;

  final double width;
  final Widget child;

  /// The viewport's dp-to-pixel scale for widgets inside it.
  static double scaleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PixelScale>()?.scale ?? 1;

  static double scaleFor(Size size, {double width = androidWidth}) {
    final side = size.shortestSide;
    if (!side.isFinite || side <= 0) return 1;
    return math.max(1.0, side / width);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = scaleFor(viewport, width: width);
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
                    // Text keeps its apparent size in either width.
                    textScaler: TextScaler.linear(
                      media.textScaler.scale(1) *
                          phoneTextScale *
                          width /
                          androidWidth,
                    ),
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

class _PixelShade extends ConsumerStatefulWidget {
  const _PixelShade({
    required this.expansion,
    required this.closed,
    required this.active,
  });

  final ShadeExpansion expansion;
  final bool closed;
  final bool active;

  /// The panel's fraction, 0 hidden to 1 open.
  Animation<double> get progress => expansion.panel;

  @override
  ConsumerState<_PixelShade> createState() => _PixelShadeState();
}

class _PixelShadeState extends ConsumerState<_PixelShade>
    with SingleTickerProviderStateMixin {
  /// The full quick settings' footer actions, a 48 dp row at the bottom of
  /// the screen (AOSP's footer actions), with 8 dp above it.
  static const double _footerHeight = 56;

  /// The quick settings' fraction: 0 the quick tiles, 1 the full QS.
  AnimationController get _expansion => widget.expansion.qs;

  bool _closedBefore = true;

  /// The notification list's overscroll is moving the shade.
  bool _listDragging = false;

  /// The full quick settings' tile pages; each pull starts on the first.
  final PageController _pages = PageController();

  /// Thresholds of the quick settings' fraction that change what the parts
  /// do (the list takes touches only on the quick tiles, the pages scroll
  /// only in the full quick settings): rebuilt only when crossed.
  final ShadeListScroll _listScroll = ShadeListScroll();
  final ValueNotifier<bool> _qsCollapsed = ValueNotifier<bool>(true);
  final ValueNotifier<bool> _qsFull = ValueNotifier<bool>(false);

  /// The first tile page's motion: its two quick-tile rows are squashed
  /// (AOSP's QS squishiness) while the stack's top uncovers them, the other
  /// rows fade in with the quick settings' content.
  late final QsTileMotion _tileMotion = QsTileMotion(
    sharedRows: 2,
    squish: widget.expansion.panel.drive(
      Animatable<double>.fromCallback(ShadeReveal.tileSquish),
    ),
    contentAlpha: widget.expansion.qs.drive(
      Animatable<double>.fromCallback(
        (e) => ((e - 0.43) / 0.57).clamp(0.0, 1.0),
      ),
    ),
  );

  void _trackQs() {
    final e = _expansion.value;
    _qsCollapsed.value = e < 0.01;
    _qsFull.value = e >= 1;
  }

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_trackOpen);
    _trackOpen();
    _expansion.addListener(_trackQs);
    _trackQs();
  }

  void _trackOpen() {
    final p = widget.progress.value;
    // Each pull reads the torch again: the slider may have switched it.
    if (_closedBefore && p > 0.001) {
      Future.microtask(() {
        if (mounted) ref.read(flashlightProvider.notifier).refresh();
      });
    }
    _closedBefore = p <= 0.001;
  }

  @override
  void didUpdateWidget(covariant _PixelShade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expansion.qs != widget.expansion.qs) {
      oldWidget.expansion.qs.removeListener(_trackQs);
      widget.expansion.qs.addListener(_trackQs);
      _trackQs();
    }
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress.removeListener(_trackOpen);
      widget.progress.addListener(_trackOpen);
      _trackOpen();
    }
    if (widget.closed || !widget.active) {
      // Closed: every pull starts on the first tile page, out of editing.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pages.hasClients && (_pages.page ?? 0) != 0) _pages.jumpToPage(0);
        if (mounted && ref.read(qsEditingProvider)) {
          ref.read(qsEditingProvider.notifier).stop();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.progress.removeListener(_trackOpen);
    _expansion.removeListener(_trackQs);
    _listScroll.dispose();
    _qsCollapsed.dispose();
    _qsFull.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// A scrolling notification list pulled down past its top opens the
  /// full quick settings, as a drag on the rest of the shade does.
  bool _onListScroll(ScrollNotification notification) {
    final expansion = widget.expansion;
    final scale = PixelShadeViewport.scaleOf(context);
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        (notification.overscroll < 0 || _listDragging)) {
      if (!_listDragging) {
        _listDragging = expansion.beginDrag();
        if (!_listDragging) return false;
      }
      expansion.dragBy(-notification.overscroll * scale);
    } else if (notification is ScrollEndNotification && _listDragging) {
      _listDragging = false;
      expansion.endDrag(
        (notification.dragDetails?.primaryVelocity ?? 0) * scale,
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

  /// Every tile this phone can show, for the grid and the editor.
  List<QsTileSpec> _catalog(BuildContext context) {
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
    final flashlight = ref.watch(flashlightProvider);
    final presentation = ref.watch(referenceShellPresentationProvider);
    final singleOutput =
        (ref
                .watch(sceneDisplayLayoutProvider(ShellPart.of(context)))
                ?.outputs
                .length ??
            0) <=
        1;
    final snapshot = network.snapshot;
    return <QsTileSpec>[
      QsTileSpec(
        id: 'wifi',
        category: QsTileCategory.connectivity,
        icon: Icons.wifi_rounded,
        label: l10n.commonWifi,
        build: (wide) => QuickTile(
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
          wide: wide,
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
      ),
      QsTileSpec(
        id: 'bluetooth',
        category: QsTileCategory.connectivity,
        icon: Icons.bluetooth_rounded,
        label: l10n.commonBluetooth,
        build: (wide) => QuickTile(
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
          wide: wide,
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
      ),
      QsTileSpec(
        id: 'silent',
        category: QsTileCategory.utilities,
        icon: Icons.do_not_disturb_on_rounded,
        label: l10n.quickSettingsSilent,
        build: (wide) => QuickTile(
          icon: Icons.do_not_disturb_on_rounded,
          onSettings: () => _openSettingsPage('notifications'),
          title: l10n.quickSettingsSilent,
          active: doNotDisturb,
          enabled: settingsReady,
          wide: wide,
          onTap: ref
              .read(desktopNotificationsProvider.notifier)
              .toggleDoNotDisturb,
        ),
      ),
      if (rotationLock.supported)
        QsTileSpec(
          id: 'rotation',
          category: QsTileCategory.display,
          icon: Icons.screen_rotation_rounded,
          label: l10n.quickSettingsAutoRotate,
          build: (wide) => QuickTile(
            icon: rotationLock.locked
                ? Icons.screen_lock_rotation_rounded
                : Icons.screen_rotation_rounded,
            title: l10n.quickSettingsAutoRotate,
            onSettings: () => _openSettingsPage('display'),
            active: !rotationLock.locked,
            enabled: !rotationLock.busy,
            busy: rotationLock.busy,
            wide: wide,
            onTap: () => ref.read(rotationLockProvider.notifier).toggle(),
          ),
        ),
      QsTileSpec(
        id: 'power_profile',
        category: QsTileCategory.utilities,
        icon: profileIcon(profile),
        label: profileLabel(profile, l10n),
        build: (wide) => QuickTile(
          icon: profileIcon(profile),
          onSettings: () => _openSettingsPage('battery'),
          title: profileLabel(profile, l10n),
          active: profile != PowerProfile.balanced,
          wide: wide,
          onTap: ref.read(quickSettingsProvider.notifier).cycleProfile,
        ),
      ),
      if (flashlight.available)
        QsTileSpec(
          id: 'flashlight',
          category: QsTileCategory.utilities,
          icon: Icons.flashlight_on_rounded,
          label: l10n.quickSettingsFlashlight,
          build: (wide) => QuickTile(
            icon: flashlight.on
                ? Icons.flashlight_on_rounded
                : Icons.flashlight_off_rounded,
            title: l10n.quickSettingsFlashlight,
            active: flashlight.on,
            wide: wide,
            onTap: () => ref.read(flashlightProvider.notifier).toggle(),
          ),
        ),
      if (recording.available)
        QsTileSpec(
          id: 'screen_record',
          category: QsTileCategory.utilities,
          icon: Icons.radio_button_checked_rounded,
          label: l10n.quickSettingsScreenRecording,
          build: (wide) => QuickTile(
            icon: recording.recording
                ? Icons.stop_circle_rounded
                : Icons.radio_button_checked_rounded,
            title: recording.recording
                ? l10n.quickSettingsRecording
                : l10n.quickSettingsScreenRecording,
            active: recording.recording,
            enabled: !recording.busy,
            busy: recording.busy,
            wide: wide,
            onTap: () => ref.read(screenRecordingProvider.notifier).toggle(),
          ),
        ),
      QsTileSpec(
        id: 'mobile_data',
        category: QsTileCategory.connectivity,
        icon: Icons.swap_vert_rounded,
        label: l10n.mobileData,
        build: (wide) => MobileDataTile(
          wide: wide,
          onSettings: () => _openSettingsPage('mobile'),
        ),
      ),
      if (singleOutput)
        QsTileSpec(
          id: 'desktop',
          category: QsTileCategory.display,
          icon: Icons.desktop_windows_rounded,
          label: l10n.shellPresentationDesktop,
          build: (wide) => QuickTile(
            icon: Icons.desktop_windows_rounded,
            onSettings: () => _openSettingsPage('monitor'),
            title: l10n.shellPresentationDesktop,
            active: presentation == ReferenceShellProfile.desktop,
            wide: wide,
            onTap: () {
              ref.read(referenceShellProvider.notifier).closeQuickSettings();
              ref.read(referenceShellPresentationProvider.notifier).toggle();
            },
          ),
        ),
    ];
  }

  /// The placed tiles, in the saved order.
  List<Widget> _tiles(List<QsTileSpec> catalog) {
    final byId = <String, QsTileSpec>{
      for (final spec in catalog) spec.id: spec,
    };
    return <Widget>[
      for (final slot in ref.watch(qsTileLayoutProvider))
        if (byId[slot.id] case final spec?)
          QsTileSize(
            key: ValueKey<String>(slot.id),
            wide: slot.wide,
            child: spec.build(slot.wide),
          ),
    ];
  }

  void _openSettings() {
    ref.read(referenceShellProvider.notifier).closeQuickSettings();
    ref.read(denialBridgeProvider).launchApplication(const <String>[
      'denial-phone-settings',
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final catalog = _catalog(context);
    final tiles = _tiles(catalog);
    final pages = PixelPagedTileGrid.pagesOf(tiles);
    final rows = PixelPagedTileGrid.rowsOf(pages.isEmpty ? tiles : pages.first);
    final gridHeight = PixelPagedTileGrid.heightOf(tiles);
    // The first pull shows the first two tile rows (Android's QQS).
    final twoRows = PixelPagedTileGrid.gridHeight(math.min(2, rows));
    // The media player under the tiles: in the quick tiles only while
    // active (AOSP showsOnlyActiveMedia), in the full quick settings always.
    final mediaShown = ref.watch(
      mediaCardProvider.select((card) => card != null),
    );
    final mediaActive = ref.watch(
      mediaCardProvider.select((card) => card?.active ?? false),
    );
    final scale = PixelShadeViewport.scaleOf(context);
    // Every part is built once; the fractions only move, clip and fade
    // them (ShadeStackLayout).
    final shade = ShadeDismissGesture(
      expansion: widget.expansion,
      child: Padding(
        // The parts are placed from the top of the screen, as on
        // EvolutionX.
        padding: EdgeInsets.fromLTRB(
          PixelQs.margin + padding.left,
          0,
          PixelQs.margin + padding.right,
          0,
        ),
        child: ShadeStackLayout(
          panel: widget.progress,
          qs: _expansion,
          pullsBoth: widget.expansion.pullsBoth,
          listScroll: _listScroll,
          panelColor: phoneNotificationPanel(phoneSchemeOf(context)),
          sideMargin: PixelQs.margin,
          quickTilesHeight: twoRows,
          mediaActive: mediaActive,
          onTravel: (travel) {
            // The finger moves the notification stack 1:1 (AOSP's quick
            // settings expansion height).
            if (travel > 120) widget.expansion.qsTravel = travel * scale;
          },
          children: <Widget>[
            for (final part in _HeaderPart.values)
              ShadeStackSlot(
                part: part.slot,
                child: RepaintBoundary(child: _PixelHeader(part: part)),
              ),
            const ShadeStackSlot(
              part: ShadePart.slider,
              child: RepaintBoundary(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: _BrightnessSlider(),
                ),
              ),
            ),
            ShadeStackSlot(
              part: ShadePart.grid,
              child: RepaintBoundary(
                child: SizedBox(
                  height: gridHeight,
                  // The pages scroll only in the full quick settings.
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _qsFull,
                    builder: (context, full, _) => PixelPagedTileGrid(
                      tiles: tiles,
                      controller: _pages,
                      scrollable: full,
                      motion: _tileMotion,
                    ),
                  ),
                ),
              ),
            ),
            ShadeStackSlot(
              part: ShadePart.gridFooter,
              child: RepaintBoundary(
                child: SizedBox(
                  height: PixelPagedTileGrid.footerHeight,
                  // AOSP FooterBar: the page dots centred, the edit button
                  // at the end.
                  child: Row(
                    children: <Widget>[
                      const Spacer(),
                      PixelPagerDots(controller: _pages, count: pages.length),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: _EditButton(
                            onTap: ref.read(qsEditingProvider.notifier).start,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (mediaShown)
              const ShadeStackSlot(
                part: ShadePart.media,
                child: Padding(
                  padding: EdgeInsets.only(top: PixelMediaCard.gap),
                  child: RepaintBoundary(child: PixelMediaCard()),
                ),
              ),
            // AOSP: the footer actions (settings, power) belong to the full
            // quick settings, under the tiles; they grow in with it.
            ShadeStackSlot(
              part: ShadePart.footer,
              child: RepaintBoundary(
                child: SizedBox(
                  height: _footerHeight,
                  child: Align(
                    alignment: AlignmentDirectional.bottomEnd,
                    child: SizedBox(
                      height: 48,
                      child: Center(
                        child: ShadeActions(
                          onOpenPower: () => showPowerSessionSurface(ref),
                          onOpenSettings: _openSettings,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Notifications below the first pull's tiles; the full quick
            // settings push them away. On the first pull they come down
            // from the top squashed and fade in (AndroidStackExpansion).
            ShadeStackSlot(
              part: ShadePart.list,
              child: RepaintBoundary(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onListScroll,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _qsCollapsed,
                    builder: (context, collapsed, _) => _Notifications(
                      progress: widget.progress,
                      closed: widget.closed,
                      active: widget.active && collapsed,
                      expansion: widget.expansion,
                      scroll: _listScroll,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    // AOSP's edit mode takes the shade's place, over the same background.
    final editing = ref.watch(qsEditingProvider);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          ignoring: editing,
          child: AnimatedOpacity(
            opacity: editing ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: shade,
          ),
        ),
        if (editing)
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 200),
            builder: (context, t, child) => Opacity(opacity: t, child: child),
            child: QsTileEditor(catalog: catalog),
          ),
      ],
    );
  }
}

/// The shade's header: the status row (time, date, status icons) on the
/// first pull; on the full quick settings a large clock with the date and
/// the network's name.
/// The shade header's parts, which ShadeStackLayout moves on their own.
enum _HeaderPart {
  clock(ShadePart.clock),
  date(ShadePart.date),
  icons(ShadePart.icons),
  carrier(ShadePart.carrier);

  const _HeaderPart(this.slot);
  final ShadePart slot;
}

/// One part of the shade header (time, date, status icons, operator), at
/// the first pull's size; the full quick settings' clock is this one
/// scaled (AOSP qqs_expand_clock_scale).
class _PixelHeader extends ConsumerWidget {
  const _PixelHeader({required this.part});

  final _HeaderPart part;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = phoneSchemeOf(context);
    // The header's text and icons keep the size the owner chose (set when
    // the shade was 374 dp wide), a little larger than EvolutionX's.
    final text = TextStyle(
      color: scheme.onSurface,
      fontSize: 15.5,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final Widget child = switch (part) {
      _HeaderPart.clock => Text(
        localizedTime(
          context,
          ref.watch(clockProvider).value ?? DateTime.now(),
        ),
        style: text,
      ),
      // Android's short date ("Sat, 21 Nov"), which always fits.
      _HeaderPart.date => Text(
        localizedShortDate(
          context,
          ref.watch(clockProvider).value ?? DateTime.now(),
        ),
        maxLines: 1,
        style: text,
      ),
      // The cluster is drawn in Denial's units; in dp it would come out
      // larger than Android's.
      _HeaderPart.icons => StatusCluster(
        battery: ref.watch(batteryProvider),
        color: scheme.onSurface,
        scale: phoneStatusIconScale,
      ),
      _HeaderPart.carrier => Text(
        (ref.watch(mobileNetworkProvider).value?.operatorName ?? '')
            .toUpperCase(),
        style: text,
      ),
    };
    // The owner keeps the header's time, date and status text at their
    // full size: undo the shade's text scale here.
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(
          media.textScaler.scale(1) / phoneTextScale,
        ),
      ),
      child: IgnorePointer(child: child),
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
    required this.expansion,
    required this.scroll,
  });

  final Animation<double> progress;
  final bool closed;
  final bool active;
  final ShadeExpansion expansion;
  final ShadeListScroll scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empty = ref.watch(
      desktopNotificationsProvider.select((state) => state.history.isEmpty),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // ShadeStackLayout: the list's place below the screen's top.
        final top = constraints.maxHeight - constraints.minHeight;
        return SizedBox(
          height: constraints.maxHeight,
          child: empty
              ? Padding(
                  padding: EdgeInsets.only(top: top),
                  child: const _EmptyNotifications(),
                )
              : MobileNotificationHistory(
                  progress: progress,
                  closed: closed,
                  active: active,
                  expansion: expansion,
                  topPadding: top,
                  scroll: scroll,
                ),
        );
      },
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

/// AOSP's EditModeButton: an icon button (40 dp, the pencil, 24 dp).
class _EditButton extends StatelessWidget {
  const _EditButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Semantics(
      button: true,
      label: context.l10n.qsEditTiles,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.edit_rounded, size: 24, color: scheme.onSurface),
        ),
      ),
    );
  }
}
