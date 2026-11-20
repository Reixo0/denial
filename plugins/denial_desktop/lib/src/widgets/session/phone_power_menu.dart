import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/phone_desk.dart';

/// Material 3 roles from the shell accent (the wallpaper's colour when the
/// accent follows it), as Android's system UI derives its own.
ColorScheme phoneSchemeOf(BuildContext context) {
  final theme = ShellTheme.of(context);
  final brightness = context.shellColors.brightness;
  final key = (theme.accentSeed, brightness);
  final cached = _schemeCache;
  if (cached != null && cached.$1 == key) return cached.$2;
  final scheme = ColorScheme.fromSeed(
    seedColor: theme.accentSeed,
    brightness: brightness,
  );
  _schemeCache = (key, scheme);
  return scheme;
}

((Color, Brightness), ColorScheme)? _schemeCache;

enum _Page { menu, restart, confirm }

class _Pending {
  const _Pending({
    required this.title,
    required this.icon,
    required this.slideLabel,
    required this.run,
  });

  final String title;
  final IconData icon;
  final String slideLabel;
  final Future<void> Function() run;
}

IconData restartTargetIcon(String name) => switch (name) {
  'android' => Icons.android_rounded,
  'linux' => Icons.terminal_rounded,
  'bootloader' => Icons.memory_rounded,
  'recovery' => Icons.healing_rounded,
  'shell' => Icons.dashboard_rounded,
  _ => Icons.restart_alt_rounded,
};

