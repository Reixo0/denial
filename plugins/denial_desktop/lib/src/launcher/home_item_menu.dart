import 'package:flutter/material.dart';

import 'package:denial_flutter_sdk/applications.dart';

import 'home_interactions.dart';

/// Where a held icon is.
enum HomeItemPlace { grid, folder, dock, drawer }

/// The icon a long press opened the menu for.
@immutable
class HomeItemMenuRequest {
  const HomeItemMenuRequest({
    required this.item,
    required this.place,
    required this.iconRect,
  });

  final HomeGridItem item;
  final HomeItemPlace place;

  /// The icon, in global coordinates; the menu opens beside it.
  final Rect iconRect;
}

/// One option in the menu a held icon opens.
///
/// To add an option, implement this and list it in [homeItemActions]. The
/// menu shows, in that order, the options that apply to the held icon.
abstract class HomeItemAction {
  const HomeItemAction();

  IconData get icon;
  String label(BuildContext context);

  /// Whether the option makes sense for [request], with home as [grid].
  bool appliesTo(HomeItemMenuRequest request, HomeGridState grid);

  /// The menu has closed when this runs.
  void invoke(HomeItemMenuRequest request, HomeGridHost home);
}

const List<HomeItemAction> homeItemActions = [
  AddToHomeAction(),
  RemoveFromHomeAction(),
  NewWindowAction(),
];

/// Puts an app taken off home back, on the current page or the first free
/// cell after it.
class AddToHomeAction extends HomeItemAction {
  const AddToHomeAction();

  @override
  IconData get icon => Icons.add_to_home_screen_rounded;

  @override
  String label(BuildContext context) => 'Add to home';

  @override
  bool appliesTo(HomeItemMenuRequest request, HomeGridState grid) =>
      request.place == HomeItemPlace.drawer &&
      grid.hidden.contains(request.item.id);

  @override
  void invoke(HomeItemMenuRequest request, HomeGridHost home) {
    final pageSize = home.geometry?.pageSize ?? 0;
    home.gridController.addToHome(
      request.item.id,
      (home.grid?.page ?? 0) * pageSize,
    );
  }
}

/// Takes an app, or a folder with its apps, off home. They stay installed
/// and in the app drawer.
class RemoveFromHomeAction extends HomeItemAction {
  const RemoveFromHomeAction();

  @override
  IconData get icon => Icons.remove_circle_outline_rounded;

  @override
  String label(BuildContext context) => 'Remove';

  @override
  bool appliesTo(HomeItemMenuRequest request, HomeGridState grid) {
    final item = request.item;
    if (!(item.isApp || item.isFolder)) return false;
    return request.place != HomeItemPlace.drawer ||
        !grid.hidden.contains(item.id);
  }

  @override
  void invoke(HomeItemMenuRequest request, HomeGridHost home) =>
      home.gridController.removeFromHome(request.item.id);
}

/// Opens another window of an app, even while one is open: through the
/// app's own new-window action when its desktop entry has one, else by
/// starting it again. Android apps do not open a second window yet.
class NewWindowAction extends HomeItemAction {
  const NewWindowAction();

  @override
  IconData get icon => Icons.open_in_new_rounded;

  @override
  String label(BuildContext context) => 'New window';

  @override
  bool appliesTo(HomeItemMenuRequest request, HomeGridState grid) {
    final app = request.item.app;
    return request.item.isApp &&
        app != null &&
        !app.id.startsWith('droidloom-');
  }

  @override
  void invoke(HomeItemMenuRequest request, HomeGridHost home) =>
      home.launchNewWindow(request.item, request.iconRect);
}

/// The menu itself: the options that apply, beside the held icon.
class HomeItemMenu extends StatelessWidget {
  const HomeItemMenu({
    super.key,
    required this.anchor,
    required this.actions,
    required this.onSelected,
    required this.menuKey,
  });

  /// The held icon, in the menu layer's coordinates.
  final Rect anchor;
  final List<HomeItemAction> actions;
  final ValueChanged<HomeItemAction> onSelected;

  /// Marks the card, so a press outside it can close the menu.
  final GlobalKey menuKey;

  static const double width = 220;
  static const double rowHeight = 50;
  static const double margin = 12;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final icon = anchor;
        final height = actions.length * rowHeight + 12;
        // Above the icon when it fits, else below it.
        final above = icon.top - margin - height;
        final top = above >= margin ? above : icon.bottom + margin;
        final left = (icon.center.dx - width / 2).clamp(
          margin,
          constraints.maxWidth - width - margin,
        );
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: width,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.9, end: 1),
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                builder: (context, scale, child) => Transform.scale(
                  scale: scale,
                  alignment: top < icon.top
                      ? Alignment.bottomCenter
                      : Alignment.topCenter,
                  child: Opacity(
                    opacity: ((scale - 0.9) * 10).clamp(0.0, 1.0),
                    child: child,
                  ),
                ),
                child: _MenuCard(
                  key: menuKey,
                  actions: actions,
                  onSelected: onSelected,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({super.key, required this.actions, required this.onSelected});

  final List<HomeItemAction> actions;
  final ValueChanged<HomeItemAction> onSelected;

  static const Color _fill = Color(0xf0202226);
  static const Color _foreground = Color(0xfff2f2f4);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _fill,
      elevation: 8,
      shadowColor: const Color(0x99000000),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              InkWell(
                onTap: () => onSelected(action),
                child: SizedBox(
                  height: HomeItemMenu.rowHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: 18),
                      Icon(action.icon, size: 22, color: _foreground),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          action.label(context),
                          style: const TextStyle(
                            color: _foreground,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
