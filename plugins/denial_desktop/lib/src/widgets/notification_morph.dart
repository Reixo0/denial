import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'notification_pull_expand.dart';

/// How one part of a notification goes from one layout to the other
/// (AOSP's TransformState and its kinds).
enum MorphKind {
  /// The same in both (by [MorphPart.same]), it moves; otherwise the two
  /// cross-fade as they move. In one layout only, it fades in place.
  normal,

  /// Taken as the same in both, whatever it shows (addViewTransformingToSimilar).
  similar,

  /// A picture that grows out of a one-line row of a group
  /// (ImageTransformState with HybridNotificationView).
  picture,

  /// Stays where its own layout has it; the same in both.
  still,
}

/// A part of a notification that [NotificationMorph] moves and fades on its
/// own. Both layouts must wrap everything they draw in parts.
class MorphPart extends SingleChildRenderObjectWidget {
  const MorphPart({
    required this.id,
    required Widget super.child,
    this.same,
    this.kind = MorphKind.normal,
    this.linear = false,
    this.group,
    super.key,
  });

  /// The same part has the same id in both layouts.
  final Object id;

  /// What it shows: equal (and, for text, cut at the same place over as many
  /// lines) in both layouts, it is one thing that moves. Null is never equal.
  final Object? same;
  final MorphKind kind;

  /// Follows the finger linearly (MessagingLayoutTransformState).
  final bool linear;

  /// A message of the one layout that shows more than [lastMessage], by its
  /// sender's group (MessagingLayoutTransformState's groups without a pair).
  final int? group;

  /// The id of the message both layouts show.
  static const Object lastMessage = 'message0';

  @override
  RenderMorphPart createRenderObject(BuildContext context) => RenderMorphPart(
    id: id,
    same: same,
    kind: kind,
    linear: linear,
    group: group,
  );

  @override
  void updateRenderObject(BuildContext context, RenderMorphPart renderObject) {
    renderObject
      ..id = id
      ..same = same
      ..kind = kind
      ..linear = linear
      ..group = group;
  }
}

class RenderMorphPart extends RenderProxyBox {
  RenderMorphPart({
    required this.id,
    required this.same,
    required this.kind,
    required this.linear,
    required this.group,
  });

  Object id;
  Object? same;
  MorphKind kind;
  bool linear;
  int? group;

  Offset _shift = Offset.zero;
  double _scale = 1;
  double _alpha = 1;
  bool _moving = false;

  final _opacity = LayerHandle<OpacityLayer>();
  final _transform = LayerHandle<TransformLayer>();

  set _morphing(bool value) {
    if (value == _moving) return;
    _moving = value;
    if (!value) {
      _shift = Offset.zero;
      _scale = 1;
      _alpha = 1;
    }
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _moving && child != null;

  @override
  void dispose() {
    _opacity.layer = null;
    _transform.layer = null;
    super.dispose();
  }

  /// What of a text shows: how far it is cut and over how many lines.
  (bool, int)? get _textShape {
    (bool, int)? shape;
    void visit(RenderObject object) {
      if (shape != null) return;
      if (object is RenderParagraph) {
        shape = (object.didExceedMaxLines, object.size.height.round());
        return;
      }
      object.visitChildren(visit);
    }

    visitChildren(visit);
    return shape;
  }

  bool _sameAs(RenderMorphPart other) {
    if (kind == MorphKind.similar || kind == MorphKind.still) return true;
    return same != null && same == other.same && _textShape == other._textShape;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_moving) {
      _opacity.layer = null;
      _transform.layer = null;
      context.paintChild(child, offset);
      return;
    }
    final alpha = (_alpha * 255).round();
    if (alpha <= 0) {
      _opacity.layer = null;
      _transform.layer = null;
      return;
    }
    void scaled(PaintingContext context, Offset offset) {
      if (_scale == 1) {
        _transform.layer = null;
        context.paintChild(child, offset);
        return;
      }
      // About its top centre.
      final x = offset.dx + size.width / 2;
      final matrix = Matrix4.translationValues(x, offset.dy, 0)
        ..scaleByDouble(_scale, _scale, 1, 1)
        ..translateByDouble(-x, -offset.dy, 0, 1);
      _transform.layer = context.pushTransform(
        needsCompositing,
        Offset.zero,
        matrix,
        (context, _) => context.paintChild(child, offset),
        oldLayer: _transform.layer,
      );
    }

    if (alpha >= 255) {
      _opacity.layer = null;
      scaled(context, offset + _shift);
    } else {
      _opacity.layer = context.pushOpacity(
        offset + _shift,
        alpha,
        scaled,
        oldLayer: _opacity.layer,
      );
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_moving) transform.translateByDouble(_shift.dx, _shift.dy, 0, 1);
  }
}

