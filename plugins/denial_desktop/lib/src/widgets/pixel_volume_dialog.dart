import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show GestureBinding;
import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/platform.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart' show denialBridgeProvider;
import 'package:denial_flutter_sdk/system_services.dart';

import '../state/phone_desk.dart';
import '../state/quick_settings.dart';
import '../state/system_level_hud.dart';
import 'phone_scheme.dart';
import 'pixel_volume_panel.dart';
import 'shade/quick_settings_panel.dart' show PixelShadeViewport;
import 'shade/shade_expansion_motion.dart' show androidAnimatorScale;

/// The volume of each kind of sound, while the dialog is up; empty when the
/// system has no separate volumes.
final _audioRolesProvider = StreamProvider.autoDispose<List<AudioRoleLevel>>((
  ref,
) {
  final audio = ref.watch(audioServiceProvider);
  audio.requestRoles();
  return audio.roleStates;
});

/// Android 16/17's volume dialog (SystemUI `volume/dialog`, the vertical
/// layout as the owner's phone shows it): a 60 dp panel at the right edge
/// with one Material 3 slider, a settings button under it, sliding in from
/// the edge on a spring and leaving after 3 s. The settings button opens one
/// floating slider per kind of sound beside the panel (Android's floating
/// sliders), where the system keeps separate volumes.
class PixelVolumeDialog extends ConsumerStatefulWidget {
  const PixelVolumeDialog({super.key});

  @override
  ConsumerState<PixelVolumeDialog> createState() => _PixelVolumeDialogState();
}

/// Sizes from SystemUI's `volume_dialog_*` dimens, in dp.
abstract final class _Dimens {
  static const double windowWidth = 176;
  static const double windowMargin = 12;
  static const double sliderWidth = 52;
  static const double sliderMaxHeight = 254;
  static const double sliderVerticalMargin = 124;
  static const double width = 60;
  static const double backgroundBottom = 6;
  static const double radius = 30;
  static const double spacing = 4;
  static const double button = 48;
  static const double maxDeviation = 56;
}

