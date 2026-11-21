import 'package:meta/meta.dart';

enum MprisPlaybackStatus { playing, paused, stopped }

/// One of the player's own buttons (an Android app's custom action, from
/// Droidloom's `org.droidloom.MediaPlayer2.Actions`): its id, its label and
/// its 48 px RGBA icon, or none.
@immutable
class MprisCustomAction {
  const MprisCustomAction({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;

  /// 48 × 48 RGBA pixels, or empty.
  final List<int> icon;

  @override
  bool operator ==(Object other) =>
      other is MprisCustomAction &&
      other.id == id &&
      other.label == label &&
      identical(other.icon, icon);

  @override
  int get hashCode => Object.hash(id, label, icon.length);
}

@immutable
class MprisPlaybackState {
  const MprisPlaybackState({
    required this.serviceName,
    required this.identity,
    required this.title,
    required this.artists,
    required this.album,
    required this.artUrl,
    required this.length,
    required this.position,
    required this.observedAt,
    required this.status,
    required this.canGoNext,
    required this.canGoPrevious,
    required this.canPlay,
    required this.canPause,
    this.desktopEntry = '',
    this.trackId = '',
    this.canSeek = false,
    this.actions = const <MprisCustomAction>[],
  });

  MprisPlaybackState.unavailable()
    : serviceName = '',
      identity = '',
      title = '',
      artists = const <String>[],
      album = '',
      artUrl = '',
      length = Duration.zero,
      position = Duration.zero,
      observedAt = DateTime.fromMillisecondsSinceEpoch(0),
      status = MprisPlaybackStatus.stopped,
      canGoNext = false,
      canGoPrevious = false,
      canPlay = false,
      canPause = false,
      desktopEntry = '',
      trackId = '',
      canSeek = false,
      actions = const <MprisCustomAction>[];

  final String serviceName;
  final String identity;
  final String title;
  final List<String> artists;
  final String album;
  final String artUrl;
  final Duration length;
  final Duration position;
  final DateTime observedAt;
  final MprisPlaybackStatus status;
  final bool canGoNext;
  final bool canGoPrevious;
  final bool canPlay;
  final bool canPause;

  /// The player's desktop entry (without `.desktop`), for its icon and to
  /// open it; empty when the player names none.
  final String desktopEntry;

  /// `mpris:trackid`, which `SetPosition` needs.
  final String trackId;
  final bool canSeek;
  final List<MprisCustomAction> actions;

  MprisPlaybackState copyWith({
    String? title,
    List<String>? artists,
    String? album,
    String? artUrl,
    Duration? length,
    Duration? position,
    DateTime? observedAt,
    MprisPlaybackStatus? status,
    bool? canGoNext,
    bool? canGoPrevious,
    bool? canPlay,
    bool? canPause,
    String? desktopEntry,
    String? trackId,
    bool? canSeek,
    List<MprisCustomAction>? actions,
  }) => MprisPlaybackState(
    serviceName: serviceName,
    identity: identity,
    title: title ?? this.title,
    artists: artists ?? this.artists,
    album: album ?? this.album,
    artUrl: artUrl ?? this.artUrl,
    length: length ?? this.length,
    position: position ?? this.position,
    observedAt: observedAt ?? this.observedAt,
    status: status ?? this.status,
    canGoNext: canGoNext ?? this.canGoNext,
    canGoPrevious: canGoPrevious ?? this.canGoPrevious,
    canPlay: canPlay ?? this.canPlay,
    canPause: canPause ?? this.canPause,
    desktopEntry: desktopEntry ?? this.desktopEntry,
    trackId: trackId ?? this.trackId,
    canSeek: canSeek ?? this.canSeek,
    actions: actions ?? this.actions,
  );

  bool get available =>
      serviceName.isNotEmpty &&
      (status == MprisPlaybackStatus.playing ||
          status == MprisPlaybackStatus.paused);

  bool get playing => status == MprisPlaybackStatus.playing;

  String get artistLabel => artists.join(', ');

  Duration positionAt(DateTime now) {
    if (!playing || length <= Duration.zero) {
      return position;
    }
    final elapsed = now.difference(observedAt);
    if (elapsed.isNegative) {
      return position;
    }
    final advanced = position + elapsed;
    return advanced > length ? length : advanced;
  }
}
