import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart'
    show ColorScheme, DynamicSchemeVariant, Icons;
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
  /// The art's blur while playing, in dp.
  static const double _playingBlur = 12;

  // A ticker, not a timer: it stops while the shade is closed (TickerMode).
  late final Ticker _tick = createTicker(_onTick);
  Duration _shown = Duration.zero;
  String _artUrl = '';
  ImageProvider? _art;
  _MediaColors _colors = _MediaColors.fallback;

  /// A seek drag in progress, as a fraction of the track.
  double? _seeking;

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
        onTap: () => unawaited(service.invokeAction(action.id)),
        child: _ActionIcon(pixels: action.icon),
      );
    }

    final previous = live && playback.canGoPrevious
        ? _MediaButton(
            tooltip: 'Previous',
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
          height: PixelMediaCard.height,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (art != null)
                // EvolutionX blurs the art while the player plays.
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    end: live && playback.playing ? _playingBlur : 0,
                  ),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.fastOutSlowIn,
                  builder: (context, sigma, child) => sigma < 0.1
                      ? child!
                      : ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: sigma,
                            sigmaY: sigma,
                            tileMode: TileMode.clamp,
                          ),
                          child: child,
                        ),
                  child: Image(
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
              Positioned(
                left: 16,
                top: 16,
                width: 24,
                height: 24,
                child: _PlayerIcon(playback: playback),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playback.title,
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
                      playback.artistLabel,
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
                ),
              ),
              Positioned(
                right: 23,
                top: 75,
                width: 58,
                height: 40,
                child: _PlayPill(
                  playing: playback.playing,
                  colors: colors,
                  // A player that is gone resumes in its app.
                  onTap: live
                      ? () => unawaited(service.playPause())
                      : playback.desktopEntry.isEmpty
                      ? () {}
                      : _open,
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

/// The player's app icon, from its desktop entry.
class _PlayerIcon extends ConsumerWidget {
  const _PlayerIcon({required this.playback});

  final MprisPlaybackState playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

/// Play/pause: a pill while paused, a rounded square while playing.
class _PlayPill extends StatelessWidget {
  const _PlayPill({
    required this.playing,
    required this.colors,
    required this.onTap,
  });

  final bool playing;
  final _MediaColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.fastOutSlowIn,
          decoration: BoxDecoration(
            color: colors.button,
            borderRadius: BorderRadius.circular(playing ? 14 : 20),
          ),
          child: Center(
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 24,
              color: colors.onButton,
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaButton extends StatelessWidget {
  const _MediaButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(width: 48, height: 48, child: Center(child: child)),
      ),
    );
  }
}

/// An app's own button icon: 48 px RGBA, drawn white at 24 dp.
class _ActionIcon extends StatefulWidget {
  const _ActionIcon({required this.pixels});

  final List<int> pixels;

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  static const int _size = 48;
  ui.Image? _image;

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
    if (pixels.length != _size * _size * 4) {
      _swap(null);
      return;
    }
    ui.decodeImageFromPixels(
      pixels is Uint8List ? pixels : Uint8List.fromList(pixels),
      _size,
      _size,
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
    if (image == null) return const SizedBox(width: 24, height: 24);
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Color(0xFFFFFFFF), BlendMode.srcIn),
      child: RawImage(
        image: image,
        width: 24,
        height: 24,
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
  static const double _track = 6;
  static const double _waveLength = 20 * _track / 2;
  static const double _amplitude = 1.5 * _track / 2;
  static const double _phaseSpeed = 8 * _track / 2;

  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  double _phase = 0;
  double _height = 0;
  double _heightFrom = 0;
  double _heightTo = 0;
  Duration _heightStart = Duration.zero;
  Duration _now = Duration.zero;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _height = widget.playing ? 1 : 0;
    _heightFrom = _heightTo = _height;
    if (widget.playing) _ticker.start();
  }

  @override
  void didUpdateWidget(_SeekBar old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      _heightFrom = _height;
      _heightTo = widget.playing ? 1 : 0;
      _heightStart = _now;
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _now = Duration.zero;
        _heightStart = Duration.zero;
        _ticker.start();
      }
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _now = elapsed;
    if (widget.playing) {
      _phase = (_phase + dt * _phaseSpeed) % _waveLength;
    }
    final growing = _heightTo > _heightFrom;
    final delay = growing ? 60 : 0;
    final span = growing ? 800 : 550;
    final t = ((elapsed - _heightStart).inMilliseconds - delay) / span;
    final curve = growing
        ? Curves
              .easeOutQuint // emphasized decelerate
        : Curves.decelerate; // standard decelerate
    _height =
        _heightFrom +
        (_heightTo - _heightFrom) * curve.transform(t.clamp(0.0, 1.0));
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
              active: widget.colors.button,
              thumb: enabled,
              phase: _phase,
              height: _height,
              track: _track,
              waveLength: _waveLength,
              amplitude: _amplitude,
            ),
          ),
        );
      },
    );
  }
}

class _SeekPainter extends CustomPainter {
  const _SeekPainter({
    required this.fraction,
    required this.active,
    required this.thumb,
    required this.phase,
    required this.height,
    required this.track,
    required this.waveLength,
    required this.amplitude,
  });

  final double fraction;
  final Color active;
  final bool thumb;
  final double phase;
  final double height;
  final double track;
  final double waveLength;
  final double amplitude;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final width = size.width;
    final x = width * fraction;
    final rest = Paint()
      ..color = const Color(0x4DFFFFFF)
      ..strokeWidth = track
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final played = Paint()
      ..color = active
      ..strokeWidth = track
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // The rest of the track, flat.
    if (x < width - track / 2) {
      canvas.drawLine(
        Offset(math.max(x, track / 2), y),
        Offset(width - track / 2, y),
        rest,
      );
    }
    if (x > 0) {
      final amp = amplitude * height;
      if (amp < 0.05) {
        canvas.drawLine(
          Offset(track / 2, y),
          Offset(math.max(track / 2, x), y),
          played,
        );
      } else {
        // AOSP: a wave of half-wavelength cubic segments, starting before
        // the bar and moving right; the bar's start keeps a round cap.
        final path = Path();
        var cx = -phase - waveLength / 2;
        var sign = 1.0;
        path.moveTo(cx, y + sign * amp);
        while (cx < x) {
          sign = -sign;
          final nx = cx + waveLength / 2;
          final mx = cx + waveLength / 4;
          path.cubicTo(
            mx,
            y - sign * amp,
            mx,
            y + sign * amp,
            nx,
            y + sign * amp,
          );
          cx = nx;
        }
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(0, 0, x, size.height));
        canvas.translate(track / 2, 0);
        canvas.drawPath(path, played);
        canvas.restore();
      }
    }
    if (thumb) {
      canvas.drawCircle(
        Offset(x.clamp(8.0, math.max(8.0, width - 8)), y),
        8,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.fraction != fraction ||
      old.active != active ||
      old.thumb != thumb ||
      old.phase != phase ||
      old.height != height;
}