class _PixelVolumeDialogState extends ConsumerState<PixelVolumeDialog>
    with TickerProviderStateMixin {
  // VolumeDialogVisibilityInteractor: dismissed 3 s after the last change.
  static const Duration _timeout = Duration(seconds: 3);
  static const double _scaleFactor =
      androidAnimatorScale * androidAnimatorScale;

  // VolumeDialogViewBinder: SpringForce 700, damping 0.9.
  static final SpringDescription _visibilitySpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 700 / _scaleFactor,
        ratio: 0.9,
      );

  // VolumeDialogOverscrollViewBinder: SpringForce 800, damping 0.6.
  static final SpringDescription _overscrollSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 800 / _scaleFactor,
        ratio: 0.6,
      );

  // VolumeDialogOverscrollViewModel.offsetInterpolator.
  static const Curve _overscrollCurve = Cubic(0.15, 0, 0.2, 1);

  late final AnimationController _visibility = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _overscroll = AnimationController.unbounded(
    vsync: this,
  );
  // volume_dialog_ringer_drawer_motion_scene: 400 ms,
  // cubic(0.05, 0.7, 0.1, 1), at the phone's 0.75.
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (400 * androidAnimatorScale).round()),
  );
  static const Curve _drawerCurve = Cubic(0.05, 0.7, 0.1, 1);

  /// CLOSE_DRAWER_DELAY: a choice closes the drawer 300 ms later.
  static const Duration _closeDrawerDelay = Duration(milliseconds: 300);
  Timer? _closeDrawer;

  Timer? _hideTimer;
  StreamSubscription<DenialShellActionEvent>? _shellActions;
  int _revision = -1;
  bool _shown = false;
  double _level = 0;
  bool _muted = false;
  bool _drawerOpen = false;

  /// The volume panel (bottom sheet), opened from the settings button.
  bool _panelOpen = false;
  bool _panelShowing = false;
  Timer? _panelGone;

  /// A finger is on a slider: the dialog stays.
  int _held = 0;

  /// Where the dialog takes touches, in this widget's coordinates.
  List<Rect> _hitRects = const <Rect>[];

  @override
  void initState() {
    super.initState();
    _visibility.addListener(_visibilityChanged);
    // A touch anywhere else dismisses it and still reaches what it touched.
    _shellActions = ref.read(denialBridgeProvider).shellActions.listen((event) {
      if (event.action == DenialShellAction.clientPointerPressed) _dismiss();
    });
    GestureBinding.instance.pointerRouter.addGlobalRoute(_globalPointer);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    unawaited(_shellActions?.cancel());
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_globalPointer);
    _visibility.dispose();
    _overscroll.dispose();
    _drawer.dispose();
    _closeDrawer?.cancel();
    _panelGone?.cancel();
    super.dispose();
  }

  bool _onScreen = false;

  void _visibilityChanged() {
    final onScreen = _shown || _visibility.value > 0.001;
    if (onScreen != _onScreen && mounted) setState(() => _onScreen = onScreen);
  }

  void _globalPointer(PointerEvent event) {
    if (event is! PointerDownEvent || !_shown) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    if (_hitRects.any((rect) => rect.contains(local))) return;
    scheduleMicrotask(() {
      if (mounted) _dismiss();
    });
  }

  void _present(SystemLevelHudState hud) {
    if (hud.kind != SystemLevelHudKind.audio || !hud.visible) return;
    if (hud.revision == _revision) return;
    _revision = hud.revision;
    // While a finger is on a slider, the levels coming back are its own.
    if (_held > 0) {
      _armHide();
      return;
    }
    setState(() {
      _muted = hud.muted;
      _level = hud.level;
    });
    _show();
  }

  void _show() {
    if (!_shown) {
      _shown = true;
      _animate(_visibility, 1, _visibilitySpring);
      _visibilityChanged();
    }
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_timeout, () {
      if (mounted && _held == 0) _dismiss();
    });
  }

  void _dismiss() {
    if (_held > 0 || !_shown) return;
    _hideTimer?.cancel();
    _shown = false;
    _animate(_visibility, 0, _visibilitySpring);
    _setDrawer(false);
  }

  void _animate(
    AnimationController controller,
    double target,
    SpringDescription spring,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = target;
      return;
    }
    controller.animateWith(
      SpringSimulation(
        spring,
        controller.value,
        target,
        controller.velocity,
        tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
      ),
    );
  }

  void _setDrawer(bool open) {
    _closeDrawer?.cancel();
    if (open == _drawerOpen) return;
    if (mounted) setState(() => _drawerOpen = open);
    if (MediaQuery.disableAnimationsOf(context)) {
      _drawer.value = open ? 1 : 0;
    } else if (open) {
      _drawer.forward();
    } else {
      _drawer.reverse();
    }
  }

  /// The ringer button: the selected one opens or closes the drawer; another
  /// becomes the mode and the drawer closes a moment later.
  void _ringerTap(PhoneRingerMode mode) {
    final current = ref.read(shellSettingsProvider).sound.ringerMode;
    _armHide();
    if (!_drawerOpen) {
      _setDrawer(true);
      return;
    }
    if (mode == current) {
      _setDrawer(false);
      return;
    }
    ref.read(shellSettingsProvider.notifier).setRingerMode(mode);
    _closeDrawer?.cancel();
    _closeDrawer = Timer(_closeDrawerDelay, () {
      if (mounted) _setDrawer(false);
    });
  }

  void _openPanel() {
    _hideTimer?.cancel();
    _panelGone?.cancel();
    _shown = false;
    _visibility.value = 0;
    _setDrawer(false);
    setState(() {
      _panelOpen = true;
      _panelShowing = true;
    });
  }

  void _closePanel() {
    setState(() => _panelOpen = false);
    _panelGone = Timer(const Duration(milliseconds: 400), () {
      if (mounted && !_panelOpen) setState(() => _panelShowing = false);
    });
  }

  void _openSoundSettings() {
    _closePanel();
    ref.read(denialBridgeProvider).launchApplication(<String>[
      'denial-phone-settings',
      'sound',
    ]);
  }

  void _grab() {
    _held++;
    _hideTimer?.cancel();
  }

  void _letGo() {
    _held = math.max(0, _held - 1);
    if (_held == 0) _armHide();
  }

  // The main slider sets whichever volume is sounding.
  void _mainStart() {
    _grab();
    ref.read(quickSettingsProvider.notifier).beginVolumeInteraction();
  }

  // The slider draws the finger's level itself; the dialog rebuilds once
  // the finger lifts.
  void _mainChange(double level) {
    _level = level;
    _muted = false;
    ref.read(quickSettingsProvider.notifier).setDashboardVolume(level);
  }

  void _mainEnd(double level) {
    ref.read(quickSettingsProvider.notifier).commitDashboardVolume(level);
    setState(() => _level = level);
    _letGo();
  }

  void _limit() => ref.read(hapticsServiceProvider).pulse();

  /// Past either end the finger pulls the whole dialog, a third as far and
  /// at most 56 dp (VolumeDialogOverscrollViewModel).
  void _overscrollBy(double beyond) {
    _overscroll.stop();
    final travel = math.min(beyond.abs() / 3, _Dimens.maxDeviation);
    _overscroll.value =
        beyond.sign *
        _Dimens.maxDeviation *
        _overscrollCurve.transform(travel / _Dimens.maxDeviation);
  }

  void _overscrollRelease() => _animate(_overscroll, 0, _overscrollSpring);

  @override
  Widget build(BuildContext context) {
    final part = ShellPart.of(context);
    ref.listen<SystemLevelHudState?>(systemLevelHudProvider, (_, hud) {
      if (hud == null) return;
      if (part == ShellPart.whole ||
          ref.read(activeShellPartProvider) == part) {
        _present(hud);
      }
    });
    if (!_onScreen && !_panelShowing) return const SizedBox.shrink();
    final roles =
        ref.watch(_audioRolesProvider).value ?? const <AudioRoleLevel>[];
    final ringer = ref.watch(
      shellSettingsProvider.select((settings) => settings.sound.ringerMode),
    );
    return PixelShadeViewport(
      child: Builder(
        builder: (context) => Stack(
          fit: StackFit.expand,
          children: [
            // The dialog shows over the panel, as on Android.
            if (_panelShowing)
              PixelVolumePanel(
                open: _panelOpen,
                roles: roles,
                ringer: ringer,
                scheme: phoneSchemeOf(context),
                onClose: _closePanel,
                onSettings: _openSoundSettings,
                onRinger: (mode) => ref
                    .read(shellSettingsProvider.notifier)
                    .setRingerMode(mode),
              ),
            if (_onScreen) _layout(context, roles, ringer),
          ],
        ),
      ),
    );
  }

  Widget _layout(
    BuildContext context,
    List<AudioRoleLevel> roles,
    PhoneRingerMode ringer,
  ) {
    final scheme = phoneSchemeOf(context);
    final view = MediaQuery.sizeOf(context);
    final scale = PixelShadeViewport.scaleOf(context);
    final sliderHeight = math.min(
      _Dimens.sliderMaxHeight,
      view.height - 2 * _Dimens.sliderVerticalMargin,
    );
    final sliderTop = (view.height - sliderHeight) / 2;
    final sliderRight = view.width - _Dimens.windowMargin;
    final slider = Rect.fromLTWH(
      sliderRight - _Dimens.sliderWidth,
      sliderTop,
      _Dimens.sliderWidth,
      sliderHeight,
    );
    final settings = Rect.fromCenter(
      center: Offset(
        slider.center.dx,
        slider.bottom + _Dimens.spacing + _Dimens.button / 2,
      ),
      width: _Dimens.button,
      height: _Dimens.button,
    );
    // The ringer drawer ends 4 dp over the slider; its background reaches
    // 6 dp past that, 60 dp tall closed and three buttons + 12 dp open.
    final drawerBottom = slider.top - _Dimens.spacing;
    final buttons = PhoneRingerMode.values.length;
    double backgroundTop(double open) =>
        drawerBottom +
        _Dimens.backgroundBottom -
        (_Dimens.width +
            open *
                (buttons * _Dimens.button +
                    2 * _Dimens.backgroundBottom -
                    _Dimens.width));
    final rest = Rect.fromLTRB(
      slider.center.dx - _Dimens.width / 2,
      backgroundTop(0),
      slider.center.dx + _Dimens.width / 2,
      settings.bottom + _Dimens.backgroundBottom,
    );
    final open = Rect.fromLTRB(
      rest.left,
      backgroundTop(1),
      rest.right,
      rest.bottom,
    );
    final hits = <Rect>[_drawerOpen ? open : rest];
    _hitRects = [for (final rect in hits) _scaled(rect, scale)];
    // Effect 0 over a 23 dp blur, as Android 17 draws it with blur on. The
    // colour's value on the phone is not known; this is a guess.
    final panelColor = scheme.primaryContainer.withValues(alpha: 0x8a / 255);
    final percent = ((_muted ? 0 : _level) * 100).round();
    final active = roles.where((role) => role.active).firstOrNull?.role;
    // Vibrate and mute hold the ring and notification streams at zero.
    final ringerMuted =
        ringer != PhoneRingerMode.normal &&
        (active == AudioRole.ringtone || active == AudioRole.notification);

    final dialog = Stack(
      fit: StackFit.expand,
      children: [
        AnimatedBuilder(
          animation: _drawer,
          builder: (context, _) {
            final t = _drawerCurve.transform(_drawer.value);
            return Positioned.fromRect(
              rect: Rect.fromLTRB(
                rest.left,
                backgroundTop(t),
                rest.right,
                rest.bottom,
              ),
              child: IgnorePointer(
                child: ShellBackdropBlur(
                  separateChild: true,
                  strength: 23 / 34,
                  borderRadius: BorderRadius.circular(_Dimens.radius),
                  child: ColoredBox(color: panelColor),
                ),
              ),
            );
          },
        ),
        for (final (index, mode) in _ringerOrder.indexed)
          _RingerButton(
            mode: mode,
            selected: mode == ringer,
            // From the bottom, ring then mute then vibrate.
            openBottom: drawerBottom - index * _Dimens.button,
            closedBottom: drawerBottom,
            centerX: slider.center.dx,
            drawer: _drawer,
            curve: _drawerCurve,
            scheme: scheme,
            onTap: () => _ringerTap(mode),
          ),
        Positioned.fromRect(
          rect: slider,
          child: Semantics(
            container: true,
            slider: true,
            label: context.l10n.outputVolumeSemantics,
            value: context.l10n.percentCompact(percent),
            increasedValue: context.l10n.percentCompact(
              (percent + 5).clamp(0, 100),
            ),
            decreasedValue: context.l10n.percentCompact(
              (percent - 5).clamp(0, 100),
            ),
            onIncrease: () {
              _grab();
              _mainChange((_level + 0.05).clamp(0.0, 1.0));
              _mainEnd(_level);
            },
            onDecrease: () {
              _grab();
              _mainChange((_level - 0.05).clamp(0.0, 1.0));
              _mainEnd(_level);
            },
            child: _VolumeSlider(
              value: _muted || ringerMuted ? 0 : _level,
              icon: ringerMuted && ringer == PhoneRingerMode.vibrate
                  ? Icons.vibration_rounded
                  : _streamIcon(
                      active,
                      muted: _muted || ringerMuted || _level <= 0,
                    ),
              scheme: scheme,
              onStart: _mainStart,
              onChanged: _mainChange,
              onEnd: _mainEnd,
              onLimit: _limit,
              onOverscroll: _overscrollBy,
              onOverscrollEnd: _overscrollRelease,
            ),
          ),
        ),
        Positioned.fromRect(
          rect: settings,
          child: Semantics(
            button: true,
            label: context.l10n.volumeRolesShow,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openPanel,
              // ic_tuner, tinted materialColorPrimary.
              child: Icon(Icons.tune_rounded, size: 24, color: scheme.primary),
            ),
          ),
        ),
      ],
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ShellInputRegion(
            debugLabel: 'Mobile volume dismissal',
            active: _shown,
            pointerPolicy: ShellPointerPolicy.none,
            observeClientPointerPresses: true,
            child: const SizedBox.shrink(),
          ),
        ),
        // The touch areas stay where the dialog rests, so the input layout
        // is published once, not on every frame of its motion.
        for (final (i, rect) in hits.indexed)
          Positioned.fromRect(
            rect: rect,
            child: ShellInputRegion(
              debugLabel: 'Mobile volume $i',
              active: _shown,
              child: const SizedBox.shrink(),
            ),
          ),
        AnimatedBuilder(
          animation: Listenable.merge([_visibility, _overscroll]),
          builder: (context, child) {
            final f = _visibility.value;
            // applyAnimationProgress: alpha = ceil(fraction), translationX =
            // lerp(width, 0, fraction).
            return Opacity(
              opacity: f > 0 ? 1 : 0,
              child: Transform.translate(
                offset: Offset(
                  _Dimens.windowWidth * (1 - f),
                  _overscroll.value,
                ),
                child: IgnorePointer(ignoring: !_shown, child: child),
              ),
            );
          },
          child: dialog,
        ),
      ],
    );
  }

  /// Bottom to top in the open drawer, as on the phone.
  static const List<PhoneRingerMode> _ringerOrder = <PhoneRingerMode>[
    PhoneRingerMode.normal,
    PhoneRingerMode.silent,
    PhoneRingerMode.vibrate,
  ];

  static Rect _scaled(Rect rect, double scale) => Rect.fromLTRB(
    rect.left * scale,
    rect.top * scale,
    rect.right * scale,
    rect.bottom * scale,
  );

  /// VolumeDialogSliderIconProvider: the sounding stream's icon, its muted
  /// form at zero.
  static IconData _streamIcon(
    AudioRole? role, {
    required bool muted,
  }) => switch (role ?? AudioRole.media) {
    AudioRole.media =>
      muted ? Icons.music_off_rounded : Icons.music_note_rounded,
    AudioRole.call => Icons.call_rounded,
    AudioRole.ringtone =>
      muted ? Icons.notifications_off_outlined : Icons.ring_volume_rounded,
    AudioRole.notification =>
      muted ? Icons.notifications_off_outlined : Icons.notifications_rounded,
    AudioRole.alarm => muted ? Icons.alarm_off_rounded : Icons.alarm_rounded,
  };
}

