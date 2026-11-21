import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../../state/phone_desk.dart';
import '../../state/quick_settings.dart';
import '../phone_scheme.dart';
import '../shade/quick_settings_panel.dart' show PixelShadeViewport;

enum _Page { menu, restart, confirm }

class _Pending {
  const _Pending({
    required this.title,
    required this.icon,
    required this.slideLabel,
    required this.run,
    required this.fromRestart,
  });

  final String title;
  final IconData icon;
  final String slideLabel;
  final Future<void> Function() run;

  /// Picked from the restart choices: Back returns there.
  final bool fromRestart;
}

/// The actions the menu can hold. A new action added here shows up in the
/// editor's "Add Actions" list until it is placed.
enum _MenuAction {
  powerOff('power_off', 4, 1),
  restart('restart', 4, 1),
  lock('lock', 2, 1),
  screenshot('screenshot', 2, 1);

  const _MenuAction(this.id, this.cols, this.rows);

  final String id;

  /// The span it gets when placed.
  final int cols;
  final int rows;

  IconData get icon => switch (this) {
    powerOff => Icons.power_settings_new_rounded,
    restart => Icons.restart_alt_rounded,
    lock => Icons.lock_outline_rounded,
    screenshot => Icons.screenshot_rounded,
  };

  String label(AppLocalizations l10n) => switch (this) {
    powerOff => l10n.powerActionPowerOff,
    restart => l10n.powerActionRestart,
    lock => l10n.powerActionLock,
    screenshot => l10n.powerMenuScreenshot,
  };
}

/// One placed tile (EvolutionX's TileConfig): 1–4 columns, 1–3 rows.
class _Tile {
  const _Tile(this.action, this.cols, this.rows);

  final _MenuAction action;
  final int cols;
  final int rows;

  _Tile resized(int cols, int rows) => _Tile(action, cols, rows);
}

/// The placed tiles, in order, kept in `~/.config/denial/power-menu.json`
/// as EvolutionX keeps `active_tiles`: id, spanCols, spanRows.
abstract final class _Layout {
  static const List<_Tile> defaults = <_Tile>[
    _Tile(_MenuAction.powerOff, 4, 1),
    _Tile(_MenuAction.restart, 4, 1),
  ];

  static File? _file() {
    final home = Platform.environment['HOME'];
    return home == null ? null : File('$home/.config/denial/power-menu.json');
  }

  static List<_Tile> load() {
    try {
      final data = jsonDecode(_file()!.readAsStringSync());
      final entries = data is Map ? data['active_tiles'] : null;
      if (entries is! List) return defaults;
      final tiles = <_Tile>[];
      for (final entry in entries.whereType<Map<Object?, Object?>>()) {
        final action = _MenuAction.values
            .where((a) => a.id == entry['id'])
            .firstOrNull;
        if (action == null || tiles.any((t) => t.action == action)) continue;
        int span(Object? value, int fallback, int max) =>
            value is int ? value.clamp(1, max) : fallback;
        tiles.add(
          _Tile(
            action,
            span(entry['spanCols'], action.cols, 4),
            span(entry['spanRows'], action.rows, 3),
          ),
        );
      }
      return tiles.isEmpty ? defaults : tiles;
    } on Object {
      return defaults;
    }
  }

  static void save(List<_Tile> tiles) {
    final file = _file();
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(<String, Object>{
          'active_tiles': <Object>[
            for (final tile in tiles)
              <String, Object>{
                'id': tile.action.id,
                'spanCols': tile.cols,
                'spanRows': tile.rows,
              },
          ],
        }),
      );
    } on Object {
      // Not saved: the layout still holds until the menu closes.
    }
  }
}

IconData restartTargetIcon(String name) => switch (name) {
  'android' => Icons.android_rounded,
  'linux' => Icons.terminal_rounded,
  'bootloader' => Icons.memory_rounded,
  'recovery' => Icons.healing_rounded,
  'shell' => Icons.dashboard_rounded,
  _ => Icons.refresh_rounded,
};

