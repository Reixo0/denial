import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import '../../state/unlock_then.dart';
import '../shade/quick_settings_tiles.dart';

class MobileDataTile extends ConsumerStatefulWidget {
  const MobileDataTile({super.key, this.onSettings, this.wide = true});

  /// Opens mobile data's page in Settings (a long press).
  final VoidCallback? onSettings;

  /// A large tile (two columns) or an icon tile.
  final bool wide;
  @override
  ConsumerState<MobileDataTile> createState() => _MobileDataTileState();
}

class _MobileDataTileState extends ConsumerState<MobileDataTile> {
  bool _busy = false;
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final state =
        ref.watch(mobileNetworkProvider).value ?? const MobileNetworkSnapshot();
    final l10n = context.l10n;
    final subtitle = _failed
        ? l10n.mobileChangeFailed
        : state.modemPath == null
        ? l10n.mobileUnavailable
        : state.locked
        ? l10n.simLocked
        : !state.enabled
        ? l10n.commonOff
        : state.connected
        ? (state.operatorName.isEmpty
              ? l10n.mobileConnected
              : state.operatorName)
        : l10n.mobileDisconnected;
    return QuickTile(
      icon: Icons.network_cell_rounded,
      title: l10n.mobileData,
      subtitle: subtitle,
      active: state.enabled,
      enabled: state.canToggle && !_busy,
      busy: _busy,
      wide: widget.wide,
      onSettings: widget.onSettings,
      onTap: () async {
        // Android's Internet tile asks for the unlock first.
        final gate = ref.read(unlockThenProvider.notifier);
        if (gate.locked) {
          gate.run();
          return;
        }
        setState(() {
          _busy = true;
          _failed = false;
        });
        try {
          await ref
              .read(mobileNetworkServiceProvider)
              .setEnabled(!state.enabled);
        } on Object {
          if (mounted) setState(() => _failed = true);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      },
    );
  }
}