/// SystemUI's vertical volume slider (VolumeDialogSlider with SliderTrack):
/// Material 3's expressive slider turned upright, filling from the bottom.
/// Track 40 dp wide, 12 dp outer and 2 dp inner corners, 6 dp gaps around a
/// 52 x 4 dp thumb that narrows to half while held; the stream's 20 dp icon
/// sits at the top of the empty part, or just under the thumb once that part
/// is too short for it. A press moves the thumb to the finger.
class _VolumeSlider extends StatefulWidget {
  const _VolumeSlider({
    required this.value,
    required this.icon,
    required this.scheme,
    required this.onStart,
    required this.onChanged,
    required this.onEnd,
    required this.onLimit,
    this.onOverscroll,
    this.onOverscrollEnd,
  });

  final double value;
  final IconData icon;
  final ColorScheme scheme;
  final VoidCallback onStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onEnd;
  final VoidCallback onLimit;
  final ValueChanged<double>? onOverscroll;
  final VoidCallback? onOverscrollEnd;

  @override
  State<_VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<_VolumeSlider>
    with SingleTickerProviderStateMixin {
  // AOSP volume Slider: outside changes (keys, other apps) spring to the
  // new value, no bounce, Compose's StiffnessMedium; the finger moves it
  // directly.
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 1500 / (androidAnimatorScale * androidAnimatorScale),
    ratio: 1,
  );