/// The phone's power menu: a small card with Power off and Restart over the
/// blurred screen; Restart lists the system's restart targets; every action
/// is confirmed with a slide.
class PhonePowerMenu extends ConsumerStatefulWidget {
  const PhonePowerMenu({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  ConsumerState<PhonePowerMenu> createState() => _PhonePowerMenuState();
}

class _PhonePowerMenuState extends ConsumerState<PhonePowerMenu> {
  _Page _page = _Page.menu;
  _Pending? _pending;
  bool _running = false;

  void _confirm(_Pending pending) {
    setState(() {
      _pending = pending;
      _page = _Page.confirm;
    });
  }

  _Pending _powerOff() {
    final l10n = context.l10n;
    final controller = ref.read(sessionPowerProvider.notifier);
    return _Pending(
      title: l10n.powerActionPowerOff,
      icon: Icons.power_settings_new_rounded,
      slideLabel: l10n.powerMenuSlidePowerOff,
      run: () => controller.performConfirmed(SessionPowerAction.powerOff),
    );
  }

  _Pending _restart(RestartTarget target) {
    final controller = ref.read(sessionPowerProvider.notifier);
    return _Pending(
      title: target.label,
      icon: restartTargetIcon(target.icon),
      slideLabel: context.l10n.powerMenuSlideRestart,
      run: () => controller.restartTo(target),
    );
  }

  void _openRestart(List<RestartTarget> targets) {
    if (targets.length == 1) {
      _confirm(_restart(targets.single));
    } else {
      setState(() => _page = _Page.restart);
    }
  }

  Future<void> _run() async {
    final pending = _pending;
    if (pending == null || _running) return;
    setState(() => _running = true);
    unawaited(HapticFeedback.heavyImpact());
    await pending.run();
    if (!mounted) return;
    // Still here: the request failed (the error shows) or the system is
    // going down; let the user try again or leave.
    setState(() => _running = false);
  }

  void _back() {
    if (_running) return;
    switch (_page) {
      case _Page.menu:
        widget.onClose();
      case _Page.restart:
      case _Page.confirm:
        setState(() {
          _page = _Page.menu;
          _pending = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final targets =
        ref.watch(restartTargetsProvider).value ??
        const <RestartTarget>[RestartTarget.system];
    final error = ref.watch(sessionPowerProvider.select((s) => s.error));
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Widget page = switch (_page) {
      _Page.menu => _MenuCard(
        key: const ValueKey<String>('power-menu'),
        scheme: scheme,
        onPowerOff: () => _confirm(_powerOff()),
        onRestart: () => _openRestart(targets),
      ),
      _Page.restart => _RestartCard(
        key: const ValueKey<String>('power-restart'),
        scheme: scheme,
        targets: targets,
        onTarget: (target) => _confirm(_restart(target)),
        onCancel: _back,
      ),
      _Page.confirm => _ConfirmPane(
        key: ValueKey<String>('power-confirm-${_pending!.title}'),
        scheme: scheme,
        pending: _pending!,
        running: _running,
        error: error,
        onConfirmed: () => unawaited(_run()),
        onCancel: _back,
      ),
    };
    // The view spans every output: cover the main one only.
    final canvas = Offset.zero & MediaQuery.sizeOf(context);
    final output = ref
        .watch(sceneDisplayLayoutProvider(ShellPart.of(context)))
        ?.mainOutput
        ?.logicalRect
        .intersect(canvas);
    final outputRect = output == null || output.isEmpty ? canvas : output;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fromRect(
          rect: outputRect,
          child: _scene(page, reduceMotion, _androidScale(outputRect.size)),
        ),
      ],
    );
  }

  /// Sizes below are Android's (dp, a phone about 390 dp across). Denial
  /// lays the phone out wider, so the menu is scaled to take the same share
  /// of the screen as Android's.
  static double _androidScale(Size output) =>
      (output.shortestSide / 390).clamp(1.0, 1.8);

  Widget _scene(Widget page, bool reduceMotion, double scale) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _back,
      },
      child: Focus(
        autofocus: true,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Motion.md3EmphasizedDecelerate,
          builder: (context, t, child) => Stack(
            fit: StackFit.expand,
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _back,
                child: ShellBackdropBlur(
                  edgeless: true,
                  strength: t,
                  child: ColoredBox(
                    color: const Color(0xff000000).withValues(alpha: 0.4 * t),
                  ),
                ),
              ),
              Center(
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: scale * (0.92 + 0.08 * t),
                    child: MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(size: MediaQuery.sizeOf(context) / scale),
                      child: child!,
                    ),
                  ),
                ),
              ),
            ],
          ),
          child: AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
            switchInCurve: Motion.md3EmphasizedDecelerate,
            switchOutCurve: Motion.md3EmphasizedAccelerate,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.94, end: 1).animate(animation),
                child: child,
              ),
            ),
            child: page,
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.scheme, required this.child});

  final ColorScheme scheme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = math.min(300.0, MediaQuery.sizeOf(context).width - 32);
    return GestureDetector(
      // Taps on the card must not reach the scrim behind it.
      onTap: () {},
      child: Container(
        width: width,
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
        ),
        child: child,
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.scheme,
    required this.onPowerOff,
    required this.onRestart,
    super.key,
  });

  final ColorScheme scheme;
  final VoidCallback onPowerOff;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _Card(
      scheme: scheme,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              l10n.powerMenuTitle,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 20),
          _MenuRow(
            scheme: scheme,
            icon: Icons.power_settings_new_rounded,
            label: l10n.powerActionPowerOff,
            radius: const BorderRadius.vertical(
              top: Radius.circular(20),
              bottom: Radius.circular(6),
            ),
            onTap: onPowerOff,
          ),
          const SizedBox(height: 3),
          _MenuRow(
            scheme: scheme,
            icon: Icons.restart_alt_rounded,
            label: l10n.powerActionRestart,
            radius: const BorderRadius.vertical(
              top: Radius.circular(6),
              bottom: Radius.circular(20),
            ),
            onTap: onRestart,
          ),
        ],
      ),
    );
  }
}

class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.builder});

  final VoidCallback onTap;
  final Widget Function(BuildContext context, bool pressed) builder;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;

  void _set(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => _set(true),
    onTapUp: (_) => _set(false),
    onTapCancel: () => _set(false),
    onTap: widget.onTap,
    child: widget.builder(context, _pressed),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.scheme,
    required this.icon,
    required this.label,
    required this.radius,
    required this.onTap,
  });

  final ColorScheme scheme;
  final IconData icon;
  final String label;
  final BorderRadius radius;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: _Pressable(
      onTap: onTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 60,
        decoration: BoxDecoration(
          color: pressed
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerLow,
          borderRadius: radius,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 24, color: scheme.onSurfaceVariant),
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 24),
          ],
        ),
      ),
    ),
  );
}

class _RestartCard extends StatelessWidget {
  const _RestartCard({
    required this.scheme,
    required this.targets,
    required this.onTarget,
    required this.onCancel,
    super.key,
  });

