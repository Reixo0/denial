import 'dart:math' as math;

import 'package:flutter/material.dart' show ColorScheme, Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';

import '../../state/qs_tile_layout.dart';
import '../phone_scheme.dart';
import 'quick_settings_tiles.dart';

/// AOSP's TileCategory, in its order, for the editor's available tiles.
enum QsTileCategory { connectivity, utilities, display }

/// One tile this phone can show: how the editor names it, and how the
/// grid builds it, large ([wide]) or as an icon.
class QsTileSpec {
  const QsTileSpec({
    required this.id,
    required this.category,
    required this.icon,
    required this.label,
    required this.build,
  });

  final String id;
  final QsTileCategory category;
  final IconData icon;
  final String label;
  final Widget Function(bool wide) build;
}

/// Material 3's type scale, in the sizes AOSP's edit mode uses.
abstract final class _Type {
  static const headlineMedium = TextStyle(fontSize: 28, height: 36 / 28);
  static const titleMedium = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    letterSpacing: 0.15,
    fontWeight: FontWeight.w600,
  );
  static const titleLarge = TextStyle(fontSize: 22, height: 28 / 22);
  static const bodyMedium = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    letterSpacing: 0.25,
  );
  static const labelLarge = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    letterSpacing: 0.1,
    fontWeight: FontWeight.w500,
  );
  static const labelMedium = TextStyle(
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.5,
    fontWeight: FontWeight.w500,
  );
}

/// AOSP's quick-settings edit mode (qs/panels/ui/compose/infinitegrid,
/// EditTile.kt): a top bar with back and Remove, "Edit tiles", the placed
/// tiles in an outlined grid (tap to select, the side pill resizes, a long
/// press drags to reorder), the tiles by category with "+" badges to add
/// them, and Reset. Laid out in Android's dp.
class QsTileEditor extends ConsumerStatefulWidget {
  const QsTileEditor({required this.catalog, super.key});

  final List<QsTileSpec> catalog;

  @override
  ConsumerState<QsTileEditor> createState() => _QsTileEditorState();
}

class _QsTileEditorState extends ConsumerState<QsTileEditor> {
  final ScrollController _scroll = ScrollController();
  String? _selected;

