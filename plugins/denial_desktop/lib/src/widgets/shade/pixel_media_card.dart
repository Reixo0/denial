import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart'
    show AnimatedIcon, AnimatedIcons, ColorScheme, DynamicSchemeVariant, Icons;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/rendering.dart' show AppIconImage;
import 'package:denial_flutter_sdk/system_services.dart';

import '../../state/reference_shell_controller.dart';
import '../notification_media.dart';
import '../notification_open.dart';

/// What the shade's media player shows: the current player, or the last
/// one after it went away (AOSP keeps it as a resumable player in the full
/// quick settings), and whether the quick tiles show it (AOSP
/// `showsOnlyActiveMedia`: while it plays and for ten minutes after a
/// pause).
@immutable
class MediaCardState {
  const MediaCardState({
    required this.playback,
    required this.live,
    required this.active,
  });

  final MprisPlaybackState playback;

  /// The player still exists; false for the kept last player.
  final bool live;
  final bool active;
}

final mediaCardProvider = NotifierProvider<MediaCardNotifier, MediaCardState?>(
  MediaCardNotifier.new,
);

class MediaCardNotifier extends Notifier<MediaCardState?> {
  static const Duration inactiveAfter = Duration(minutes: 10);

  Timer? _timer;

  @override
  MediaCardState? build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen<AsyncValue<MprisPlaybackState>>(
      mediaPlaybackProvider,
      (_, next) => _update(next.value),
    );
    final playback = ref.read(mediaPlaybackProvider).value;
    if (playback == null || !playback.available) return null;
    return MediaCardState(
      playback: playback,
      live: true,
      active: playback.playing,
    );
  }

  void _update(MprisPlaybackState? playback) {
    final previous = state;
    if (playback == null || !playback.available) {
      _timer?.cancel();
      _timer = null;
      if (previous != null) {
        state = MediaCardState(
          playback: previous.playback.copyWith(
            status: MprisPlaybackStatus.paused,
          ),
          live: false,
          active: false,
        );
      }
      return;
    }
    var active = previous?.live == true && previous!.active;
    if (playback.playing) {
      _timer?.cancel();
      _timer = null;
      active = true;
    } else if (active && _timer == null) {
      _timer = Timer(inactiveAfter, () {
        _timer = null;
        final current = state;
        if (current == null) return;
        state = MediaCardState(
          playback: current.playback,
          live: current.live,
          active: false,
        );
      });
    }
    state = MediaCardState(playback: playback, live: true, active: active);
  }

  /// AOSP's long press → Hide on a player that is gone.
  void dismiss() {
    if (state?.live == false) state = null;
  }
}

/// The media player of Android's quick settings (SystemUI MediaControlPanel /
/// `media_session_view`), measured from EvolutionX at 2.925 px/dp: 184 dp
/// tall, the album art under a scrim, colours from the art.
class PixelMediaCard extends ConsumerStatefulWidget {
  const PixelMediaCard({super.key});

  static const double height = 184;

  /// The gap above the card, under the tiles.
  static const double gap = 8;

  @override
  ConsumerState<PixelMediaCard> createState() => _PixelMediaCardState();
}

/// The card's colours: AOSP `ColorScheme(art, light, CONTENT)`; the buttons
/// use its fixed primary.
class _MediaColors {
  const _MediaColors({
    required this.scrim,
    required this.button,
    required this.onButton,
  });

  static const _MediaColors fallback = _MediaColors(
    scrim: Color(0xFF41484D),
    button: Color(0xFFE0E3E5),
    onButton: Color(0xFF191C1E),
  );

  final Color scrim;
  final Color button;
  final Color onButton;
}