  final ColorScheme scheme;
  final List<RestartTarget> targets;
  final ValueChanged<RestartTarget> onTarget;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _Card(
      scheme: scheme,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            l10n.powerActionRestart,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final width = (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  for (final target in targets)
                    SizedBox(
                      width: width,
                      child: _TargetTile(
                        scheme: scheme,
                        target: target,
                        onTap: () => onTarget(target),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          _Pressable(
            onTap: onCancel,
            builder: (context, pressed) => Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: pressed ? scheme.surfaceContainerHighest : null,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Text(
                l10n.actionCancel,
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.scheme,
    required this.target,
    required this.onTap,
  });

  final ColorScheme scheme;
  final RestartTarget target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: target.label,
    child: _Pressable(
      onTap: onTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 92,
        decoration: BoxDecoration(
          color: pressed
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              restartTargetIcon(target.icon),
              size: 28,
              color: scheme.primary,
            ),
            const SizedBox(height: 10),
            Text(
              target.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ConfirmPane extends StatelessWidget {
  const _ConfirmPane({
    required this.scheme,
    required this.pending,
    required this.running,
    required this.error,
    required this.onConfirmed,
    required this.onCancel,
    super.key,
  });

  final ColorScheme scheme;
  final _Pending pending;
  final bool running;
  final String? error;
  final VoidCallback onConfirmed;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final width = math.min(270.0, MediaQuery.sizeOf(context).width - 64);
    return GestureDetector(
      onTap: () {},
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            pending.title,
            style: const TextStyle(
              color: Color(0xffffffff),
              fontSize: 28,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: width,
            child: _SlideToConfirm(
              scheme: scheme,
              icon: pending.icon,
              label: running ? l10n.powerMenuWorking : pending.slideLabel,
              locked: running,
              onConfirmed: onConfirmed,
            ),
          ),
          if (error != null && !running) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: width,
              child: Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error, fontSize: 14),
              ),
            ),
          ],
          const SizedBox(height: 20),
          if (!running)
            _Pressable(
              onTap: onCancel,
              builder: (context, pressed) => Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: pressed
                      ? const Color(0x33ffffff)
                      : const Color(0x00ffffff),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  l10n.actionCancel,
                  style: const TextStyle(
                    color: Color(0xffffffff),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A pill track with a round thumb: dragging the thumb to the end confirms.
class _SlideToConfirm extends StatefulWidget {
  const _SlideToConfirm({
    required this.scheme,
    required this.icon,
    required this.label,
    required this.locked,
    required this.onConfirmed,
  });

  final ColorScheme scheme;
  final IconData icon;
  final String label;
  final bool locked;
  final VoidCallback onConfirmed;

  @override
  State<_SlideToConfirm> createState() => _SlideToConfirmState();
}

class _SlideToConfirmState extends State<_SlideToConfirm>
    with SingleTickerProviderStateMixin {
  static const double _height = 64;
  static const double _thumb = 52;
  static const double _inset = (_height - _thumb) / 2;
  static const Color _red = Color(0xffe0473e);

  late final AnimationController _position = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _travel = 1;
  bool _done = false;

  @override
  void didUpdateWidget(_SlideToConfirm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A failed request unlocks the slide again: bring the thumb back.
    if (oldWidget.locked && !widget.locked && _done) {
      _done = false;
      unawaited(_position.animateTo(0, curve: Motion.md3EmphasizedDecelerate));
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails details) {
    if (_done || widget.locked) return;
    _position.value += details.primaryDelta! / _travel;
  }

  void _release(DragEndDetails details) {
    if (_done || widget.locked) return;
    final flung = (details.primaryVelocity ?? 0) > 900;
    if (_position.value > 0.85 || (flung && _position.value > 0.5)) {
      _done = true;
      unawaited(
        _position
            .animateTo(1, curve: Motion.md3EmphasizedDecelerate)
            .whenComplete(() {
              if (mounted) widget.onConfirmed();
            }),
      );
    } else {
      unawaited(_position.animateTo(0, curve: Motion.md3EmphasizedDecelerate));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.locked ? null : widget.onConfirmed,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _travel = math.max(1, constraints.maxWidth - _thumb - _inset * 2);
          return GestureDetector(
            onHorizontalDragUpdate: _drag,
            onHorizontalDragEnd: _release,
            child: AnimatedBuilder(
              animation: _position,
              builder: (context, _) {
                final t = _position.value;
                return Container(
                  height: _height,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.92,
                    ),
                    borderRadius: BorderRadius.circular(_height / 2),
                  ),
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        left: _thumb + _inset * 2,
                        right: _inset * 2,
                        child: Center(
                          child: Opacity(
                            opacity: (1 - t * 1.6).clamp(0.0, 1.0),
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: _inset + t * _travel,
                        top: _inset,
                        child: Container(
                          width: _thumb,
                          height: _thumb,
                          decoration: const BoxDecoration(
                            color: _red,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.icon,
                            color: const Color(0xffffffff),
                            size: 26,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
