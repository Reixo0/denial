import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One placed quick-settings tile: its id and whether it is large (two
/// columns, icon and label) or an icon tile (one column).
class QsTileSlot {
  const QsTileSlot(this.id, {this.wide = false});

  final String id;
  final bool wide;
}

/// The quick-settings tiles in order, as AOSP keeps `sysui_qs_tiles` and
/// its large-tile set; kept in `~/.config/denial/qs-tiles.json`.
final qsTileLayoutProvider =
    NotifierProvider<QsTileLayoutController, List<QsTileSlot>>(
      QsTileLayoutController.new,
    );

class QsTileLayoutController extends Notifier<List<QsTileSlot>> {
  static const List<QsTileSlot> defaults = <QsTileSlot>[
    QsTileSlot('wifi', wide: true),
    QsTileSlot('bluetooth', wide: true),
    QsTileSlot('silent'),
    QsTileSlot('rotation'),
    QsTileSlot('power_profile'),
    QsTileSlot('flashlight'),
    QsTileSlot('screen_record'),
    QsTileSlot('mobile_data', wide: true),
    QsTileSlot('desktop'),
  ];

  @override
  List<QsTileSlot> build() => _load();

  static File? _file() {
    final home = Platform.environment['HOME'];
    return home == null ? null : File('$home/.config/denial/qs-tiles.json');
  }

  static List<QsTileSlot> _load() {
    try {
      final data = jsonDecode(_file()!.readAsStringSync());
      final entries = data is Map ? data['tiles'] : null;
      if (entries is! List) return defaults;
      final slots = <QsTileSlot>[];
      for (final entry in entries.whereType<Map<Object?, Object?>>()) {
        final id = entry['id'];
        if (id is! String || slots.any((s) => s.id == id)) continue;
        slots.add(QsTileSlot(id, wide: entry['wide'] == true));
      }
      return slots;
    } on Object {
      return defaults;
    }
  }

  void _set(List<QsTileSlot> slots) {
    state = slots;
    final file = _file();
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(<String, Object>{
          'tiles': <Object>[
            for (final slot in slots)
              <String, Object>{'id': slot.id, 'wide': slot.wide},
          ],
        }),
      );
    } on Object {
      // Not saved: the layout still holds for this session.
    }
  }

  void remove(String id) =>
      _set(<QsTileSlot>[...state]..removeWhere((s) => s.id == id));

  /// AOSP adds a tile at the end, as an icon tile.
  void add(String id) {
    if (state.any((s) => s.id == id)) return;
    _set(<QsTileSlot>[...state, QsTileSlot(id)]);
  }

  void setWide(String id, bool wide) => _set(<QsTileSlot>[
    for (final slot in state) slot.id == id ? QsTileSlot(id, wide: wide) : slot,
  ]);

  /// Moves [id] into [target]'s place in the order.
  void move(String id, String target) {
    final from = state.indexWhere((s) => s.id == id);
    final to = state.indexWhere((s) => s.id == target);
    if (from < 0 || to < 0 || from == to) return;
    final slots = <QsTileSlot>[...state];
    slots.insert(to, slots.removeAt(from));
    _set(slots);
  }

  void reset() => _set(defaults);
}

/// Whether the shade shows "Edit tiles" in place of quick settings.
final qsEditingProvider = NotifierProvider<QsEditingController, bool>(
  QsEditingController.new,
);

class QsEditingController extends Notifier<bool> {
  @override
  bool build() => false;

  void start() => state = true;

  void stop() => state = false;
}
