import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/applications.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/rendering.dart';

import '../../launcher/home_icon_locator.dart' show launcherAppIdentity;
import '../phone_scheme.dart';

/// The application identity shown on a recents card.
typedef _CardApplication = ({String? name, String? iconPath, IconData? icon});

final _cardApplication = Provider.autoDispose.family<_CardApplication, String>((
  ref,
  appId,
) {
  final local = ref.watch(localFlutterApplicationRegistryProvider)[appId];
  if (local != null) {
    return (name: local.title, iconPath: null, icon: local.icon);
  }
  final id = launcherAppIdentity(appId);
  final launcher = ref.watch(appLauncherProvider);
  for (final item
      in ref.watch(homeGridControllerProvider).value?.apps ??
          const <HomeGridItem>[]) {
    final app = item.app;
    if (app == null) continue;
    if (launcher
        .expectedWindowAppIds(app)
        .any((candidate) => launcherAppIdentity(candidate) == id)) {
      return (name: app.name, iconPath: app.iconPath, icon: null);
    }
  }
  return (name: null, iconPath: null, icon: null);
});

/// The app chip over a recents card's top start corner, as Android 17's
/// IconAppChipView. Collapsed it is a 156 x 36 dp pill 8 dp inside its
/// 4 dp inset box (task_thumbnail_icon_menu_background_margin_top_start):
/// a 24 dp icon 6 dp in, the name 8 dp after it in an 86 dp box (14 sp,
/// fading at its end), a 24 dp chevron. Opening its menu, [expansion] grows
/// it to 216 x 52 dp filling the box, the icon to 32 dp, the name box to
/// 118 dp, and turns the chevron up. surfaceBright, lifted 4 dp.
class OverviewCardLabel extends ConsumerWidget {
  const OverviewCardLabel({
    super.key,
    required this.window,
    required this.dp,
    this.expansion = 0,
  });

  /// The chip's box, which the expanded chip fills.
  static const double boxWidthDp = 216;
  static const double boxHeightDp = 52;

  /// The box's inset from the card's top start corner, in dp.
  static const double insetDp = 4;

  /// The collapsed pill's margin inside the box, in dp.
  static const double marginDp = 8;
  static const double collapsedWidthDp = 156;
  static const double collapsedHeightDp = 36;

  final DenialWindow window;

  /// Logical pixels per Android dp.
  final double dp;

  /// 0 collapsed, 1 open with its menu.
  final double expansion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final application = ref.watch(_cardApplication(window.appId));
    final scheme = phoneSchemeOf(context);
    final icon = application.icon;
    final name = application.name ?? localizedWindowTitle(context, window);
    final e = expansion.clamp(0.0, 1.0);
    double lerp(double a, double b) => (a + (b - a) * e) * dp;
    final margin = lerp(marginDp, 0);
    final height = lerp(collapsedHeightDp, boxHeightDp);
    final iconSize = lerp(24, 32);
    final nameBox = lerp(86, 118);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: margin, top: margin),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: Container(
          width: lerp(collapsedWidthDp, boxWidthDp),
          height: height,
          decoration: BoxDecoration(
            color: scheme.surfaceBright,
            borderRadius: BorderRadius.circular(height / 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0x40000000),
                blurRadius: 4 * dp,
                offset: Offset(0, 1 * dp),
              ),
            ],
          ),
          padding: EdgeInsetsDirectional.only(start: lerp(6, 10)),
          child: Row(
            children: [
              SizedBox.square(
                dimension: iconSize,
                child: icon != null
                    ? FittedBox(child: Icon(icon, color: scheme.onSurface))
                    : AppIconImage(iconPath: application.iconPath),
              ),
              SizedBox(width: 8 * dp),
              SizedBox(
                width: nameBox,
                // Android fades a name longer than its box at the end.
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) =>
                      LinearGradient(
                        begin: AlignmentDirectional.centerStart,
                        end: AlignmentDirectional.centerEnd,
                        stops: [1 - 20 * dp / nameBox, 1],
                        colors: const [Color(0xffffffff), Color(0x00ffffff)],
                      ).createShader(
                        bounds,
                        textDirection: Directionality.of(context),
                      ),
                  child: Text(
                    name,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: lerp(14, 16) * phoneTextScale,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Transform.rotate(
                angle: e * 3.141592653589793,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 24 * dp,
                  color: scheme.onSurface,
                ),
              ),
              SizedBox(width: lerp(0, 8)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The menu under an open app chip (Launcher3's TaskMenuView): 216 dp
/// wide, 2 dp below the chip, in surfaceBright with 26 dp corners; 52 dp
/// rows with a 20 dp icon 16 dp in and 16 sp text 18 dp after it.
class OverviewTaskMenu extends StatelessWidget {
  const OverviewTaskMenu({super.key, required this.dp, required this.items});

  static const double widthDp = 216;
  static const double rowDp = 52;
  static const double gapDp = 2;

  final double dp;
  final List<({IconData icon, String label, VoidCallback onTap})> items;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Container(
      width: widthDp * dp,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceBright,
        borderRadius: BorderRadius.circular(26 * dp),
        boxShadow: [
          BoxShadow(
            color: const Color(0x40000000),
            blurRadius: 4 * dp,
            offset: Offset(0, 1 * dp),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: item.onTap,
              child: SizedBox(
                height: rowDp * dp,
                child: Row(
                  children: [
                    SizedBox(width: 16 * dp),
                    Icon(item.icon, size: 20 * dp, color: scheme.onSurface),
                    SizedBox(width: 18 * dp),
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 16 * dp * phoneTextScale,
                          fontWeight: FontWeight.w400,
                          height: 1.2,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