enum MorphSlot { collapsed, expanded }

/// A notification's two layouts, one turning into the other as AOSP's
/// NotificationContentView does (ViewTransformationHelper): what both show
/// moves from its place in one to its place in the other, the rest fades,
/// and the height follows [motion]. At rest only one of the two is given.
///
/// Without a [motion] the parent drives it ([RenderNotificationMorph.drive]).
class NotificationMorph
    extends SlottedMultiChildRenderObjectWidget<MorphSlot, RenderBox> {
  const NotificationMorph({
    this.motion,
    this.collapsed,
    this.expanded,
    this.fromLine = false,
    super.key,
  });

  final NotificationExpandMotion? motion;
  final Widget? collapsed;
  final Widget? expanded;

  /// [collapsed] is a one-line row of a folded group (HybridNotificationView).
  final bool fromLine;

  @override
  Iterable<MorphSlot> get slots => MorphSlot.values;

  @override
  Widget? childForSlot(MorphSlot slot) => switch (slot) {
    MorphSlot.collapsed => collapsed,
    MorphSlot.expanded => expanded,
  };

  @override
  RenderNotificationMorph createRenderObject(BuildContext context) =>
      RenderNotificationMorph(motion, fromLine: fromLine);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderNotificationMorph renderObject,
  ) {
    renderObject
      ..motion = motion
      ..fromLine = fromLine;
  }
}

