import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/rendering.dart';

// Launcher3 Quickstep's overview_page_spacing. Its overview_max_scale is 0.7;
// Denial's recents previews are 10% smaller, leaving room for their labels.
const double overviewMaxScale = 0.63;
const double overviewPageSpacing = 16.0;
const double _singlePreviewWidthFraction = 0.66;
const double _singlePreviewMaxWidth = 840.0;

/// Logical pixels per Android dp on this screen (the phone's 1216 px at
/// 468 dpi is 415.7 dp wide).
double overviewDpFor(Size size) {
  final side = size.shortestSide;
  if (!side.isFinite || side <= 0) return 1;
  return math.max(1.0, side / (1216 * 160 / 468));
}

/// Launcher3's overview_page_spacing, 16 dp, in logical pixels.
double overviewPageSpacingFor(Size size) => 16 * overviewDpFor(size);

/// The centred recents card, as Launcher3 sizes a phone's task
/// (BaseContainerInterface.calculateTaskSize): the screen less the status
/// bar (27.7 dp on this phone, as EvolutionX draws it) and the gesture bar
/// (24 dp), less the overview actions below (24 dp margin, 48 dp row, the
/// gesture bar again), and 50 + 16 dp each side for the neighbours; the
/// screen's shape scaled to fit, at most 0.7, centred. Landscape keeps
/// Denial's own card.
Rect overviewCardRectFor(Size size, EdgeInsets padding) {
  if (size.width > size.height || size.isEmpty) {
    return centerPreviewRectFor(
      size,
      cardSizeFor(
        constraints: BoxConstraints.tight(size),
        padding: padding,
        aspect: viewAspectFor(size),
      ),
    );
  }
  final dp = overviewDpFor(size);
  final available = Rect.fromLTRB(
    66 * dp,
    27.7 * dp,
    size.width - 66 * dp,
    size.height - 24 * dp - (24 + 48 + 24) * dp,
  );
  final scale = math.min(
    overviewAndroidMaxScale,
    math.min(available.width / size.width, available.height / size.height),
  );
  return Rect.fromCenter(
    center: available.center,
    width: size.width * scale,
    height: size.height * scale,
  );
}

/// Launcher3's overview_max_scale.
const double overviewAndroidMaxScale = 0.7;

/// Where the overview actions row sits below [card]: 24 dp under it, 48 dp
/// tall (overview_actions_top_margin, overview_actions_height).
Rect overviewActionsRectFor(Size size, Rect card) {
  final dp = overviewDpFor(size);
  return Rect.fromLTWH(0, card.bottom + 24 * dp, size.width, 48 * dp);
}

/// The equal-sized slots used by the landscape recents overview.
///
/// [itemRects] and [previewRectAt] share the exact live-texture bounds used by
/// the foreground hero.
class LandscapeOverviewLayout {
  const LandscapeOverviewLayout({
    required this.cardSize,
    required this.itemRects,
    required this.columns,
    required this.rows,
  });

  final Size cardSize;
  final List<Rect> itemRects;
  final int columns;
  final int rows;

  Rect previewRectAt(int index) {
    final itemRect = itemRects[index];
    return Rect.fromLTWH(
      itemRect.left,
      itemRect.top,
      cardSize.width,
      cardSize.height,
    );
  }
}

double viewAspectFor(Size size) {
  if (size.width <= 0.0 || size.height <= 0.0) {
    return kPreviewAspect;
  }
  return (size.width / size.height)
      .clamp(kMinPreviewAspect, kMaxPreviewAspect)
      .toDouble();
}

/// Computes the preview card size that fits the carousel within [constraints].
Size cardSizeFor({
  required BoxConstraints constraints,
  required EdgeInsets padding,
  required double aspect,
}) {
  final availableWidth = math.max(
    0.0,
    constraints.maxWidth - padding.horizontal,
  );
  final availableHeight = math.max(
    0.0,
    constraints.maxHeight - padding.vertical,
  );
  final maxWidth = availableWidth * overviewMaxScale;
  final maxHeight = math.min(
    availableHeight,
    constraints.maxHeight * overviewMaxScale,
  );

  var width = maxWidth;
  var height = width / aspect;
  if (height > maxHeight) {
    height = maxHeight;
    width = height * aspect;
  }

  return Size(width, height);
}

/// Keep the page stride tied to the preview, including on tall or inset views.
/// A fixed viewport fraction changes the visible gap as the card is fitted.
/// The carousel paints an extra page on each side during dismissal reflow.
double overviewPageViewportFractionFor(Size viewSize, EdgeInsets padding) {
  if (viewSize.width <= 0) return 1;
  final cardSize = cardSizeFor(
    constraints: BoxConstraints.tight(viewSize),
    padding: padding,
    aspect: viewAspectFor(viewSize),
  );
  return ((cardSize.width + overviewPageSpacing) /
          overviewCarouselViewportWidthFor(viewSize, cardSize))
      .clamp(0.01, 1.0);
}