/// EvolutionX's power menu (SystemUI globalactions/compose,
/// GlobalActionsComposeDialog): a card with Power off and Restart over the
/// dimmed, blurred screen; Restart lists the restart targets; each action is
/// confirmed with a slide. Laid out in Android's dp ([PixelShadeViewport]).
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
  bool _editing = false;
  List<_Tile> _tiles = _Layout.load();

  void _setTiles(List<_Tile> tiles) {
    setState(() => _tiles = tiles);
    _Layout.save(tiles);
  }

  void _remove(_Tile tile) => _setTiles(
    <_Tile>[..._tiles]..removeWhere((t) => t.action == tile.action),
  );

  void _add(_MenuAction action) =>
      _setTiles(<_Tile>[..._tiles, _Tile(action, action.cols, action.rows)]);

  void _resize(_Tile tile, int cols, int rows) => _setTiles(<_Tile>[
    for (final t in _tiles) t.action == tile.action ? t.resized(cols, rows) : t,
  ]);

  void _activate(_MenuAction action, List<RestartTarget> targets) {
    switch (action) {
      case _MenuAction.powerOff:
        _confirm(_powerOff());
      case _MenuAction.restart:
        _openRestart(targets);
      case _MenuAction.lock:
        final power = ref.read(sessionPowerProvider.notifier);
        widget.onClose();
        unawaited(power.request(SessionPowerAction.lock));
      case _MenuAction.screenshot:
        // Taken once the menu has faded out (the settle delay).
        final settings = ref.read(quickSettingsProvider.notifier);
        widget.onClose();
        unawaited(settings.takeScreenshot());
    }
  }

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
      fromRestart: false,
    );
  }

  _Pending _restart(RestartTarget target, {required bool fromRestart}) {
    final controller = ref.read(sessionPowerProvider.notifier);
    return _Pending(
      title: target.label,
      icon: restartTargetIcon(target.icon),
      slideLabel: context.l10n.powerMenuSlideRestart,
      run: () => controller.restartTo(target),
      fromRestart: fromRestart,
    );
  }

  void _openRestart(List<RestartTarget> targets) {
    if (targets.length == 1) {
      _confirm(_restart(targets.single, fromRestart: false));
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

  /// EvolutionX: the restart choices go back to the menu; a confirmation
  /// back to where it was picked.
  void _back() {
    if (_running) return;
    switch (_page) {
      case _Page.menu when _editing:
        setState(() => _editing = false);
      case _Page.menu:
        widget.onClose();
      case _Page.restart:
        setState(() => _page = _Page.menu);
      case _Page.confirm:
        setState(() {
          _page = _pending?.fromRestart ?? false ? _Page.restart : _Page.menu;
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
        tiles: _tiles,
        editing: _editing,
        onEdit: () => setState(() => _editing = !_editing),
        onTap: (action) => _activate(action, targets),
        onRemove: _remove,
        onResize: _resize,
        onAdd: _add,
      ),
      _Page.restart => _RestartCard(
        key: const ValueKey<String>('power-restart'),
        scheme: scheme,
        targets: targets,
        onTarget: (target) => _confirm(_restart(target, fromRestart: true)),
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
              : const Duration(milliseconds: 220),
          curve: Curves.fastOutSlowIn,
          builder: (context, t, child) => Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // The dialog window: dim 0.4 with the blur behind it.
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
              Positioned.fromRect(
                rect: outputRect,
                child: PixelShadeViewport(
                  child: Center(
                    child: Opacity(
                      opacity: t,
                      child: Transform.scale(
                        scale: 0.9 + 0.1 * t,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          child: _ViewTransition(
            reduceMotion: reduceMotion,
            current: page.key!,
            child: page,
          ),
        ),
      ),
    );
  }
}

/// EvolutionX's view_transition: the new view fades in over 220 ms while
/// it scales up from 0.9; the old one fades out over 200 ms.
class _ViewTransition extends StatelessWidget {
  const _ViewTransition({
    required this.reduceMotion,
    required this.current,
    required this.child,
  });

  final bool reduceMotion;
  final Key current;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
    reverseDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200),
    switchInCurve: Curves.fastOutSlowIn,
    switchOutCurve: Curves.fastOutSlowIn,
    transitionBuilder: (child, animation) {
      final fade = FadeTransition(opacity: animation, child: child);
      if (child.key != current) return fade;
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: 0.9,
            end: 1,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
      );
    },
    child: child,
  );
}

/// Material 3's type scale, in the sizes EvolutionX uses.
abstract final class _Type {
  static const headlineSmall = TextStyle(fontSize: 24, height: 32 / 24);
  static const headlineMedium = TextStyle(fontSize: 28, height: 36 / 28);
  static const titleMedium = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    letterSpacing: 0.15,
  );
  static const bodyLarge = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    letterSpacing: 0.5,
  );
  static const labelMedium = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.5,
    fontWeight: FontWeight.w500,
  );
  static const labelLarge = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    letterSpacing: 0.1,
    fontWeight: FontWeight.w500,
  );
}