class RenderNotificationMorph extends RenderBox
    with SlottedContainerRenderObjectMixin<MorphSlot, RenderBox> {
  RenderNotificationMorph(this._motion, {required this._fromLine});

  NotificationExpandMotion? _motion;
  set motion(NotificationExpandMotion? value) {
    if (identical(value, _motion)) return;
    if (attached) _motion?.removeListener(markNeedsLayout);
    _motion = value;
    if (attached) _motion?.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  bool _fromLine;
  set fromLine(bool value) {
    if (value == _fromLine) return;
    _fromLine = value;
    markNeedsPaint();
  }

  RenderBox? get _collapsed => childForSlot(MorphSlot.collapsed);
  RenderBox? get _expanded => childForSlot(MorphSlot.expanded);

  /// Both layouts are up, one turning into the other.
  bool get morphing => _collapsed != null && _expanded != null;

  /// The two layouts' heights, after layout.
  double get collapsedHeight => _collapsed?.size.height ?? 0;
  double get expandedHeight => _expanded?.size.height ?? 0;

  double _amount = 1;
  bool _toExpanded = true;
  bool _byHand = false;
  double _extent = 0;

  /// The parent's: how far ([amount]) it has turned into the expanded layout
  /// ([toExpanded]) or back, and how much of its height shows.
  void drive({
    required double amount,
    required bool toExpanded,
    required bool byHand,
    required double extent,
  }) {
    _amount = amount;
    _toExpanded = toExpanded;
    _byHand = byHand;
    _extent = extent;
    if (morphing) _place();
  }

  final _clip = LayerHandle<ClipRectLayer>();
  List<RenderMorphPart> _moved = const <RenderMorphPart>[];
  Map<Object, RenderMorphPart> _from = const <Object, RenderMorphPart>{};
  Map<Object, RenderMorphPart> _into = const <Object, RenderMorphPart>{};

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion?.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _motion?.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  Map<Object, RenderMorphPart> _partsOf(RenderBox? layout) {
    final parts = <Object, RenderMorphPart>{};
    void visit(RenderObject object) {
      if (object is RenderMorphPart) {
        parts[object.id] = object;
      } else {
        object.visitChildren(visit);
      }
    }

    if (layout != null) visit(layout);
    return parts;
  }

  void _gather() {
    _from = _partsOf(_collapsed);
    _into = _partsOf(_expanded);
    final moved = morphing
        ? <RenderMorphPart>[..._from.values, ..._into.values]
        : const <RenderMorphPart>[];
    for (final part in _moved) {
      if (part.attached && !moved.contains(part)) part._morphing = false;
    }
    for (final part in moved) {
      part._morphing = true;
    }
    _moved = moved;
  }

  @override
  void performLayout() {
    final loose = BoxConstraints(
      minWidth: constraints.minWidth,
      maxWidth: constraints.maxWidth,
    );
    _collapsed?.layout(loose, parentUsesSize: true);
    _expanded?.layout(loose, parentUsesSize: true);
    _gather();
    final resting = _collapsed ?? _expanded;
    if (resting == null) {
      size = constraints.smallest;
      return;
    }
    if (!morphing) {
      size = constraints.constrain(resting.size);
      _extent = size.height;
      return;
    }
    final width = math.max(resting.size.width, _expanded!.size.width);
    final motion = _motion;
    if (motion == null) {
      size = constraints.constrain(
        Size(width, math.max(collapsedHeight, expandedHeight)),
      );
      return;
    }
    motion.range = math.max(0, expandedHeight - collapsedHeight);
    _amount = motion.amount;
    _toExpanded = motion.toExpanded;
    _byHand = motion.byHand;
    size = constraints.constrain(Size(width, collapsedHeight + motion.grown));
    _extent = size.height;
    _place();
  }

  /// CrossFadeHelper: the fades take 210 of the 360 ms.
  static double _fadeIn(double amount) =>
      const Cubic(0.4, 0, 1, 1).transform(math.min(1, amount * 360 / 210));
  static double _fadeOut(double amount) =>
      const Cubic(0, 0, 0.8, 1).transform(1 - math.min(1, amount * 360 / 210));

  /// ImageTransformState.mapToDuration.
  static double _lateAmount(double amount) =>
      ((amount * 360 - 150) / 210).clamp(0.0, 1.0);

  Offset _placeOf(RenderMorphPart part) =>
      MatrixUtils.transformPoint(part.getTransformTo(this), Offset.zero);

  /// Sets where each part is drawn and how strongly, after layout. A part
  /// whose look changed repaints itself: parts can sit under a repaint
  /// boundary of their own (a row's launch snapshot), which this one's paint
  /// would not reach.
  void _place() {
    final before = <RenderMorphPart, (Offset, double, double)>{
      for (final part in _moved) part: (part._shift, part._scale, part._alpha),
    };
    _arrange();
    for (final part in _moved) {
      if (before[part] != (part._shift, part._scale, part._alpha)) {
        part.markNeedsPaint();
      }
    }
  }

  void _arrange() {
    final shown = _toExpanded ? _into : _from;
    final hidden = _toExpanded ? _from : _into;
    final amount = _amount.clamp(0.0, 1.0);
    final eased = Curves.fastOutSlowIn.transform(amount);
    for (final part in _moved) {
      part
        .._shift = Offset.zero
        .._scale = 1
        .._alpha = 1;
    }
    for (final MapEntry(key: id, value: part) in shown.entries) {
      if (_fromLine && _lineText(id, part, hidden, amount, eased, true)) {
        continue;
      }
      final other = hidden[id];
      if (other == null) {
        if (part.group == null) _appear(part, amount);
        continue;
      }
      final move = part.linear && _byHand ? amount : eased;
      final way = part.kind == MorphKind.still
          ? Offset.zero
          : _placeOf(other) - _placeOf(part);
      part._shift = way * (1 - move);
      if (part._sameAs(other)) {
        other._alpha = 0;
      } else {
        part._alpha = _fadeIn(amount);
        other
          .._alpha = _fadeOut(amount)
          .._shift = -way * move;
      }
    }
    for (final MapEntry(key: id, value: part) in hidden.entries) {
      if (_fromLine && _lineText(id, part, shown, amount, eased, false)) {
        continue;
      }
      if (shown.containsKey(id) || part.group != null) continue;
      _disappear(part, amount);
    }
    _trail(shown, hidden, shown: true);
    _trail(hidden, shown, shown: false);
  }

  /// The groups of messages only one layout has: each comes after the last
  /// message, which both have, and fades as it passes the messages' top.
  void _trail(
    Map<Object, RenderMorphPart> own,
    Map<Object, RenderMorphPart> others, {
    required bool shown,
  }) {
    final lead = own[MorphPart.lastMessage];
    final other = others[MorphPart.lastMessage];
    if (lead == null || other == null) return;
    final groups = <int, (double, double)>{};
    for (final part in own.values) {
      final group = part.group;
      if (group == null) continue;
      final top = _placeOf(part).dy;
      final bottom = top + part.size.height;
      final had = groups[group];
      groups[group] = had == null
          ? (top, bottom)
          : (math.min(had.$1, top), math.max(had.$2, bottom));
    }
    if (groups.isEmpty) return;
    final start = groups.values.map((group) => group.$1).reduce(math.min);
    // Where the last message is drawn, in this layout or the other.
    final drawn = shown
        ? lead._shift.dy
        : _placeOf(other).dy + other._shift.dy - _placeOf(lead).dy;
    for (final part in own.values) {
      final group = part.group;
      if (group == null) continue;
      final (top, bottom) = groups[group]!;
      final height = bottom - top;
      final at = top - start + drawn;
      final fade = _byHand
          ? (at + height * 0.5) / (height * 0.5)
          : (at + height * 0.75) / (height * 0.75 + top - start);
      final amount = fade.clamp(0.0, 1.0);
      part
        .._shift = Offset(0, drawn * 0.9)
        .._alpha = shown ? _fadeIn(amount) : _fadeOut(1 - amount);
    }
  }

  void _appear(RenderMorphPart part, double amount) {
    if (_fromLine && part.kind == MorphKind.picture) {
      final late = _lateAmount(amount);
      part
        .._alpha = const Cubic(0.4, 0, 1, 1).transform(late)
        .._scale = math.max(0.001, const Cubic(0, 0, 0.2, 1).transform(late));
      return;
    }
    part._alpha = _fadeIn(amount);
  }

  void _disappear(RenderMorphPart part, double amount) {
    if (_fromLine && part.kind == MorphKind.picture) {
      final late = _lateAmount(1 - amount);
      part
        .._alpha = const Cubic(0, 0, 0.8, 1).transform(late)
        .._scale = math.max(0.001, const Cubic(0, 0, 0.2, 1).transform(late));
      return;
    }
    part._alpha = _fadeOut(amount);
  }

  /// A one-line row's text leaves towards the title (HybridNotificationView's
  /// FadeOutAndDownWithTitleTransformation) and the row's own comes from a
  /// third of the way under it (NotificationTemplateViewWrapper).
  bool _lineText(
    Object id,
    RenderMorphPart part,
    Map<Object, RenderMorphPart> others,
    double amount,
    double eased,
    bool shown,
  ) {
    if (id != 'text') return false;
    final title = others['title'];
    part._alpha = shown ? _fadeIn(amount) : _fadeOut(amount);
    if (title == null) return true;
    final inLine = identical(_from['text'], part);
    final own = _placeOf(part).dy;
    final theirs = _placeOf(title).dy;
    final way = inLine
        ? theirs - own
        : (theirs + title.size.height - own) * 0.33;
    part._shift = Offset(0, way * (shown ? 1 - eased : eased));
    return true;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!morphing) {
      _clip.layer = null;
      final resting = _collapsed ?? _expanded;
      if (resting != null) context.paintChild(resting, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & Size(size.width, _extent),
      (context, offset) {
        context
          ..paintChild(_toExpanded ? _collapsed! : _expanded!, offset)
          ..paintChild(_toExpanded ? _expanded! : _collapsed!, offset);
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (morphing) return false;
    final resting = _collapsed ?? _expanded;
    return resting != null && resting.hitTest(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final resting = _toExpanded
        ? _expanded ?? _collapsed
        : _collapsed ?? _expanded;
    if (resting != null) visitor(resting);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      (_collapsed ?? _expanded)?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (_collapsed ?? _expanded)?.getMaxIntrinsicHeight(width) ?? 0;
}