/// Slivers only paint children inside their viewport, even if cached. Extend
/// it by one page on either side, then clip to the actual screen in the widget,
/// so a translated neighbor can enter the screen before its slot is removed.
double overviewCarouselViewportWidthFor(Size viewSize, Size cardSize) =>
    viewSize.width + 2 * (cardSize.width + overviewPageSpacing);

/// The centred rect a preview card occupies when the overview is fully open.
Rect centerPreviewRectFor(Size viewSize, Size cardSize) {
  final left = (viewSize.width - cardSize.width) / 2.0;
  final top = (viewSize.height - cardSize.height) / 2.0;
  return Rect.fromLTWH(left, top, cardSize.width, cardSize.height);
}

/// Packs every recent app into the largest possible equal-sized landscape
/// grid. The search considers every column count, so two apps can spread into
/// one row while larger sets naturally become balanced rows. Incomplete final
/// rows are centred instead of being pinned to the leading edge.
LandscapeOverviewLayout landscapeOverviewLayoutFor({
  required Size viewSize,
  required EdgeInsets padding,
  required int itemCount,
  required double aspect,
}) {
  assert(itemCount > 0);

  final horizontalMargin = (viewSize.width * 0.035)
      .clamp(28.0, 56.0)
      .toDouble();
  final topMargin =
      ReferenceShellMetrics.statusBarHeight +
      (viewSize.height * 0.02).clamp(12.0, 20.0).toDouble();
  final bottomMargin =
      ReferenceShellMetrics.gestureHitHeight +
      ReferenceShellMetrics.gestureBottomInset +
      8.0;
  final horizontalGap = (viewSize.width * 0.018).clamp(16.0, 28.0).toDouble();
  final verticalGap = (viewSize.height * 0.03).clamp(14.0, 22.0).toDouble();

  final contentRect = Rect.fromLTRB(
    padding.left + horizontalMargin,
    padding.top + topMargin,
    math.max(
      padding.left + horizontalMargin + 1.0,
      viewSize.width - padding.right - horizontalMargin,
    ),
    math.max(
      padding.top + topMargin + 1.0,
      viewSize.height - padding.bottom - bottomMargin,
    ),
  );
  final safeAspect = aspect <= 0.0 ? kPreviewAspect : aspect;

  var bestColumns = 1;
  var bestRows = itemCount;
  var bestCardSize = Size.zero;
  var bestArea = -1.0;
  var bestEmptySlots = itemCount;

  for (var columns = 1; columns <= itemCount; columns += 1) {
    final rows = (itemCount / columns).ceil();
    final cellWidth =
        (contentRect.width - horizontalGap * (columns - 1)) / columns;
    final maxPreviewHeight =
        (contentRect.height - verticalGap * (rows - 1)) / rows;
    if (cellWidth <= 0.0 || maxPreviewHeight <= 0.0) {
      continue;
    }

    final width = math.min(cellWidth, maxPreviewHeight * safeAspect);
    final height = width / safeAspect;
    final area = width * height;
    final emptySlots = rows * columns - itemCount;
    final isLarger = area > bestArea + 0.01;
    final isTighterAtSameSize =
        (area - bestArea).abs() <= 0.01 && emptySlots < bestEmptySlots;
    if (!isLarger && !isTighterAtSameSize) {
      continue;
    }

    bestColumns = columns;
    bestRows = rows;
    bestCardSize = Size(width, height);
    bestArea = area;
    bestEmptySlots = emptySlots;
  }

  if (bestCardSize == Size.zero) {
    final width = math.max(1.0, contentRect.width / itemCount);
    bestColumns = itemCount;
    bestRows = 1;
    bestCardSize = Size(width, math.max(1.0, width / safeAspect));
  }

  if (itemCount == 1) {
    final maxSingleWidth = math.max(
      1.0,
      math.min(
        contentRect.width * _singlePreviewWidthFraction,
        _singlePreviewMaxWidth,
      ),
    );
    final width = math.min(bestCardSize.width, maxSingleWidth);
    bestCardSize = Size(width, width / safeAspect);
  }

  final itemHeight = bestCardSize.height;
  final gridHeight = itemHeight * bestRows + verticalGap * (bestRows - 1);
  final gridTop = contentRect.top + (contentRect.height - gridHeight) / 2.0;
  final itemRects = <Rect>[];

  for (var row = 0; row < bestRows; row += 1) {
    final firstIndex = row * bestColumns;
    final itemsInRow = math.min(bestColumns, itemCount - firstIndex);
    final rowWidth =
        bestCardSize.width * itemsInRow + horizontalGap * (itemsInRow - 1);
    final rowLeft = contentRect.left + (contentRect.width - rowWidth) / 2.0;
    final top = gridTop + row * (itemHeight + verticalGap);

    for (var column = 0; column < itemsInRow; column += 1) {
      itemRects.add(
        Rect.fromLTWH(
          rowLeft + column * (bestCardSize.width + horizontalGap),
          top,
          bestCardSize.width,
          itemHeight,
        ),
      );
    }
  }

  return LandscapeOverviewLayout(
    cardSize: bestCardSize,
    itemRects: List<Rect>.unmodifiable(itemRects),
    columns: bestColumns,
    rows: bestRows,
  );
}