class _PixelMediaCardState extends ConsumerState<PixelMediaCard>
    with SingleTickerProviderStateMixin {
  // A ticker, not a timer: it stops while the shade is closed (TickerMode).
  late final Ticker _tick = createTicker(_onTick);
  Duration _shown = Duration.zero;
  String _artUrl = '';
  ImageProvider? _art;
  _MediaColors _colors = _MediaColors.fallback;

  /// A seek drag in progress, as a fraction of the track.
  double? _seeking;

  final _cardKey = GlobalKey();
  final _ripples = GlobalKey<_CardRipplesState>();

  /// AOSP plays a touch ripple from every button the user taps.
  void _rippleFrom(BuildContext button) {
    final box = button.findRenderObject();
    final card = _cardKey.currentContext?.findRenderObject();
    if (box is! RenderBox || card is! RenderBox) return;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    _ripples.currentState?.play(card.globalToLocal(centre));
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  void _follow(MprisPlaybackState playback) {
    if (playback.artUrl != _artUrl) {
      _artUrl = playback.artUrl;
      _art = _imageFor(_artUrl);
      _colors = _MediaColors.fallback;
      if (_art case final art?) unawaited(_loadColors(_artUrl, art));
    }
    // The position moves while it plays.
    final ticking = playback.playing && playback.length > Duration.zero;
    if (ticking && !_tick.isActive) {
      _shown = Duration.zero;
      _tick.start();
    } else if (!ticking && _tick.isActive) {
      _tick.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _shown < const Duration(milliseconds: 250)) return;
    _shown = elapsed;
    if (_seeking == null) setState(() {});
  }

  static ImageProvider? _imageFor(String url) {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.scheme == 'file') return FileImage(File(uri.toFilePath()));
    if (uri.scheme.isEmpty && url.startsWith('/')) return FileImage(File(url));
    // Remote art is not fetched from the shell.
    return null;
  }

  Future<void> _loadColors(String url, ImageProvider art) async {
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: art,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.content,
      );
      if (!mounted || url != _artUrl) return;
      setState(() {
        _colors = _MediaColors(
          scrim: scheme.onSurface,
          button: scheme.primaryFixed,
          onButton: scheme.onPrimaryFixed,
        );
      });
    } on Object {
      // A broken file keeps the plain colours.
    }
  }

  void _open() {
    final entry = ref.read(mediaCardProvider)?.playback.desktopEntry ?? '';
    if (entry.isEmpty) return;
    ref.read(referenceShellProvider.notifier).closeQuickSettings();
    openDesktopEntry(ref, entry);
  }

  @override
  Widget build(BuildContext context) {
    final card = ref.watch(mediaCardProvider);
    final live = card?.live ?? false;
    final playback = card?.playback ?? MprisPlaybackState.unavailable();
    _follow(playback);
    final service = ref.read(mediaPlayerServiceProvider);
    final colors = _colors;
    final length = playback.length;
    final position = playback.positionAt(DateTime.now());
    final fraction =
        _seeking ??
        (length > Duration.zero
            ? (position.inMicroseconds / length.inMicroseconds).clamp(0.0, 1.0)
            : 0.0);

    // AOSP fills a missing previous or next with the app's own buttons,
    // then the two custom slots.
    final customs = live
        ? List<MprisCustomAction>.of(playback.actions)
        : <MprisCustomAction>[];
    Widget custom() {
      if (customs.isEmpty) return const SizedBox(width: 48, height: 48);
      final action = customs.removeAt(0);
      return _MediaButton(
        tooltip: action.label,
        ripple: _rippleFrom,
        onTap: () => unawaited(service.invokeAction(action.id)),
        child: _ActionIcon(pixels: action.icon),
      );
    }

    final previous = live && playback.canGoPrevious
        ? _MediaButton(
            tooltip: 'Previous',
            ripple: _rippleFrom,
            onTap: () => unawaited(service.previous()),
            child: const Icon(
              Icons.skip_previous_rounded,
              size: 24,
              color: Color(0xFFFFFFFF),
            ),
          )
        : custom();
    final next = live && playback.canGoNext
        ? _MediaButton(
            tooltip: 'Next',
            ripple: _rippleFrom,
            onTap: () => unawaited(service.next()),
            child: const Icon(
              Icons.skip_next_rounded,
              size: 24,
              color: Color(0xFFFFFFFF),
            ),
          )
        : custom();
    final slot3 = custom();
    final slot4 = custom();

    final art = _art;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: playback.desktopEntry.isEmpty ? null : _open,
      onLongPress: live ? null : ref.read(mediaCardProvider.notifier).dismiss,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SizedBox(
          key: _cardKey,
          height: PixelMediaCard.height,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // AOSP cross-fades a new artwork (TransitionDrawable, 333 ms).
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 333),
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: <Widget>[...previous, ?current],
                ),
                child: art == null
                    ? const SizedBox.expand(key: ValueKey<String>(''))
                    : Image(
                        key: ValueKey<String>(_artUrl),
                        image: art,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
              ),
              // AOSP: a radial scrim of the scheme's onSurface over the art.
              AnimatedContainer(
                duration: const Duration(milliseconds: 333),
                decoration: BoxDecoration(
                  color: art == null ? colors.scrim : null,
                  gradient: art == null
                      ? null
                      : RadialGradient(
                          radius: 1.1,
                          colors: <Color>[
                            colors.scrim.withValues(alpha: 0.65),
                            colors.scrim.withValues(alpha: 0.75),
                          ],
                        ),
                ),
              ),
              _CardRipples(key: _ripples, color: colors.button),
              Positioned(
                left: 16,
                top: 16,
                width: 24,
                height: 24,
                child: _PlayerIcon(playback: playback, colors: colors),
              ),
              Positioned(
                right: 16,
                top: 15,
                height: 23,
                child: _OutputChip(colors: colors),
              ),
              Positioned(
                left: 16,
                right: 16 + 23 + 58,
                top: 78,
                child: _SongText(
                  title: playback.title,
                  artist: playback.artistLabel,
                ),
              ),
              Positioned(
                right: 23,
                top: 75,
                width: 58,
                height: 40,
                child: Builder(
                  builder: (pill) => _PlayPill(
                    playing: playback.playing,
                    colors: colors,
                    // A player that is gone resumes in its app.
                    onTap: live
                        ? () {
                            _rippleFrom(pill);
                            unawaited(service.playPause());
                          }
                        : playback.desktopEntry.isEmpty
                        ? () {}
                        : _open,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 48,
                child: Row(
                  children: <Widget>[
                    previous,
                    const SizedBox(width: 15),
                    Expanded(
                      child: _SeekBar(
                        fraction: fraction,
                        enabled:
                            live && playback.canSeek && length > Duration.zero,
                        playing: live && playback.playing,
                        colors: colors,
                        onChanged: (value) => setState(() => _seeking = value),
                        onEnd: (value) {
                          setState(() => _seeking = null);
                          unawaited(
                            service.seekTo(
                              Duration(
                                microseconds: (length.inMicroseconds * value)
                                    .round(),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    next,
                    slot3,
                    slot4,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The player's app icon: Android shows the app's small icon (white on
/// clear) tinted with the player's colour; without one, the desktop entry's.
class _PlayerIcon extends ConsumerWidget {
  const _PlayerIcon({required this.playback, required this.colors});

  final MprisPlaybackState playback;
  final _MediaColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (playback.appIcon.isNotEmpty) {
      return _ActionIcon(
        pixels: playback.appIcon,
        color: colors.button,
        size: 24,
      );
    }
    if (playback.desktopEntry.isEmpty && playback.identity.isEmpty) {
      return const SizedBox.shrink();
    }
    final path = ref.watch(
      notificationIconPathProvider(
        NotificationIconRequest(
          appIcon: '',
          desktopEntry: playback.desktopEntry,
          appName: playback.identity,
        ),
      ),
    );
    return AppIconImage(iconPath: path.value);
  }
}

/// The output switcher's chip ("This phone").
class _OutputChip extends StatelessWidget {
  const _OutputChip({required this.colors});

  final _MediaColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.button,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.phone_android_rounded, size: 14, color: colors.onButton),
            const SizedBox(width: 4),
            Text(
              'This phone',
              style: TextStyle(
                fontFamily: 'Google Sans',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.onButton,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Android's accelerate-decelerate interpolator (an animator's default).
double _accelerateDecelerate(double t) =>
    math.cos((t.clamp(0.0, 1.0) + 1) * math.pi) / 2 + 0.5;

/// Play/pause: a pill while paused, a rounded square while playing. On a
/// change AOSP's button containers (ic_media_play_button_container and
/// ic_media_pause_button_container) swell by a ninth over 167 ms and settle
/// over 333 ms while the corners morph; the icon morphs between play and
/// pause over 333 ms (ic_media_play_button).
class _PlayPill extends StatefulWidget {
  const _PlayPill({
    required this.playing,
    required this.colors,
    required this.onTap,
  });

  final bool playing;
  final _MediaColors colors;
  final VoidCallback onTap;

  @override
  State<_PlayPill> createState() => _PlayPillState();
}

class _PlayPillState extends State<_PlayPill> with TickerProviderStateMixin {
  static const _swell = 1.17758 / 1.05905;
  static const double _pill = 20;
  static const double _square = 14;

  late final AnimationController _container = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
    value: 1,
  );
  late final AnimationController _icon = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 333),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(_PlayPill old) {
    super.didUpdateWidget(old);
    if (old.playing == widget.playing) return;
    _container.forward(from: 0);
    _icon.animateTo(widget.playing ? 1 : 0, curve: const Cubic(0.433, 0, 0, 1));
  }

  @override
  void dispose() {
    _container.dispose();
    _icon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playing = widget.playing;
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _container,
          builder: (context, icon) {
            final ms = _container.value * 500;
            final scale = ms < 167
                ? 1 +
                      (_swell - 1) *
                          const Cubic(0.226, 0, 0.667, 1).transform(ms / 167)
                : _swell +
                      (1 - _swell) *
                          const Cubic(
                            0.213,
                            0,
                            0.248,
                            1,
                          ).transform((ms - 167) / 333);
            // The corners morph after a short hold: 167 ms into a pause
            // button, 133 ms into a play button.
            final start = playing ? 167.0 : 133.0;
            final shape =
                (playing
                        ? const Cubic(0.493, 0, 0, 1)
                        : const Cubic(0.473, 0, 0.065, 1))
                    .transform(((ms - start) / (500 - start)).clamp(0.0, 1.0));
            final from = playing ? _pill : _square;
            final to = playing ? _square : _pill;
            return Transform.scale(
              scale: scale,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.colors.button,
                  borderRadius: BorderRadius.circular(
                    from + (to - from) * shape,
                  ),
                ),
                child: icon,
              ),
            );
          },
          child: Center(
            child: AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _icon,
              size: 24,
              color: widget.colors.onButton,
            ),
          ),
        ),
      ),
    );
  }
}

/// The title and artist. A new song slides them as AOSP's metadata
/// animations do: out 32 dp to the left (167 ms, fading over its second
/// half), then in from 32 dp to the right (600 ms, fading in over 167 ms).
class _SongText extends StatefulWidget {
  const _SongText({required this.title, required this.artist});

  final String title;
  final String artist;

  @override
  State<_SongText> createState() => _SongTextState();
}

class _SongTextState extends State<_SongText>
    with SingleTickerProviderStateMixin {
  static const double _exit = 167;
  static const double _enter = 600;

  late final AnimationController _change = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_exit + _enter).round()),
    value: 1,
  )..addListener(_swapWhenOut);
  late String _title = widget.title;
  late String _artist = widget.artist;

  @override
  void didUpdateWidget(_SongText old) {
    super.didUpdateWidget(old);
    if (widget.title == _title && widget.artist == _artist) return;
    // A change while sliding out only swaps the text it will show.
    if (_change.isAnimating && _change.value * (_exit + _enter) < _exit) {
      return;
    }
    _change.forward(from: 0);
  }

  void _swapWhenOut() {
    if (_change.value * (_exit + _enter) < _exit) return;
    if (widget.title == _title && widget.artist == _artist) return;
    setState(() {
      _title = widget.title;
      _artist = widget.artist;
    });
  }

  @override
  void dispose() {
    _change.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Google Sans',
            fontSize: 16,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: Color(0xFFFFFFFF),
          ),
        ),
        Text(
          _artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Google Sans',
            fontSize: 14,
            height: 1.43,
            color: Color(0xFFFFFFFF),
          ),
        ),
      ],
    );
    return AnimatedBuilder(
      animation: _change,
      child: text,
      builder: (context, child) {
        final ms = _change.value * (_exit + _enter);
        double dx;
        double alpha;
        if (ms < _exit) {
          dx = -32 * _accelerateDecelerate(ms / _exit);
          alpha = 1 - ((ms - _exit / 2) / (_exit / 2)).clamp(0.0, 1.0);
        } else {
          final t = ms - _exit;
          dx = 32 * (1 - _accelerateDecelerate(t / _enter));
          alpha = _accelerateDecelerate(t / _exit);
        }
        return Opacity(
          opacity: alpha,
          child: Transform.translate(offset: Offset(dx, 0), child: child),
        );
      },
    );
  }
}