  // debouncedValueState: for 100 ms after a drag, values coming back from
  // the system are ignored, so the thumb does not jump to a stale one.
  static const Duration _debounce = Duration(milliseconds: 100);

  late final AnimationController _shown = AnimationController.unbounded(
    vsync: this,
    value: widget.value,
  );
  int? _pointer;
  double? _value;
  bool _atLimit = false;
  Timer? _debounceTimer;

  @override
  void didUpdateWidget(_VolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _follow();
  }

  /// Springs the thumb to the incoming value unless a finger or the
  /// debounce after one holds it.
  void _follow() {
    if (_pointer != null || _debounceTimer != null) return;
    final target = widget.value;
    if (_shown.value == target && !_shown.isAnimating) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _shown.value = target;
      return;
    }
    _shown.animateWith(
      SpringSimulation(
        _spring,
        _shown.value,
        target,
        _shown.velocity,
        tolerance: const Tolerance(distance: 0.0005, velocity: 0.01),
      ),
    );
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _shown.dispose();
    super.dispose();
  }

  double _valueAt(double y, double height) =>
      1 -
      (y - _VolumePainter.thumbHeight / 2) /
          (height - _VolumePainter.thumbHeight);

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _shown.stop();
    widget.onStart();
    _move(event.localPosition.dy);
  }

  void _move(double y) {
    final height = context.size?.height ?? 1;
    final raw = _valueAt(y, height);
    final value = raw.clamp(0.0, 1.0);
    final atLimit = raw <= 0 || raw >= 1;
    if (atLimit && !_atLimit) widget.onLimit();
    _atLimit = atLimit;
    // Past an end, the distance beyond it in dp (down positive).
    final usable = height - _VolumePainter.thumbHeight;
    final beyond = raw < 0
        ? -raw * usable
        : raw > 1
        ? -(raw - 1) * usable
        : 0.0;
    widget.onOverscroll?.call(beyond);
    _value = value;
    _shown.value = value;
    widget.onChanged(value);
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    final value = _value ?? widget.value;
    widget.onOverscrollEnd?.call();
    _value = null;
    _atLimit = false;
    _debounceTimer = Timer(_debounce, () {
      _debounceTimer = null;
      if (mounted) _follow();
    });
    setState(() {});
    widget.onEnd(value);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: (event) {
        if (event.pointer == _pointer) _move(event.localPosition.dy);
      },
      onPointerUp: _up,
      onPointerCancel: _up,
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _shown,
          builder: (context, _) => _paint(constraints),
        ),
      ),
    );
  }

  Widget _paint(BoxConstraints constraints) {
    final value = _shown.value.clamp(0.0, 1.0);
    final h = constraints.maxHeight;
    final thumbY =
        (1 - value) * (h - _VolumePainter.thumbHeight) +
        _VolumePainter.thumbHeight / 2;
    // TrackMeasurePolicy: the icon's 40 dp square goes at the top of
    // the empty part while that part has room for it, else just under
    // the thumb.
    final onInactive = thumbY - _VolumePainter.gap > _VolumePainter.trackWidth;
    final squareTop = onInactive ? 0.0 : thumbY + _VolumePainter.gap;
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: _VolumePainter(
            value: value,
            pressed: _pointer != null,
            scheme: widget.scheme,
          ),
        ),
        Positioned(
          left: (constraints.maxWidth - _VolumePainter.trackWidth) / 2,
          top: squareTop,
          width: _VolumePainter.trackWidth,
          height: _VolumePainter.trackWidth,
          child: ClipRect(
            child: Center(
              child: Icon(
                widget.icon,
                size: _VolumePainter.iconSize,
                color: onInactive
                    ? widget.scheme.onSurfaceVariant
                    : widget.scheme.surfaceContainerHighest,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _VolumePainter extends CustomPainter {
  _VolumePainter({
    required this.value,
    required this.pressed,
    required this.scheme,
  });

  static const double trackWidth = 40;
  static const double thumbWidth = 52;
  static const double thumbHeight = 4;
  static const double gap = 6;
  static const double outer = 12;
  static const double inner = 2;
  static const double iconSize = 20;

  final double value;
  final bool pressed;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final cx = size.width / 2;
    final left = cx - trackWidth / 2;
    final right = cx + trackWidth / 2;
    final thumbY = (1 - value) * (h - thumbHeight) + thumbHeight / 2;
    // Inactive part above the thumb, active part below it.
    final inactiveBottom = thumbY - thumbHeight / 2 - gap;
    final activeTop = thumbY + thumbHeight / 2 + gap;
    if (inactiveBottom > 0) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          left,
          0,
          right,
          inactiveBottom,
          topLeft: const Radius.circular(outer),
          topRight: const Radius.circular(outer),
          bottomLeft: const Radius.circular(inner),
          bottomRight: const Radius.circular(inner),
        ),
        Paint()..color = scheme.surfaceContainerHighest,
      );
    }
    if (activeTop < h) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          left,
          activeTop,
          right,
          h,
          topLeft: const Radius.circular(inner),
          topRight: const Radius.circular(inner),
          bottomLeft: const Radius.circular(outer),
          bottomRight: const Radius.circular(outer),
        ),
        Paint()..color = scheme.primary,
      );
    }
    // SliderDefaults.Thumb: half as wide while pressed.
    final width = pressed ? thumbWidth / 2 : thumbWidth;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, thumbY),
          width: width,
          height: thumbHeight,
        ),
        const Radius.circular(thumbHeight / 2),
      ),
      Paint()..color = scheme.primary,
    );
  }

  @override
  bool shouldRepaint(_VolumePainter old) =>
      old.value != value || old.pressed != pressed || old.scheme != scheme;
}

