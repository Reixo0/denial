import 'package:dbus/dbus.dart';

import '../models/mpris_playback.dart';
import 'mpris_playback_protocol.dart';

/// Retains only the latest relevant fields signalled during one player read.
/// The refresh still supplies untouched fields, including updated identity and
/// capabilities. Storage stays bounded by the seven properties the shell uses.
final class MprisReadReconciliation {
  MprisReadReconciliation(this._current);

  MprisPlaybackState _current;
  MprisPlaybackState get current => _current;
  Map<String, DBusValue>? _changed;
  bool _clockChanged = false;

  void record(Map<String, DBusValue> changed, MprisPlaybackState next) {
    // Repeated metadata/status reports still override those fields in a stale
    // reply, but must not discard a fresh position supplied by the reply.
    _clockChanged =
        _clockChanged ||
        changed['Position'] != null ||
        next.status != current.status ||
        next.length != current.length ||
        (changed['Metadata'] != null &&
            (next.title != current.title ||
                !identical(next.artists, current.artists) ||
                next.album != current.album ||
                next.artUrl != current.artUrl));
    for (final name in mprisPlayerProperties) {
      final value = changed[name];
      if (value == null) continue;
      (_changed ??= {})[name] = value;
    }
    _current = next;
  }

  MprisPlaybackState? resolve(
    String serviceName,
    Map<String, DBusValue> player,
    Map<String, DBusValue> root,
    DateTime observedAt,
  ) {
    final changed = _changed;
    final state = parseMprisPlaybackState(
      serviceName,
      changed == null ? player : {...player, ...changed},
      root,
      observedAt,
    );
    if (state == null || !_clockChanged) return state;
    final length = state.length;
    return state.copyWith(
      position: length > Duration.zero && current.position > length
          ? length
          : current.position,
      observedAt: current.observedAt,
    );
  }
}