class _MediaButton extends StatelessWidget {
  const _MediaButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.ripple,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  /// Plays the card's ripple from this button.
  final void Function(BuildContext button)? ripple;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ripple?.call(context);
          onTap();
        },
        child: SizedBox(width: 48, height: 48, child: Center(child: child)),
      ),
    );
  }
}

/// AOSP's media touch ripple (MultiRippleController with a circle
/// RippleShader, 1.5 s, at most 10 at once): a soft disc of the button
/// colour at 100/255 opacity grows from the tapped button over the whole
/// card. Timing measured on EvolutionX: the front crosses the card in about
/// 0.12 s, holds about 0.1 s, fades out by 0.45 s with a faint tail to 1.5 s.
class _CardRipples extends StatefulWidget {
  const _CardRipples({super.key, required this.color});

  final Color color;

  @override
  State<_CardRipples> createState() => _CardRipplesState();
}

class _CardRipplesState extends State<_CardRipples>
    with TickerProviderStateMixin {
  final _ripples = <({Offset centre, AnimationController time})>[];

  void play(Offset centre) {
    if (_ripples.length >= 10) return;
    final time = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    final ripple = (centre: centre, time: time);
    setState(() => _ripples.add(ripple));
    time.forward().whenComplete(() {
      time.dispose();
      if (mounted) setState(() => _ripples.remove(ripple));
    });
  }

  @override
  void dispose() {
    for (final ripple in _ripples) {
      ripple.time.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ripples.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RipplePainter(
          ripples: List.of(_ripples),
          color: widget.color,
          repaint: Listenable.merge(<Listenable>[
            for (final ripple in _ripples) ripple.time,
          ]),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.ripples,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<({Offset centre, AnimationController time})> ripples;
  final Color color;

  /// Opacity over the ripple's 1.5 s, in seconds since the tap.
  static double _opacity(double seconds) {
    const peak = 100 / 255;
    if (seconds < 0.12) return peak;
    if (seconds < 0.45) {
      return peak +
          (peak * 0.15 - peak) *
              Curves.easeOut.transform((seconds - 0.12) / 0.33);
    }
    return peak * 0.15 * (1 - (seconds - 0.45) / 1.05).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final ripple in ripples) {
      final seconds = ripple.time.value * 1.5;
      final radius =
          size.width *
          1.3 *
          Curves.easeOutCubic.transform((seconds / 0.2).clamp(0.0, 1.0));
      final alpha = _opacity(seconds);
      if (radius <= 0 || alpha <= 0) continue;
      final c = color.withValues(alpha: alpha);
      paint.shader = RadialGradient(
        colors: <Color>[c, c, c.withValues(alpha: 0)],
        stops: const <double>[0, 0.7, 1],
      ).createShader(Rect.fromCircle(center: ripple.centre, radius: radius));
      canvas.drawCircle(ripple.centre, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => true;
}

/// An app's icon from Droidloom: square RGBA at 2 px per dp (its own
/// size), drawn in one colour (white for the app's buttons).
class _ActionIcon extends StatefulWidget {
  const _ActionIcon({
    required this.pixels,
    this.color = const Color(0xFFFFFFFF),
    this.size,
  });

  final List<int> pixels;
  final Color color;

  /// A fixed size in dp; by default the icon's own (its side / 2).
  final double? size;

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  ui.Image? _image;

  int get _side {
    final pixels = widget.pixels.length ~/ 4;
    final side = math.sqrt(pixels).round();
    return side * side == pixels && widget.pixels.length % 4 == 0 ? side : 0;
  }

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_ActionIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.pixels, widget.pixels)) _decode();
  }

  void _decode() {
    final pixels = widget.pixels;
    final side = _side;
    if (side == 0) {
      _swap(null);
      return;
    }
    ui.decodeImageFromPixels(
      pixels is Uint8List ? pixels : Uint8List.fromList(pixels),
      side,
      side,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || !identical(pixels, widget.pixels)) {
          image.dispose();
          return;
        }
        _swap(image);
      },
    );
  }

  void _swap(ui.Image? image) {
    final old = _image;
    if (mounted) setState(() => _image = image);
    old?.dispose();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final size = widget.size ?? (_side == 0 ? 24.0 : _side / 2);
    if (image == null) return SizedBox(width: size, height: size);
    return ColorFiltered(
      colorFilter: ColorFilter.mode(widget.color, BlendMode.srcIn),
      child: RawImage(
        image: image,
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

/// The seek bar, AOSP's SquigglyProgress: while playing, the played part is
/// a moving wave whose height grows in (800 ms after 60 ms, emphasized
/// decelerate) and settles flat on pause (550 ms); the rest is the track at
/// 30 %; a white thumb. The wave's size is AOSP's (20 dp wavelength, 1.5 dp
/// amplitude, 8 dp/s) scaled to the 6 dp track measured on EvolutionX.
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.fraction,
    required this.enabled,
    required this.playing,
    required this.colors,
    required this.onChanged,
    required this.onEnd,
  });

  final double fraction;
  final bool enabled;
  final bool playing;
  final _MediaColors colors;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onEnd;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar>
    with SingleTickerProviderStateMixin {
  /// EvolutionX's WaveformSeekBar: a full turn of the wave every 3.5 s,
  /// its height eased in or out over 300 ms when playback starts or stops.
  static const _turn = Duration(milliseconds: 3500);
  static const _fade = Duration(milliseconds: 300);

  late final Ticker _ticker = createTicker(_onTick);
  Duration _now = Duration.zero;
  Duration _last = Duration.zero;
  double _phase = 0;
  double _height = 0;
  double _heightFrom = 0;
  double _heightTo = 0;
  Duration _heightStart = Duration.zero;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _height = _heightFrom = _heightTo = widget.playing ? 1 : 0;
    if (widget.playing) _ticker.start();
  }

  @override
  void didUpdateWidget(_SeekBar old) {
    super.didUpdateWidget(old);
    if (old.playing == widget.playing) return;
    _heightFrom = _height;
    _heightTo = widget.playing ? 1 : 0;
    if (!_ticker.isActive) {
      _now = _last = Duration.zero;
      _ticker.start();
    }
    _heightStart = _now;
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / _turn.inMicroseconds;
    _last = _now = elapsed;
    if (widget.playing) _phase = (_phase + dt * 2 * math.pi) % (2 * math.pi);
    final t = ((elapsed - _heightStart).inMicroseconds / _fade.inMicroseconds)
        .clamp(0.0, 1.0);
    // ValueAnimator's default interpolator: accelerate-decelerate.
    final eased = (math.cos((t + 1) * math.pi) / 2) + 0.5;
    _height = _heightFrom + (_heightTo - _heightFrom) * eased;
    setState(() {});
    if (!widget.playing && t >= 1) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth);
        double at(Offset local) => (local.dx / width).clamp(0.0, 1.0);
        final enabled = widget.enabled;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          onHorizontalDragStart: enabled
              ? (details) => widget.onChanged(_drag = at(details.localPosition))
              : null,
          onHorizontalDragUpdate: enabled
              ? (details) => widget.onChanged(_drag = at(details.localPosition))
              : null,
          onHorizontalDragEnd: enabled ? (_) => widget.onEnd(_drag) : null,
          onHorizontalDragCancel: enabled ? () => widget.onEnd(_drag) : null,
          child: CustomPaint(
            size: Size(width, 48),
            painter: _SeekPainter(
              fraction: widget.fraction,
              color: widget.colors.button,
              thumb: enabled,
              phase: _phase,
              height: _height,
            ),
          ),
        );
      },
    );
  }
}