  /// The scroll offset past which the big title has gone under the bar.
  static const double _titleBlock = 22 + 36 + 20 + 17;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
  }

  bool _collapsed = false;

  void _scrolled() {
    final collapsed = _scroll.offset > _titleBlock - 20;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  QsTileLayoutController get _layout => ref.read(qsTileLayoutProvider.notifier);

  void _stop() => ref.read(qsEditingProvider.notifier).stop();

  /// Removes the selection and selects its neighbour, the next tile first.
  void _removeSelected(List<QsTileSlot> slots) {
    final id = _selected;
    if (id == null) return;
    final index = slots.indexWhere((s) => s.id == id);
    String? next;
    if (index >= 0) {
      if (index + 1 < slots.length) {
        next = slots[index + 1].id;
      } else if (index > 0) {
        next = slots[index - 1].id;
      }
    }
    _layout.remove(id);
    setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = phoneSchemeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final byId = <String, QsTileSpec>{
      for (final spec in widget.catalog) spec.id: spec,
    };
    // Tiles this phone can't show stay saved, but out of the editor.
    final slots = <QsTileSlot>[
      for (final slot in ref.watch(qsTileLayoutProvider))
        if (byId.containsKey(slot.id)) slot,
    ];
    final placed = <String>{for (final slot in slots) slot.id};
    if (_selected != null && !placed.contains(_selected)) _selected = null;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _stop,
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: EdgeInsets.only(
            top: math.max(8.0, padding.top),
            left: PixelQs.margin,
            right: PixelQs.margin,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _TopBar(
                scheme: scheme,
                collapsed: _collapsed,
                canRemove: _selected != null && slots.length > 1,
                onBack: _stop,
                onRemove: () => _removeSelected(slots),
              ),
              Expanded(
                child: ClipRect(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: EdgeInsets.only(bottom: padding.bottom + 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // TwoRowsTopAppBar's expanded row.
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 22, 16, 17),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                l10n.qsEditTiles,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: _Type.headlineMedium.copyWith(
                                  color: scheme.onSurface,
                                ),
                              ),
                              Text(
                                l10n.qsEditSubtitle,
                                style: _Type.bodyMedium.copyWith(
                                  color: scheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _CurrentTilesGrid(
                          scheme: scheme,
                          slots: slots,
                          byId: byId,
                          selected: _selected,
                          onSelect: (id) => setState(() => _selected = id),
                        ),
                        const SizedBox(height: 12),
                        _AvailableTiles(
                          scheme: scheme,
                          catalog: widget.catalog,
                          placed: placed,
                          onAdd: (id) {
                            _layout.add(id);
                            setState(() => _selected = id);
                          },
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: _Pill(
                            label: l10n.qsEditReset,
                            container: scheme.primary,
                            content: scheme.onPrimary,
                            height: 40,
                            horizontal: 12,
                            onTap: () {
                              _layout.reset();
                              setState(() => _selected = null);
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// EditModeExpandableTopBar's pinned row (8 dp above and below, 64 dp):
/// the back arrow, the title once the big one has scrolled away, Remove.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.scheme,
    required this.collapsed,
    required this.canRemove,
    required this.onBack,
    required this.onRemove,
  });

  final ColorScheme scheme;
  final bool collapsed;
  final bool canRemove;
  final VoidCallback onBack;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 64,
        child: Row(
          children: <Widget>[
            const SizedBox(width: 4),
            Semantics(
              button: true,
              label: l10n.qsEditBack,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onBack,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(
                    Icons.arrow_back_rounded,
                    size: 24,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
            Expanded(
              child: AnimatedOpacity(
                opacity: collapsed ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    l10n.qsEditTiles,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _Type.titleLarge.copyWith(color: scheme.onSurface),
                  ),
                ),
              ),
            ),
            // RemoveButton: primary when a tile is selected, else
            // onSurface at 0.1 with onSurface@0.38 text; 10 dp inside.
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: canRemove ? 1 : 0),
              duration: const Duration(milliseconds: 300),
              builder: (context, t, _) => _Pill(
                label: l10n.qsEditRemove,
                container: Color.lerp(
                  scheme.onSurface.withValues(alpha: 0.1),
                  scheme.primary,
                  t,
                )!,
                content: Color.lerp(
                  scheme.onSurface.withValues(alpha: 0.38),
                  scheme.onPrimary,
                  t,
                )!,
                horizontal: 10,
                vertical: 10,
                onTap: canRemove ? onRemove : null,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// A rounded button with a label: Remove, Reset.
class _Pill extends StatefulWidget {
  const _Pill({
    required this.label,
    required this.container,
    required this.content,
    required this.onTap,
    this.horizontal = 12,
    this.vertical = 0,
    this.height,
  });

  final String label;
  final Color container;
  final Color content;
  final VoidCallback? onTap;
  final double horizontal;
  final double vertical;
  final double? height;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _pressed = false;

  void _set(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = _pressed && enabled
        ? Color.alphaBlend(
            widget.content.withValues(alpha: 0.1),
            widget.container,
          )
        : widget.container;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap,
        child: Container(
          height: widget.height,
          alignment: widget.height == null ? null : Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: widget.horizontal,
            vertical: widget.vertical,
          ),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            widget.label,
            style: _Type.labelLarge.copyWith(color: widget.content),
          ),
        ),
      ),
    );
  }
}

/// CurrentTilesGrid: 2 dp primary outline over primary@0.15, 28 dp
/// corners, 10 dp inside; the tiles as in the shade, four columns.
class _CurrentTilesGrid extends ConsumerStatefulWidget {
  const _CurrentTilesGrid({
    required this.scheme,
    required this.slots,
    required this.byId,
    required this.selected,
    required this.onSelect,
  });

  static const double padding = 10;
  static const double radius = 28;

  final ColorScheme scheme;
  final List<QsTileSlot> slots;
  final Map<String, QsTileSpec> byId;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  ConsumerState<_CurrentTilesGrid> createState() => _CurrentTilesGridState();
}

class _CurrentTilesGridState extends ConsumerState<_CurrentTilesGrid> {
  final GlobalKey _gridKey = GlobalKey();

  /// The tile being dragged to a new place, and where the finger holds it.
  String? _dragging;
  Offset _grab = Offset.zero;
  Offset _finger = Offset.zero;

  /// Each tile's rectangle: a large tile takes two columns, and goes to the
  /// next row when one column is left (the shade's grid does the same).
  static List<Rect> place(List<QsTileSlot> slots, double width) {
    const gap = PixelQs.gap;
    final column = (width - gap * (PixelQs.columns - 1)) / PixelQs.columns;
    final rects = <Rect>[];
    var x = 0;
    var y = 0;
    for (final slot in slots) {
      final span = slot.wide ? 2 : 1;
      if (x + span > PixelQs.columns) {
        x = 0;
        y++;
      }
      rects.add(
        Rect.fromLTWH(
          x * (column + gap),
          y * (PixelQs.tileHeight + gap),
          span * column + (span - 1) * gap,
          PixelQs.tileHeight,
        ),
      );
      x += span;
      if (x >= PixelQs.columns) {
        x = 0;
        y++;
      }
    }
    return rects;
  }

  Offset _local(Offset global) {
    final box = _gridKey.currentContext?.findRenderObject();
    return box is RenderBox ? box.globalToLocal(global) : global;
  }

  void _dragStart(String id, Rect rect, LongPressStartDetails details) {
    HapticFeedback.heavyImpact();
    widget.onSelect(id);
    final local = _local(details.globalPosition);
    setState(() {
      _dragging = id;
      _grab = local - rect.topLeft;
      _finger = local;
    });
  }

  void _dragMove(List<Rect> rects, LongPressMoveUpdateDetails details) {
    final id = _dragging;
    if (id == null) return;
    final local = _local(details.globalPosition);
    setState(() => _finger = local);
    // Over another tile: take its place.
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].contains(local) && widget.slots[i].id != id) {
        HapticFeedback.selectionClick();
        ref.read(qsTileLayoutProvider.notifier).move(id, widget.slots[i].id);
        return;
      }
    }
  }

  void _dragEnd() => setState(() => _dragging = null);

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    const inset = _CurrentTilesGrid.padding;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.15),
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(_CurrentTilesGrid.radius),
      ),
      padding: const EdgeInsets.all(inset - 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final rects = place(widget.slots, width);
          final height = rects.isEmpty
              ? PixelQs.tileHeight
              : rects.map((r) => r.bottom).reduce(math.max);
          final dragging = _dragging;
          final dragIndex = dragging == null
              ? -1
              : widget.slots.indexWhere((s) => s.id == dragging);
          return GestureDetector(
            // A tap between tiles drops the selection.
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelect(null),
            child: AnimatedContainer(
              key: _gridKey,
              duration: const Duration(milliseconds: 250),
              curve: Curves.fastOutSlowIn,
              height: height,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  for (var i = 0; i < widget.slots.length; i++)
                    AnimatedPositioned(
                      key: ValueKey<String>(widget.slots[i].id),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      left: rects[i].left,
                      top: rects[i].top,
                      width: rects[i].width,
                      height: rects[i].height,
                      child: _EditTile(
                        scheme: scheme,
                        spec: widget.byId[widget.slots[i].id]!,
                        wide: widget.slots[i].wide,
                        placeholder: i == dragIndex,
                        selected: widget.slots[i].id == widget.selected,
                        resizeStep: (width - 3 * PixelQs.gap) / 4,
                        onTap: () => widget.onSelect(
                          widget.slots[i].id == widget.selected
                              ? null
                              : widget.slots[i].id,
                        ),
                        onResize: (wide) => ref
                            .read(qsTileLayoutProvider.notifier)
                            .setWide(widget.slots[i].id, wide),
                        onDragStart: (details) =>
                            _dragStart(widget.slots[i].id, rects[i], details),
                        onDragMove: (details) => _dragMove(rects, details),
                        onDragEnd: _dragEnd,
                      ),
                    ),
                  if (dragIndex >= 0)
                    Positioned(
                      left: _finger.dx - _grab.dx,
                      top: _finger.dy - _grab.dy,
                      width: rects[dragIndex].width,
                      height: rects[dragIndex].height,
                      child: IgnorePointer(
                        child: _TileFace(
                          spec: widget.byId[dragging]!,
                          wide: widget.slots[dragIndex].wide,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The tile as the shade draws it, off (editTileColors: surfaceEffect1,
/// onSurface), without its state line.
class _TileFace extends StatelessWidget {
  const _TileFace({required this.spec, required this.wide});

  final QsTileSpec spec;
  final bool wide;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: QuickTile(
        icon: spec.icon,
        title: spec.label,
        active: false,
        wide: wide,
        onTap: () {},
      ),
    ),
  );
}

/// TileGridCell in edit mode. Selected: a 2 dp primary border inside and
/// the resizing pill (8×16 dp, primary) on the end edge, which toggles
/// the size when tapped or dragged half a column.
class _EditTile extends StatefulWidget {
  const _EditTile({
    required this.scheme,
    required this.spec,
    required this.wide,
    required this.placeholder,
    required this.selected,
    required this.resizeStep,
    required this.onTap,
    required this.onResize,
    required this.onDragStart,
    required this.onDragMove,
    required this.onDragEnd,
  });

  final ColorScheme scheme;
  final QsTileSpec spec;
  final bool wide;

  /// Being dragged: drawn as its empty place (PLACEHOLDER_ALPHA). The
  /// gesture detector stays in the tree so the long press keeps tracking.
  final bool placeholder;
  final bool selected;

  /// A column's width: dragging the pill half of it changes the size.
  final double resizeStep;
  final VoidCallback onTap;
  final ValueChanged<bool> onResize;
  final ValueChanged<LongPressStartDetails> onDragStart;
  final ValueChanged<LongPressMoveUpdateDetails> onDragMove;
  final VoidCallback onDragEnd;

  @override
  State<_EditTile> createState() => _EditTileState();
}

class _EditTileState extends State<_EditTile> {
  double _dx = 0;

  void _resizeUpdate(DragUpdateDetails details) {
    _dx += details.delta.dx;
    final half = widget.resizeStep / 2;
    if (!widget.wide && _dx > half) {
      _dx = 0;
      HapticFeedback.selectionClick();
      widget.onResize(true);
    } else if (widget.wide && _dx < -half) {
      _dx = 0;
      HapticFeedback.selectionClick();
      widget.onResize(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final l10n = context.l10n;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: Semantics(
            button: true,
            selected: widget.selected,
            label: widget.spec.label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              onLongPressStart: widget.onDragStart,
              onLongPressMoveUpdate: widget.onDragMove,
              onLongPressEnd: (_) => widget.onDragEnd(),
              onLongPressCancel: widget.onDragEnd,
              child: widget.placeholder
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.secondary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(
                          PixelQs.tileHeight / 2,
                        ),
                      ),
                    )
                  : _TileFace(spec: widget.spec, wide: widget.wide),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: widget.selected && !widget.placeholder ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(PixelQs.tileHeight / 2),
                ),
              ),
            ),
          ),
        ),
        // The pill's centre sits on the end edge, 2 dp in; a 48 dp target.
        if (widget.selected && !widget.placeholder)
          Positioned(
            right: -24 + 2,
            top: 0,
            bottom: 0,
            child: Semantics(
              button: true,
              label: l10n.qsEditResizeTile,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onResize(!widget.wide);
                },
                onHorizontalDragStart: (_) => _dx = 0,
                onHorizontalDragUpdate: _resizeUpdate,
                child: SizedBox(
                  width: 48,
                  child: Center(
                    child: Container(
                      width: 8,
                      height: 16,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// AvailableTileGrid: one block per category (surface@0.32, 2 dp apart,
/// 28 dp outer corners, 16 dp inside), a header with the category's icon,
/// then the tiles four to a row: an icon tile with a "+" badge and the
/// name under it. Tiles already placed are faded to 0.38, without badge.
class _AvailableTiles extends StatelessWidget {
  const _AvailableTiles({
    required this.scheme,
    required this.catalog,
    required this.placed,
    required this.onAdd,
  });

  final ColorScheme scheme;
  final List<QsTileSpec> catalog;
  final Set<String> placed;
  final ValueChanged<String> onAdd;

  static IconData _icon(QsTileCategory category) => switch (category) {
    QsTileCategory.connectivity => Icons.wifi_rounded,
    QsTileCategory.utilities => Icons.settings_rounded,
    QsTileCategory.display => Icons.brightness_medium_rounded,
  };

  static String _label(QsTileCategory category, AppLocalizations l10n) =>
      switch (category) {
        QsTileCategory.connectivity => l10n.qsCategoryConnectivity,
        QsTileCategory.utilities => l10n.qsCategoryUtilities,
        QsTileCategory.display => l10n.qsCategoryDisplay,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final groups = <QsTileCategory, List<QsTileSpec>>{
      for (final category in QsTileCategory.values)
        category: <QsTileSpec>[
          for (final spec in catalog)
            if (spec.category == category) spec,
        ]..sort((a, b) => a.label.compareTo(b.label)),
    }..removeWhere((_, specs) => specs.isEmpty);
    final entries = groups.entries.toList();
    const corner = Radius.circular(_CurrentTilesGrid.radius);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < entries.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.32),
              borderRadius: BorderRadius.only(
                topLeft: i == 0 ? corner : Radius.zero,
                topRight: i == 0 ? corner : Radius.zero,
                bottomLeft: i == entries.length - 1 ? corner : Radius.zero,
                bottomRight: i == entries.length - 1 ? corner : Radius.zero,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // CategoryHeader, 16 dp under it plus the 16 dp spacing.
                Row(
                  children: <Widget>[
                    Icon(
                      _icon(entries[i].key),
                      size: 24,
                      color: scheme.onSurface,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _label(entries[i].key, l10n),
                        style: _Type.titleMedium.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                for (
                  var start = 0;
                  start < entries[i].value.length;
                  start += PixelQs.columns
                ) ...<Widget>[
                  if (start > 0) const SizedBox(height: 16),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (var c = 0; c < PixelQs.columns; c++) ...<Widget>[
                          if (c > 0) const SizedBox(width: PixelQs.gap),
                          Expanded(
                            child: start + c < entries[i].value.length
                                ? _AvailableTile(
                                    scheme: scheme,
                                    spec: entries[i].value[start + c],
                                    placed: placed.contains(
                                      entries[i].value[start + c].id,
                                    ),
                                    onAdd: onAdd,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// AvailableTileGridCell: the icon tile (72 dp), the "+" badge (24 dp
/// primary circle, 16 dp onPrimary icon) on the tile's rounded corner at
/// -0.8 rad, moved 4 dp in and down; the name (labelMedium, two lines).
class _AvailableTile extends StatelessWidget {
  const _AvailableTile({
    required this.scheme,
    required this.spec,
    required this.placed,
    required this.onAdd,
  });

  final ColorScheme scheme;
  final QsTileSpec spec;
  final bool placed;
  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnimatedOpacity(
      opacity: placed ? 0.38 : 1,
      duration: const Duration(milliseconds: 200),
      child: Semantics(
        button: !placed,
        label: placed ? spec.label : '${l10n.qsEditAddTile}: ${spec.label}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: placed
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onAdd(spec.id);
                },
          child: Column(
            children: <Widget>[
              SizedBox(
                height: PixelQs.tileHeight,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const r = PixelQs.tileHeight / 2;
                    final center = Offset(constraints.maxWidth - r, r);
                    final badge =
                        center +
                        Offset(math.cos(-0.8) * r, math.sin(-0.8) * r) +
                        const Offset(-4, 4);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: scheme.surfaceEffect1,
                              borderRadius: BorderRadius.circular(r),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              spec.icon,
                              size: phoneIconSize,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        Positioned(
                          left: badge.dx - 12,
                          top: badge.dy - 12,
                          child: AnimatedOpacity(
                            opacity: placed ? 0 : 1,
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.add_rounded,
                                size: 16,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                spec.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: _Type.labelMedium.copyWith(color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
