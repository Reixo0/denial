import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/settings.dart' show PhoneRingerMode;
import 'package:denial_flutter_sdk/system_services.dart';

import 'shade/shade_expansion_motion.dart' show androidAnimatorScale;

/// Android 16/17's volume panel (SystemUI `volume/panel`, VolumePanelRoot
/// in portrait), opened from the volume dialog's settings button: a bottom
/// sheet with where audio plays, one labelled slider per kind of sound and a
/// Settings / Done bar. Live Caption is left out (the owner's choice).
class PixelVolumePanel extends ConsumerStatefulWidget {
  const PixelVolumePanel({
    required this.open,
    required this.roles,
    required this.ringer,
    required this.scheme,
    required this.onClose,
    required this.onSettings,
    required this.onRinger,
    super.key,
  });

  final bool open;
  final List<AudioRoleLevel> roles;
  final PhoneRingerMode ringer;
  final ColorScheme scheme;
  final VoidCallback onClose;
  final VoidCallback onSettings;
  final ValueChanged<PhoneRingerMode> onRinger;

  @override
  ConsumerState<PixelVolumePanel> createState() => _PixelVolumePanelState();
}

/// The phone's order (AOSP VolumeSlidersComponent): media, call, ring,
/// notification, alarm.
const List<AudioRole> _order = <AudioRole>[
  AudioRole.media,
  AudioRole.call,
  AudioRole.ringtone,
  AudioRole.notification,
  AudioRole.alarm,
];

