part of 'lock_screen_layer.dart';

/// Mobile PIN entry: Android's PIN bouncer ([KeyguardPinView]) over the
/// blurred lock screen.
///
/// Digits stay in this widget until the enter key, then reach deniald as one
/// response (KeyguardPINView has no auto-confirm by default). A wrong PIN
/// shows "Wrong PIN. Try again." and the shapes go, the last first. Back (the
/// edge swipe or Escape) closes it.
/// While it leaves, touches go through to the face behind it.
class _MobileLockPinStage extends ConsumerStatefulWidget {
  const _MobileLockPinStage({
    super.key,
    required this.reveal,
    required this.interactive,
    required this.onBegin,
    required this.onCancel,
  });

  /// 0 hidden, 1 fully shown; already curved.
  final Animation<double> reveal;

  /// False once the stage is dismissed, while it still fades out.
  final bool interactive;
  final VoidCallback onBegin;
  final VoidCallback onCancel;

  @override
  ConsumerState<_MobileLockPinStage> createState() =>
      _MobileLockPinStageState();
}

class _MobileLockPinStageState extends ConsumerState<_MobileLockPinStage> {
  /// Character codes, scrubbed as soon as they are sent or dropped.
  final List<int> _digits = <int>[];
  final FocusNode _keys = FocusNode(debugLabel: 'lock-pin-keys');
  final KeyguardPinEntryController _entry = KeyguardPinEntryController();

  /// The app a tapped notification opens after unlocking; kept while the
  /// stage fades out.
  String? _opens;

  bool _submitted = false;
  bool _pendingSubmit = false;
  bool _wrong = false;

  @override
  void dispose() {
    _scrub();
    _keys.dispose();
    _entry.dispose();
    super.dispose();
  }

  void _scrub() {
    _digits.fillRange(0, _digits.length, 0);
    _digits.clear();
  }

  bool _acceptsInput(AuthenticationState state) =>
      state.locked && state.available && !state.rateLimited && !_submitted;

  void _press(int digit) {
    final state = ref.read(authenticationProvider);
    if (!_acceptsInput(state) || _digits.length >= _pinMaxLength) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.add(0x30 + digit);
      _wrong = false;
    });
    _entry.append();
    // A failed attempt ends deniald's prompt; the next digit opens another.
    if (!state.busy) {
      widget.onBegin();
    }
  }

  void _delete() {
    if (_submitted || _digits.isEmpty) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.last = 0;
      _digits.removeLast();
    });
    _entry.delete();
  }

  void _clear() {
    if (_submitted || _digits.isEmpty) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(_scrub);
    _entry.reset();
  }

  void _enter() {
    final state = ref.read(authenticationProvider);
    if (!_acceptsInput(state) || _digits.isEmpty) {
      return;
    }
    if (_digits.length < _pinMinLength) {
      // Too short to be a PIN: wrong, but not an attempt
      // (MINIMUM_PASSWORD_LENGTH_BEFORE_REPORT).
      _reject();
      return;
    }
    _submit();
  }

  void _submit() {
    final state = ref.read(authenticationProvider);
    final prompt = state.prompt;
    if (!state.busy || prompt == null || !prompt.isPin) {
      // The prompt is still on its way; submit as soon as it lands.
      setState(() => _submitted = true);
      _pendingSubmit = true;
      return;
    }
    _pendingSubmit = false;
    final pin = String.fromCharCodes(_digits);
    _scrub();
    setState(() => _submitted = true);
    ref.read(authenticationProvider.notifier).respond(pin);
  }

  void _reject() {
    _pinRejectHaptics(ref.read(hapticsServiceProvider));
    setState(() {
      _scrub();
      _wrong = true;
    });
    _entry.reset();
  }

  void _attemptFinished(AuthenticationState state) {
    _submitted = false;
    if (!state.locked) {
      return;
    }
    if (!state.resultIsError || state.resultMessage == null) {
      // Cancelled or timed out: start over quietly.
      setState(_scrub);
      _entry.reset();
      return;
    }
    _reject();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) => _handlePinKey(
    event,
    onDigit: _press,
    onDelete: _delete,
    onCancel: widget.onCancel,
    onSubmit: _enter,
  );

  @override
  Widget build(BuildContext context) {
    final authentication = ref.watch(authenticationProvider);
    ref.listen<AuthenticationState>(authenticationProvider, (previous, next) {
      if (_pendingSubmit && next.busy && (next.prompt?.isPin ?? false)) {
        _submitted = false;
        _submit();
      } else if (_pendingSubmit &&
          (!next.locked || !next.available || next.rateLimited)) {
        // No prompt is coming: drop the waiting PIN.
        _pendingSubmit = false;
        _submitted = false;
        setState(_scrub);
        _entry.reset();
      }
      if (_submitted &&
          !_pendingSubmit &&
          (previous?.busy ?? false) &&
          !next.busy) {
        _attemptFinished(next);
      }
    });
    final l10n = context.l10n;
    if (widget.interactive) {
      final groupKey = ref.watch(lockNotificationOpenProvider);
      final opening = groupKey == null
          ? null
          : ref.watch(
              desktopNotificationsProvider.select(
                (state) => state.groups
                    .where((group) => group.key == groupKey)
                    .firstOrNull
                    ?.newest
                    .notification,
              ),
            );
      _opens = opening == null ? null : notificationAppName(opening, l10n);
    }
    final opens = _opens;
    final cooldownSeconds = (authentication.cooldown.inMilliseconds / 1000)
        .ceil()
        .clamp(1, 30);
    final message = authentication.rateLimited
        ? l10n.lockRetryInSeconds(cooldownSeconds)
        : _wrong
        ? l10n.lockWrongPinTryAgain
        : !authentication.available
        ? authentication.statusMessage ?? l10n.lockAuthenticationUnavailable
        : opens != null
        ? l10n.lockEnterPinToOpen(opens)
        : l10n.lockEnterPin;

    return _KeyguardBouncer(
      reveal: widget.reveal,
      interactive: widget.interactive,
      focusNode: _keys,
      onKeyEvent: _handleKey,
      message: message,
      entry: _entry,
      enabled: _acceptsInput(authentication),
      onDigit: _press,
      onDelete: _delete,
      onClear: _clear,
      onEnter: _enter,
      onBack: widget.onCancel,
    );
  }
}