/// The menu cards (PowerMenuContainer): 340 dp with 16 dp around, so
/// 308 dp shown; 32 dp corners; `surface` at tonal elevation 6 with an
/// 8 dp shadow; 24 dp inside.
class _Card extends StatelessWidget {
  const _Card({
    required this.scheme,
    required this.child,
    this.padding = const EdgeInsets.all(inset),
  });

  static const double width = 340 - 32;
  static const double inset = 24;

  final EdgeInsets padding;

  /// Compose's surfaceColorAtElevation(6.dp): primary over surface at
  /// (4.5 ln(7) + 2) %.
  static Color colorOf(ColorScheme scheme) => Color.alphaBlend(
    scheme.primary.withValues(alpha: (4.5 * math.log(7) + 2) / 100),
    scheme.surface,
  );

  final ColorScheme scheme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Taps on the card must not reach the scrim behind it.
      onTap: () {},
      child: Container(
        width: math.min(width, MediaQuery.sizeOf(context).width - 32),
        padding: padding,
        decoration: BoxDecoration(
          color: colorOf(scheme),
          borderRadius: BorderRadius.circular(32),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 16,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// GlobalActionsScreen's card: MenuHeader, 24 dp, the tile grid; in edit
/// mode ("Arrange Tiles") each tile gets a remove badge and a resize
/// handle, and the actions not placed are listed under "Add Actions".
class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.scheme,
    required this.tiles,
    required this.editing,
    required this.onEdit,
    required this.onTap,
    required this.onRemove,
    required this.onResize,
    required this.onAdd,
    super.key,
  });