class _PixelVolumePanelState extends ConsumerState<PixelVolumePanel>
    with SingleTickerProviderStateMixin {
  // A sheet dialog's window animation: in with emphasized deceleration, out
  // with emphasized acceleration (M3 bottom sheet), at the phone's 0.75.
  late final AnimationController _sheet = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (400 * androidAnimatorScale).round()),
    reverseDuration: Duration(
      milliseconds: (200 * androidAnimatorScale).round(),
    ),
  );
  bool _mounted = false;

  /// Levels the fingers set, until the system reports them back.
  final Map<AudioRole, double> _held = <AudioRole, double>{};

  @override
  void initState() {
    super.initState();
    _sheet.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() => _mounted = false);
      }
    });
    if (widget.open) _show();
  }

  @override
  void didUpdateWidget(PixelVolumePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) _show();
    if (!widget.open && oldWidget.open) _sheet.reverse();
  }

  void _show() {
    setState(() => _mounted = true);
    ref.read(audioServiceProvider).requestOutputDevices();
    _sheet.forward();
  }

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mounted) return const SizedBox.shrink();
    final scheme = widget.scheme;
    final l10n = context.l10n;
    final padding = MediaQuery.viewPaddingOf(context);
    final devices =
        ref.watch(_outputDevicesProvider).value ?? const <AudioOutputDevice>[];
    final active = devices.where((device) => device.active).firstOrNull;
    final levels = {for (final role in widget.roles) role.role: role};
    final roles = [
      for (final role in _order)
        if (levels.containsKey(role)) levels[role]!,
    ];

    final sheet = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(24, 24, 24, 20 + padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // MediaOutputComponent: where audio plays.
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.volumePanelPlaysOn,
                      style: TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      active?.description ?? l10n.volumePanelThisPhone,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        height: 24 / 18,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 56,
                height: 56,
                child: Icon(
                  _deviceIcon(active),
                  size: 24,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          for (final (i, role) in roles.indexed) ...[
            if (i > 0) const SizedBox(height: 4),
            Text(
              _label(context, role.role),
              style: TextStyle(
                fontSize: 16,
                height: 24 / 16,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            SizedBox(height: 52, child: _slider(role)),
          ],
          const SizedBox(height: 24),
          // BottomBarComponent: outlined Settings, filled Done.
          SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _PillButton(
                  label: l10n.volumePanelSettings,
                  filled: false,
                  scheme: scheme,
                  onTap: widget.onSettings,
                ),
                _PillButton(
                  label: l10n.volumePanelDone,
                  filled: true,
                  scheme: scheme,
                  onTap: widget.onClose,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return AnimatedBuilder(
      animation: _sheet,
      builder: (context, child) {
        final forward = _sheet.status != AnimationStatus.reverse;
        final t = forward
            ? Curves.easeOutCubic.transform(_sheet.value)
            : Curves.easeInCubic.transform(_sheet.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            // The dialog's dim behind the sheet; a tap there closes it.
            Positioned.fill(
              child: ShellInputRegion(
                debugLabel: 'Volume panel scrim',
                active: widget.open,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: ColoredBox(
                    color: const Color(0xFF000000).withValues(alpha: 0.32 * t),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FractionalTranslation(
                translation: Offset(0, 1 - t),
                child: ShellInputRegion(
                  debugLabel: 'Volume panel',
                  active: widget.open,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: sheet,
    );
  }

  /// Android's ringer mode on the sliders: in vibrate or mute the ring
  /// slider sits at zero with the mode's icon and the notification slider
  /// at zero, disabled. Raising the ring slider rings again; taking it to
  /// zero vibrates.
  Widget _slider(AudioRoleLevel role) {
    final ringer = widget.ringer;
    final quiet = ringer != PhoneRingerMode.normal;
    final ring = role.role == AudioRole.ringtone;
    final notification = role.role == AudioRole.notification;
    final held = _held[role.role];
    final level = role.muted ? 0.0 : role.level;
    final value = held ?? ((ring || notification) && quiet ? 0.0 : level);
    final icon = ring && ringer == PhoneRingerMode.vibrate
        ? Icons.vibration_rounded
        : (ring || notification) && (quiet || value <= 0)
        ? Icons.notifications_off_outlined
        : _icon(role.role);
    return _PanelSlider(
      value: value,
      icon: icon,
      scheme: widget.scheme,
      enabled: !(notification && quiet),
      onChanged: (level) {
        setState(() => _held[role.role] = level);
        if (ring && quiet && level > 0) widget.onRinger(PhoneRingerMode.normal);
        if (level > 0 || !ring) {
          ref
              .read(audioServiceProvider)
              .applyRole(role.role, (level * 100).round());
        }
      },
      onEnd: () {
        final last = _held[role.role];
        if (ring && last != null && last <= 0) {
          widget.onRinger(PhoneRingerMode.vibrate);
        }
        Timer(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _held.remove(role.role));
        });
      },
    );
  }

  static IconData _deviceIcon(AudioOutputDevice? device) {
    final name = '${device?.name} ${device?.description}'.toLowerCase();
    if (name.contains('headphone') || name.contains('headset')) {
      return Icons.headphones_outlined;
    }
    if (name.contains('bluez') || name.contains('bluetooth')) {
      return Icons.bluetooth_audio_outlined;
    }
    if (name.contains('hdmi') || name.contains('display')) {
      return Icons.tv_outlined;
    }
    return Icons.smartphone_outlined;
  }

  static IconData _icon(AudioRole role) => switch (role) {
    AudioRole.media => Icons.music_note_outlined,
    AudioRole.call => Icons.call_outlined,
    AudioRole.ringtone => Icons.ring_volume_outlined,
    AudioRole.notification => Icons.notifications_none_outlined,
    AudioRole.alarm => Icons.alarm_outlined,
  };

  static String _label(BuildContext context, AudioRole role) {
    final l10n = context.l10n;
    return switch (role) {
      AudioRole.media => l10n.volumePanelMedia,
      AudioRole.call => l10n.volumePanelCall,
      AudioRole.ringtone => l10n.volumePanelRing,
      AudioRole.notification => l10n.volumePanelNotification,
      AudioRole.alarm => l10n.volumePanelAlarm,
    };
  }
}

final _outputDevicesProvider =
    StreamProvider.autoDispose<List<AudioOutputDevice>>(
      (ref) => ref.watch(audioServiceProvider).outputDeviceStates,
    );

/// M3 button, 40 dp tall: outlined (Settings) or filled primary (Done).
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.filled,
    required this.scheme,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? scheme.primary : null,
          borderRadius: BorderRadius.circular(20),
          border: filled ? null : Border.all(color: scheme.outline),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            height: 20 / 14,
            fontWeight: FontWeight.w500,
            color: filled ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// The panel's horizontal slider (VolumeSlider in volume/panel): track
/// 40 dp, 12 dp outer and 2 dp inner corners, 6 dp gaps around a 4 x 52 dp
/// thumb, the role's 24 dp icon at the end of the empty part or, when that
/// is too short, just left of the thumb. Inactive parts surfaceContainerHigh.
class _PanelSlider extends StatefulWidget {
  const _PanelSlider({
    required this.value,
    required this.icon,
    required this.scheme,
    required this.onChanged,
    required this.onEnd,
    this.enabled = true,
  });

  final double value;
  final IconData icon;
  final ColorScheme scheme;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  @override
  State<_PanelSlider> createState() => _PanelSliderState();
}

class _PanelSliderState extends State<_PanelSlider>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 1500 / (androidAnimatorScale * androidAnimatorScale),
    ratio: 1,
  );

  static const double _thumbWidth = 4;
  static const double _gap = 6;
  static const double _track = 40;

  late final AnimationController _shown = AnimationController.unbounded(
    vsync: this,
    value: widget.value,
  );
  int? _pointer;

  @override
  void didUpdateWidget(_PanelSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pointer == null && oldWidget.value != widget.value) {
      _shown.animateWith(
        SpringSimulation(_spring, _shown.value, widget.value, _shown.velocity),
      );
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  void _set(double x) {
    final width = context.size?.width ?? 1;
    final value = ((x - _thumbWidth / 2) / (width - _thumbWidth)).clamp(
      0.0,
      1.0,
    );
    _shown.value = value;
    widget.onChanged(value);
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    setState(() => _pointer = null);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (_pointer != null || !widget.enabled) return;
        setState(() => _pointer = event.pointer);
        _shown.stop();
        _set(event.localPosition.dx);
      },
      onPointerMove: (event) {
        if (event.pointer == _pointer) _set(event.localPosition.dx);
      },
      onPointerUp: _up,
      onPointerCancel: _up,
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _shown,
          builder: (context, _) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final value = _shown.value.clamp(0.0, 1.0);
            final thumbX = value * (w - _thumbWidth) + _thumbWidth / 2;
            // TrackMeasurePolicy: at the end of the empty part while it has
            // room for the icon's square, else just left of the thumb.
            final onInactive = w - (thumbX + _gap) > _track;
            final iconLeft = onInactive ? w - _track : thumbX - _gap - _track;
            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _PanelSliderPainter(
                      thumbX: thumbX,
                      scheme: scheme,
                      track: _track,
                      height: h,
                    ),
                  ),
                ),
                Positioned(
                  left: math.max(0, iconLeft),
                  top: (h - _track) / 2,
                  width: _track,
                  height: _track,
                  child: Icon(
                    widget.icon,
                    size: 24,
                    color:
                        (onInactive
                                ? scheme.onSurfaceVariant
                                : scheme.surfaceContainerHigh)
                            .withValues(alpha: widget.enabled ? 1 : 0.38),
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

class _PanelSliderPainter extends CustomPainter {
  _PanelSliderPainter({
    required this.thumbX,
    required this.scheme,
    required this.track,
    required this.height,
  });

  final double thumbX;
  final ColorScheme scheme;
  final double track;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 6.0;
    const outer = Radius.circular(12);
    const inner = Radius.circular(2);
    final top = (size.height - track) / 2;
    final bottom = top + track;
    final activeRight = thumbX - 2 - gap;
    final inactiveLeft = thumbX + 2 + gap;
    if (activeRight > 0) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          0,
          top,
          activeRight,
          bottom,
          topLeft: outer,
          bottomLeft: outer,
          topRight: inner,
          bottomRight: inner,
        ),
        Paint()..color = scheme.primary,
      );
    }
    if (inactiveLeft < size.width) {
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          inactiveLeft,
          top,
          size.width,
          bottom,
          topLeft: inner,
          bottomLeft: inner,
          topRight: outer,
          bottomRight: outer,
        ),
        Paint()..color = scheme.surfaceContainerHigh,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(thumbX, size.height / 2),
          width: 4,
          height: 52,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = scheme.primary,
    );
  }

  @override
  bool shouldRepaint(_PanelSliderPainter old) =>
      old.thumbX != thumbX || old.scheme != scheme;
}