/// The same bouncer for the modem's SIM PIN (KeyguardSimPinView): 4 to 8
/// digits, confirmed with the enter key. Back puts it off until later.
///
/// The SIM PIN goes to the modem only; it never authenticates the session.
class _MobileSimPinStage extends ConsumerStatefulWidget {
  const _MobileSimPinStage({
    super.key,
    required this.reveal,
    required this.interactive,
    required this.onLater,
  });

  /// 0 hidden, 1 fully shown; already curved.
  final Animation<double> reveal;

  /// False once the stage is dismissed, while it still fades out.
  final bool interactive;
  final VoidCallback onLater;

  @override
  ConsumerState<_MobileSimPinStage> createState() => _MobileSimPinStageState();
}

class _MobileSimPinStageState extends ConsumerState<_MobileSimPinStage> {
  static const int _minLength = 4;
  static const int _maxLength = 8;

  /// Character codes, scrubbed as soon as they are sent or dropped.
  final List<int> _digits = <int>[];
  final FocusNode _keys = FocusNode(debugLabel: 'sim-pin-keys');
  final KeyguardPinEntryController _entry = KeyguardPinEntryController();

  bool _busy = false;
  bool _wrong = false;

  /// The last PIN was not 4 to 8 digits (kg_invalid_sim_pin_hint).
  bool _badLength = false;

  @override
  void dispose() {
    _scrub();
    _keys.dispose();
    _entry.dispose();
    super.dispose();
  }

  void _scrub() {
    _digits.fillRange(0, _digits.length, 0);
    _digits.clear();
  }