/// EvolutionX's WaveformSeekBar, in dp: a 6 dp track in the media colour at
/// 30 %; the played part in the colour with its top edge raised by a sine
/// wave (80 dp long, up to 12 dp high) that tapers to the track over 0.4 of
/// a wave at both ends; a white 8 dp thumb with a soft shadow.
class _SeekPainter extends CustomPainter {
  const _SeekPainter({
    required this.fraction,
    required this.color,
    required this.thumb,
    required this.phase,
    required this.height,
  });

  final double fraction;
  final Color color;
  final bool thumb;
  final double phase;

  /// The wave's height, 0 (flat, paused) to 1 (playing).
  final double height;

  static const double _track = 6;
  static const double _corner = 8;
  static const double _waveHeight = 12;
  static const double _waveLength = 80;
  static const double _thumb = 8;

  /// The wave's top edge over [x], from [start] to the played end [end].
  double _waveY(double x, double start, double end, double top, double amp) {
    final span = end - start;
    if (span <= 0) return top;
    final from = x - start;
    final wave = (math.sin(from / _waveLength * 2 * math.pi + phase) + 1) / 2;
    const ramp = _waveLength * 0.4;
    double taper;
    if (span < ramp * 2) {
      final t = from / span;
      taper = 4 * t * (1 - t);
    } else if (from < ramp) {
      final t = from / ramp;
      taper = t * t * (3 - 2 * t);
    } else if (end - x < ramp) {
      final t = (end - x) / ramp;
      taper = t * t * (3 - 2 * t);
    } else {
      taper = 1;
    }
    return top - wave * _waveHeight * taper.clamp(0.0, 1.0) * height * amp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.height / 2;
    final top = centre - _track / 2;
    final bottom = centre + _track / 2;
    final width = size.width;
    final x = width * fraction;
    canvas.drawRRect(
      RRect.fromLTRBR(0, top, width, bottom, const Radius.circular(_corner)),
      Paint()..color = color.withAlpha(77),
    );
    final played = Paint()..color = color;
    if (x > 0 && height > 0.01) {
      // Short progress keeps a lower wave (0.3 to 1 over 0.8 of a wave).
      final amp =
          (math.sqrt((x / (_waveLength * 0.8)).clamp(0.0, 1.0)) * 0.7 + 0.3)
              .clamp(0.3, 1.0);
      final r = math.min(_track / 2, _corner);
      final start = r;
      final path = Path()
        ..moveTo(start, bottom)
        ..arcTo(
          Rect.fromLTRB(0, top, r * 2, bottom),
          math.pi / 2,
          math.pi / 2,
          false,
        )
        ..quadraticBezierTo(0, top, start, _waveY(start, start, x, top, amp));
      if (x > start) {
        // Points every 2 dp, joined by a Catmull-Rom spline.
        final points = <Offset>[
          for (var px = start; px <= x; px += 2)
            Offset(px, _waveY(px, start, x, top, amp)),
        ];
        if (points.isEmpty || points.last.dx < x) {
          points.add(Offset(x, _waveY(x, start, x, top, amp)));
        }
        if (points.length < 2) {
          path.lineTo(x, top);
        } else {
          for (var i = 0; i < points.length - 1; i++) {
            final p0 = points[i > 0 ? i - 1 : i];
            final p1 = points[i];
            final p2 = points[i + 1];
            final p3 = points[i + 2 < points.length ? i + 2 : i + 1];
            path.cubicTo(
              p1.dx + (p2.dx - p0.dx) * 0.5 / 3,
              p1.dy + (p2.dy - p0.dy) * 0.5 / 3,
              p2.dx - (p3.dx - p1.dx) * 0.5 / 3,
              p2.dy - (p3.dy - p1.dy) * 0.5 / 3,
              p2.dx,
              p2.dy,
            );
          }
        }
      }
      path
        ..lineTo(x, top)
        ..lineTo(x, bottom)
        ..close();
      canvas.drawPath(path, played);
    } else if (x > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, top, x, bottom, const Radius.circular(_corner)),
        played,
      );
    }
    if (thumb) {
      canvas.drawCircle(
        Offset(x, centre + 2),
        _thumb,
        Paint()..color = const Color(0x3C000000),
      );
      canvas.drawShadow(
        Path()
          ..addOval(Rect.fromCircle(center: Offset(x, centre), radius: _thumb)),
        const Color(0x50000000),
        2,
        false,
      );
      canvas.drawCircle(
        Offset(x, centre),
        _thumb,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.thumb != thumb ||
      old.phase != phase ||
      old.height != height;
}