/// One ringer drawer button (volume_ringer_button). Open, each sits in its
/// own 48 dp slot; closed, all gather at the bottom slot where only the
/// selected one shows (the others shrink to a line and fade, as in
/// RingerDrawerConstraintsUtils). The selected one is a 40 dp primary
/// circle (measured on the emulator); the others are 40 dp squares with
/// 12 dp corners in surfaceContainerHighest.
class _RingerButton extends StatelessWidget {
  const _RingerButton({
    required this.mode,
    required this.selected,
    required this.openBottom,
    required this.closedBottom,
    required this.centerX,
    required this.drawer,
    required this.curve,
    required this.scheme,
    required this.onTap,
  });

  final PhoneRingerMode mode;
  final bool selected;
  final double openBottom;
  final double closedBottom;
  final double centerX;
  final AnimationController drawer;
  final Curve curve;
  final ColorScheme scheme;
  final VoidCallback onTap;

  static const double _size = 48;

  IconData get _icon => switch (mode) {
    PhoneRingerMode.normal => Icons.notifications_active_outlined,
    PhoneRingerMode.silent => Icons.notifications_off_outlined,
    PhoneRingerMode.vibrate => Icons.vibration_rounded,
  };

  String _label(BuildContext context) => switch (mode) {
    PhoneRingerMode.normal => context.l10n.volumeRingerNormal,
    PhoneRingerMode.silent => context.l10n.volumeRingerSilent,
    PhoneRingerMode.vibrate => context.l10n.volumeRingerVibrate,
  };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: drawer,
      builder: (context, child) {
        final t = curve.transform(drawer.value);
        final bottom = closedBottom + (openBottom - closedBottom) * t;
        // Closed, an unselected button is 1 dp tall and transparent.
        final height = selected ? _size : 1 + (_size - 1) * t;
        final opacity = selected ? 1.0 : t;
        final interactive = selected || drawer.value >= 1;
        return Positioned(
          left: centerX - _size / 2,
          top: bottom - height,
          width: _size,
          height: height,
          child: IgnorePointer(
            ignoring: !interactive,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: ClipRect(
                child: OverflowBox(
                  minHeight: _size,
                  maxHeight: _size,
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
      child: Semantics(
        button: true,
        selected: selected,
        label: _label(context),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              // Both 40 dp: the selected one a circle (radius 20).
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(selected ? 20 : 12),
              ),
              child: Icon(
                _icon,
                size: 24,
                color: selected ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