  MobileNetworkSnapshot get _sim =>
      ref.read(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();

  bool _acceptsInput(MobileNetworkSnapshot sim) =>
      sim.pinRequired && sim.pinRetries != 0 && !_busy;

  void _press(int digit) {
    if (!_acceptsInput(_sim) || _digits.length >= _maxLength) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.add(0x30 + digit);
      _wrong = false;
      _badLength = false;
    });
    _entry.append();
  }

  void _delete() {
    if (_busy || _digits.isEmpty) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(() {
      _digits.last = 0;
      _digits.removeLast();
    });
    _entry.delete();
  }

  void _clear() {
    if (_busy || _digits.isEmpty) {
      return;
    }
    ref.read(hapticsServiceProvider).pulse();
    setState(_scrub);
    _entry.reset();
  }

  void _later() {
    if (_busy) {
      return;
    }
    _scrub();
    widget.onLater();
  }

  void _reject({bool badLength = false}) {
    _pinRejectHaptics(ref.read(hapticsServiceProvider));
    setState(() {
      _scrub();
      _wrong = !badLength;
      _badLength = badLength;
    });
    _entry.reset();
  }

  Future<void> _submit() async {
    final sim = _sim;
    if (!_acceptsInput(sim) || _digits.isEmpty) {
      return;
    }
    if (_digits.length < _minLength) {
      _reject(badLength: true);
      return;
    }
    final pin = String.fromCharCodes(_digits);
    _scrub();
    setState(() => _busy = true);
    try {
      await ref.read(mobileNetworkServiceProvider).sendPin(sim.simPath!, pin);
    } on Object {
      if (mounted) {
        _reject();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) => _handlePinKey(
    event,
    onDigit: _press,
    onDelete: _delete,
    onCancel: _later,
    onSubmit: _submit,
  );

  @override
  Widget build(BuildContext context) {
    final sim =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    final l10n = context.l10n;
    final retries = sim.pinRetries;
    final message = sim.unlockRequired == 4
        ? l10n.simPukRequired
        : !sim.pinRequired
        ? l10n.simLocked
        : _badLength
        ? l10n.simPinLengthHint
        : _wrong
        ? (retries != null
              ? l10n.simPinRetries(retries)
              : l10n.lockWrongPinTryAgain)
        : l10n.simPinEnter;

    return _KeyguardBouncer(
      reveal: widget.reveal,
      interactive: widget.interactive,
      focusNode: _keys,
      onKeyEvent: _handleKey,
      message: message,
      entry: _entry,
      enabled: _acceptsInput(sim),
      onDigit: _press,
      onDelete: _delete,
      onClear: _clear,
      onEnter: _submit,
      onBack: _later,
    );
  }
}

/// PasswordTextView takes at most 16 digits here; the enter key needs 4.
const int _pinMaxLength = 16;
const int _pinMinLength = 4;

/// A double buzz for a wrong PIN.
void _pinRejectHaptics(HapticsService haptics) {
  haptics.pulse();
  Future<void>.delayed(const Duration(milliseconds: 110), haptics.pulse);
}

KeyEventResult _handlePinKey(
  KeyEvent event, {
  required ValueChanged<int> onDigit,
  required VoidCallback onDelete,
  required VoidCallback onCancel,
  required VoidCallback onSubmit,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;
  final digit = _digitKeys.indexOf(key);
  final numpad = _numpadKeys.indexOf(key);
  if (digit >= 0 || numpad >= 0) {
    onDigit(digit >= 0 ? digit : numpad);
  } else if (key == LogicalKeyboardKey.backspace) {
    onDelete();
  } else if (key == LogicalKeyboardKey.escape) {
    onCancel();
  } else if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    onSubmit();
  } else {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}

/// The bouncer stage shared by the device PIN and the SIM PIN: the blurred,
/// tinted lock screen behind, the PIN view with its 650 ms appear each time
/// it comes up, and Back.
class _KeyguardBouncer extends StatefulWidget {
  const _KeyguardBouncer({
    required this.reveal,
    required this.interactive,
    required this.focusNode,
    required this.onKeyEvent,
    required this.message,
    required this.entry,
    required this.enabled,
    required this.onDigit,
    required this.onDelete,
    required this.onClear,
    required this.onEnter,
    required this.onBack,
  });

  final Animation<double> reveal;
  final bool interactive;
  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKeyEvent;
  final String message;
  final KeyguardPinEntryController entry;
  final bool enabled;
  final ValueChanged<int> onDigit;
  final VoidCallback onDelete;
  final VoidCallback onClear;
  final VoidCallback onEnter;
  final VoidCallback onBack;

  @override
  State<_KeyguardBouncer> createState() => _KeyguardBouncerState();
}

class _KeyguardBouncerState extends State<_KeyguardBouncer>
    with SingleTickerProviderStateMixin {
  /// KeyguardPINView.startAppearAnimation, linear: the view curves each row.
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: androidDuration(KeyguardPinMetrics.appearMs),
  );

  @override
  void initState() {
    super.initState();
    if (widget.interactive) _startAppear();
  }

  @override
  void didUpdateWidget(covariant _KeyguardBouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.interactive && !oldWidget.interactive) _startAppear();
  }

  void _startAppear() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _appear.value = 1;
      } else {
        _appear.forward(from: 0);
      }
    });
  }

  @override
  void dispose() {
    _appear.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final size = MediaQuery.sizeOf(context);
    final dp = size.width / (1216 / 2.925);
    // Any material but none blurs the lock screen: glass has no edge here.
    final blur = ShellTheme.of(context).backdropBlurEnabled;
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: _BouncerBackdrop(
              reveal: widget.reveal,
              scheme: scheme,
              // The shade's blur radius, 34 dp (max_window_blur_radius), as
              // a Gaussian sigma.
              sigma: blur ? 34 * dp * 0.57735 + 0.5 : 0,
            ),
          ),
          IgnorePointer(
            ignoring: !widget.interactive,
            child: Focus(
              focusNode: widget.focusNode,
              autofocus: true,
              onKeyEvent: widget.onKeyEvent,
              child: AnimatedBuilder(
                animation: widget.reveal,
                // Leaving (startDisappearAnimation): it fades and rises
                // 50 dp with the stage.
                builder: (context, child) {
                  if (widget.interactive) return child!;
                  final t = widget.reveal.value.clamp(0.0, 1.0);
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, -50 * dp * (1 - t)),
                      child: child,
                    ),
                  );
                },
                child: KeyguardPinView(
                  scheme: scheme,
                  message: widget.message,
                  entry: widget.entry,
                  appear: _appear,
                  enabled: widget.enabled && widget.interactive,
                  onDigit: widget.onDigit,
                  onDelete: widget.onDelete,
                  onClear: widget.onClear,
                  onEnter: widget.onEnter,
                ),
              ),
            ),
          ),
          // The shell's own Back strips stand down under the lock screen.
          if (widget.interactive) MobileBackGestureLayer(onBack: widget.onBack),
        ],
      ),
    );
  }
}