  final ColorScheme scheme;
  final List<_Tile> tiles;
  final bool editing;
  final VoidCallback onEdit;
  final ValueChanged<_MenuAction> onTap;
  final ValueChanged<_Tile> onRemove;
  final void Function(_Tile tile, int cols, int rows) onResize;
  final ValueChanged<_MenuAction> onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inactive = <_MenuAction>[
      for (final action in _MenuAction.values)
        if (!tiles.any((t) => t.action == action)) action,
    ];
    const side = EdgeInsets.symmetric(horizontal: _Card.inset);
    return _Card(
      scheme: scheme,
      // The grid takes the sides itself: its badges stand out of the tiles.
      padding: const EdgeInsets.symmetric(vertical: _Card.inset),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastOutSlowIn,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: side,
              child: _MenuHeader(
                scheme: scheme,
                editing: editing,
                onEdit: onEdit,
              ),
            ),
            const SizedBox(height: 24 - _TileGrid.bleed),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _Card.inset - _TileGrid.bleed,
              ),
              child: _TileGrid(
                scheme: scheme,
                tiles: tiles,
                editing: editing,
                onTap: onTap,
                onRemove: onRemove,
                onResize: onResize,
              ),
            ),
            if (editing && inactive.isNotEmpty)
              Padding(
                padding: side + const EdgeInsets.only(top: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(height: 1, color: scheme.outlineVariant),
                    const SizedBox(height: 16),
                    Text(
                      l10n.powerMenuAddActions,
                      style: _Type.labelLarge.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        for (final action in inactive)
                          _InactiveChip(
                            scheme: scheme,
                            action: action,
                            onTap: () => onAdd(action),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// MenuHeader: the title (headlineSmall, bold; "Arrange Tiles" while
/// editing) and a filled icon button, the pencil (surfaceVariant) or the
/// check (primary) that leaves edit mode.
class _MenuHeader extends StatelessWidget {
  const _MenuHeader({
    required this.scheme,
    required this.editing,
    required this.onEdit,
  });

  final ColorScheme scheme;
  final bool editing;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final container = editing ? scheme.primary : scheme.surfaceContainerHighest;
    final content = editing ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            editing ? l10n.powerMenuArrange : l10n.powerMenuTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _Type.headlineSmall.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Semantics(
          button: true,
          label: editing ? l10n.powerMenuDone : l10n.powerMenuEdit,
          child: _Pressable(
            onTap: onEdit,
            builder: (context, pressed) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _pressedOn(container, content, pressed),
                shape: BoxShape.circle,
              ),
              child: Icon(
                editing ? Icons.check_rounded : Icons.edit_rounded,
                size: 20,
                color: content,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// EvolutionX's DraggableGrid: four square columns 12 dp apart; each tile
/// takes the first free spot, row by row, that fits its span.
class _TileGrid extends StatelessWidget {
  const _TileGrid({
    required this.scheme,
    required this.tiles,
    required this.editing,
    required this.onTap,
    required this.onRemove,
    required this.onResize,
  });

  static const int columns = 4;
  static const double spacing = 12;

  /// Room around the grid for the remove badges (8 dp out of each tile's
  /// top-end corner), so they can be tapped.
  static const double bleed = 8;

  final ColorScheme scheme;
  final List<_Tile> tiles;
  final bool editing;
  final ValueChanged<_MenuAction> onTap;
  final ValueChanged<_Tile> onRemove;
  final void Function(_Tile tile, int cols, int rows) onResize;

  /// Each tile's (column, row), first fit.
  static List<(int, int)> place(List<_Tile> tiles) {
    final taken = <(int, int)>{};
    final spots = <(int, int)>[];
    for (final tile in tiles) {
      for (var y = 0; ; y++) {
        int? found;
        for (var x = 0; x + tile.cols <= columns && found == null; x++) {
          var free = true;
          for (var dy = 0; dy < tile.rows && free; dy++) {
            for (var dx = 0; dx < tile.cols && free; dx++) {
              free = !taken.contains((x + dx, y + dy));
            }
          }
          if (free) found = x;
        }
        if (found == null) continue;
        spots.add((found, y));
        for (var dy = 0; dy < tile.rows; dy++) {
          for (var dx = 0; dx < tile.cols; dx++) {
            taken.add((found + dx, y + dy));
          }
        }
        break;
      }
    }
    return spots;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 2 * bleed;
        final cell = (width - (columns - 1) * spacing) / columns;
        final step = cell + spacing;
        final spots = place(tiles);
        var rows = 0;
        for (var i = 0; i < tiles.length; i++) {
          rows = math.max(rows, spots[i].$2 + tiles[i].rows);
        }
        final height = rows == 0 ? 0.0 : rows * step - spacing;
        return SizedBox(
          height: bleed + height,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              for (var i = 0; i < tiles.length; i++)
                AnimatedPositioned(
                  key: ValueKey<_MenuAction>(tiles[i].action),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.fastOutSlowIn,
                  left: bleed + spots[i].$1 * step,
                  top: spots[i].$2 * step,
                  width: tiles[i].cols * step - spacing + bleed,
                  height: tiles[i].rows * step - spacing + bleed,
                  child: _GridTile(
                    scheme: scheme,
                    tile: tiles[i],
                    editing: editing,
                    removable: tiles.length > 1,
                    step: step,
                    onTap: () => onTap(tiles[i].action),
                    onRemove: () => onRemove(tiles[i]),
                    onResize: (cols, rows) => onResize(tiles[i], cols, rows),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.builder});

  final VoidCallback? onTap;
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
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      child: widget.builder(context, _pressed && enabled),
    );
  }
}

/// Material's pressed state layer over [color].
Color _pressedOn(Color color, Color content, bool pressed) =>
    pressed ? Color.alphaBlend(content.withValues(alpha: 0.1), color) : color;

/// TileItem: `surfaceVariant`, 24 dp corners. One column: the icon (32 dp)
/// centred. Wider: 16 dp inside, the icon at the start (held to the 24 dp
/// left inside a one-row tile) and the label centred, titleMedium semibold.
/// In edit mode: not tappable, a 2 dp primary@0.5 outline, the remove badge
/// (28 dp, `error`, 8 dp out of the top-end corner) and the resize handle
/// in the bottom-end corner. The box is [_TileGrid.bleed] larger than the
/// tile, up and to the end, to hold the badge.
class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.scheme,
    required this.tile,
    required this.editing,
    required this.removable,
    required this.step,
    required this.onTap,
    required this.onRemove,
    required this.onResize,
  });

  final ColorScheme scheme;
  final _Tile tile;
  final bool editing;
  final bool removable;
  final double step;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final void Function(int cols, int rows) onResize;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = tile.action.label(l10n);
    final content = scheme.onSurfaceVariant;
    const bleed = _TileGrid.bleed;
    return Stack(
      children: <Widget>[
        Positioned(
          left: 0,
          top: bleed,
          right: bleed,
          bottom: 0,
          child: Semantics(
            button: !editing,
            label: label,
            child: _Pressable(
              onTap: editing ? null : onTap,
              builder: (context, pressed) => Container(
                decoration: BoxDecoration(
                  color: _pressedOn(
                    scheme.surfaceContainerHighest,
                    content,
                    pressed,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                foregroundDecoration: editing
                    ? BoxDecoration(
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.5),
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(24),
                      )
                    : null,
                child: tile.cols == 1
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: Center(
                          child: Icon(
                            tile.action.icon,
                            size: 32,
                            color: content,
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(16),
                        child: LayoutBuilder(
                          builder: (context, inner) => Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Icon(
                                  tile.action.icon,
                                  size: math.min(32, inner.maxHeight),
                                  color: content,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 40,
                                ),
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: _Type.titleMedium.copyWith(
                                    color: content,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
        if (editing) ...<Widget>[
          Positioned(
            right: bleed,
            bottom: 0,
            child: _ResizeHandle(
              scheme: scheme,
              cols: tile.cols,
              rows: tile.rows,
              step: step,
              onResize: onResize,
            ),
          ),
          if (removable)
            Positioned(
              right: 0,
              top: 0,
              child: Semantics(
                button: true,
                label: '${l10n.powerMenuRemove} $label',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: scheme.error,
                      shape: BoxShape.circle,
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 4,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: scheme.onError,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// ResizeHandle: a 40 dp target holding a 24 dp tertiaryContainer circle
/// with the drag handle turned 45°. Dragging past 3/4 of a grid step adds
/// or takes a column (1–4) or row (1–3).
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.scheme,
    required this.cols,
    required this.rows,
    required this.step,
    required this.onResize,
  });

  final ColorScheme scheme;
  final int cols;
  final int rows;
  final double step;
  final void Function(int cols, int rows) onResize;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  double _dx = 0;
  double _dy = 0;

  void _start(DragStartDetails details) {
    _dx = 0;
    _dy = 0;
  }

  void _update(DragUpdateDetails details) {
    _dx += details.delta.dx;
    _dy += details.delta.dy;
    final threshold = widget.step * 0.75;
    final dc = _dx.abs() > threshold ? (_dx / threshold).truncate() : 0;
    final dr = _dy.abs() > threshold ? (_dy / threshold).truncate() : 0;
    if (dc == 0 && dr == 0) return;
    final cols = (widget.cols + dc).clamp(1, 4);
    final rows = (widget.rows + dr).clamp(1, 3);
    if (cols == widget.cols && rows == widget.rows) return;
    if (cols != widget.cols) _dx = 0;
    if (rows != widget.rows) _dy = 0;
    widget.onResize(cols, rows);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    return Semantics(
      label: context.l10n.powerMenuResize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: _start,
        onPanUpdate: _update,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: 16,
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// InactiveTileChip: 12 dp corners, surfaceContainerHigh with a 1 dp
/// outline@0.2; 12×8 dp inside: a 16 dp primary "+", the action's icon
/// (18 dp) and its name (labelMedium), onSurfaceVariant.
class _InactiveChip extends StatelessWidget {
  const _InactiveChip({
    required this.scheme,
    required this.action,
    required this.onTap,
  });

  final ColorScheme scheme;
  final _MenuAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = action.label(context.l10n);
    final content = scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: label,
      child: _Pressable(
        onTap: onTap,
        builder: (context, pressed) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _pressedOn(scheme.surfaceContainerHigh, content, pressed),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.add_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 4),
              Icon(action.icon, size: 18, color: content),
              const SizedBox(width: 8),
              Text(label, style: _Type.labelMedium.copyWith(color: content)),
            ],
          ),
        ),
      ),
    );
  }
}

/// RestartChoiceMenu: "Restart" centred (headlineSmall, bold), the targets
/// two to a row 12 dp apart, then Cancel.
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
            style: _Type.headlineSmall.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 24),
          for (var i = 0; i < targets.length; i += 2) ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _TargetTile(
                    scheme: scheme,
                    target: targets[i],
                    onTap: () => onTarget(targets[i]),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: i + 1 < targets.length
                      ? _TargetTile(
                          scheme: scheme,
                          target: targets[i + 1],
                          onTap: () => onTarget(targets[i + 1]),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 16),
          _TextButton(
            label: l10n.actionCancel,
            color: scheme.primary,
            onTap: onCancel,
          ),
        ],
      ),
    );
  }
}

/// RestartOptionTile: 100 dp, 24 dp corners, `surfaceVariant`; the icon
/// (32 dp, primary) over the label (titleMedium, medium), 8 dp apart.
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
      builder: (context, pressed) => Container(
        height: 100,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _pressedOn(
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
            pressed,
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              restartTargetIcon(target.icon),
              size: 32,
              color: scheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              target.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: _Type.titleMedium.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Material 3's TextButton: 40 dp, labelLarge.
class _TextButton extends StatelessWidget {
  const _TextButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: _Pressable(
      onTap: onTap,
      builder: (context, pressed) => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: pressed ? 0.1 : 0),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Align(
          widthFactor: 1,
          child: Text(label, style: _Type.labelLarge.copyWith(color: color)),
        ),
      ),
    ),
  );
}

/// ConfirmationSliderView: no card, on the dimmed screen. 320 dp with 16 dp
/// around, items 24 dp apart: the action's name (headlineMedium, bold,
/// white), the slide track, Cancel.
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
    const white = Color(0xffffffff);
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: math.min(320.0, MediaQuery.sizeOf(context).width),
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 32),
            const SizedBox(height: 24),
            Text(
              pending.title,
              style: _Type.headlineMedium.copyWith(
                color: white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 24),
            _SlideToConfirm(
              scheme: scheme,
              icon: pending.icon,
              label: running ? l10n.powerMenuWorking : pending.slideLabel,
              locked: running,
              onConfirmed: onConfirmed,
            ),
            if (error != null && !running) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.error, fontSize: 14),
              ),
            ],
            const SizedBox(height: 24),
            Opacity(
              opacity: running ? 0 : 1,
              child: IgnorePointer(
                ignoring: running,
                child: _TextButton(
                  label: l10n.actionCancel,
                  color: white,
                  onTap: onCancel,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// EvolutionX's slide: a 72 dp track (36 dp corners, `surfaceVariant` at
/// 0.85, a 1 dp onSurface@0.14 border, 10 dp inside) with the hint centred
/// (bodyLarge medium, onSurfaceVariant at half alpha, fading as the thumb
/// moves) and the thumb (`error`, the action's icon in onError, 32 dp).
/// Past 75 % of the travel a release confirms; short of it the thumb jumps
/// back. Crossing 75 % either way ticks.
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

class _SlideToConfirmState extends State<_SlideToConfirm> {
  static const double _height = 72;
  static const double _inset = 10;

  /// 56 dp in the code, held to the track's 52 dp inside.
  static const double _thumb = _height - _inset * 2;
  static const double _threshold = 0.75;

  double _offset = 0;
  double _max = 1;
  bool _past = false;
  bool _done = false;

  @override
  void didUpdateWidget(_SlideToConfirm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A failed request unlocks the slide again: the thumb goes back.
    if (oldWidget.locked && !widget.locked && _done) {
      setState(() {
        _done = false;
        _offset = 0;
        _past = false;
      });
    }
  }

  void _drag(DragUpdateDetails details) {
    if (_done || widget.locked) return;
    setState(() {
      _offset = (_offset + details.primaryDelta!).clamp(0.0, _max);
    });
    final past = _offset / _max > _threshold;
    if (past != _past) {
      _past = past;
      unawaited(HapticFeedback.selectionClick());
    }
  }

  void _release(DragEndDetails details) {
    if (_done || widget.locked) return;
    if (_offset / _max > _threshold) {
      _done = true;
      widget.onConfirmed();
    } else {
      setState(() => _offset = 0);
    }
    _past = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    return Semantics(
      button: true,
      label: widget.label,
      onTap: widget.locked ? null : widget.onConfirmed,
      child: Container(
        height: _height,
        padding: const EdgeInsets.all(_inset - 1),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.85),
          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.14)),
          borderRadius: BorderRadius.circular(_height / 2),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _max = math.max(1, constraints.maxWidth - _thumb);
            final hint = (1 - _offset / _max).clamp(0.0, 1.0);
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Center(
                    child: Opacity(
                      opacity: hint,
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: _Type.bodyLarge.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: _offset,
                  top: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onHorizontalDragUpdate: _drag,
                    onHorizontalDragEnd: _release,
                    child: Container(
                      width: _thumb,
                      decoration: BoxDecoration(
                        color: scheme.error,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(widget.icon, color: scheme.onError, size: 32),
                    ),
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