/// The lock screen behind the bouncer: blurred like under the shade, then
/// the shade's scrim and panel tint, all with the reveal.
class _BouncerBackdrop extends StatelessWidget {
  const _BouncerBackdrop({
    required this.reveal,
    required this.scheme,
    required this.sigma,
  });

  final Animation<double> reveal;
  final ColorScheme scheme;
  final double sigma;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: reveal,
    builder: (context, _) {
      final t = reveal.value.clamp(0.0, 1.0);
      if (t <= 0) return const SizedBox.shrink();
      final tint = Color.alphaBlend(phoneShadePanel(scheme), phoneShadeScrim);
      final fill = ColoredBox(color: tint.withValues(alpha: tint.a * t));
      if (sigma <= 0) return fill;
      return BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: sigma * t,
          sigmaY: sigma * t,
          tileMode: TileMode.clamp,
        ),
        child: fill,
      );
    },
  );
}

const List<LogicalKeyboardKey> _digitKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

const List<LogicalKeyboardKey> _numpadKeys = <LogicalKeyboardKey>[
  LogicalKeyboardKey.numpad0,
  LogicalKeyboardKey.numpad1,
  LogicalKeyboardKey.numpad2,
  LogicalKeyboardKey.numpad3,
  LogicalKeyboardKey.numpad4,
  LogicalKeyboardKey.numpad5,
  LogicalKeyboardKey.numpad6,
  LogicalKeyboardKey.numpad7,
  LogicalKeyboardKey.numpad8,
  LogicalKeyboardKey.numpad9,
];

class _PinLink extends StatelessWidget {
  const _PinLink({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                label,
                style: ShellText.base.copyWith(
                  color: context.shellColors.textSecondary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
