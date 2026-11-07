import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/settings.dart';

/// Puts the RGB lights back as the Lights settings page left them when the
/// shell starts. The settings app changes them live itself.
class RgbLightsBinding extends ConsumerStatefulWidget {
  const RgbLightsBinding({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RgbLightsBinding> createState() => _RgbLightsBindingState();
}

class _RgbLightsBindingState extends ConsumerState<RgbLightsBinding> {
  @override
  void initState() {
    super.initState();
    unawaited(_restore(ref.read(rgbLightsProvider)));
  }

  Future<void> _restore(RgbLights lights) async {
    try {
      await lights.applyAll(await lights.load());
    } on Object catch (error) {
      // No lights, or no permission to write them: leave them as they are.
      debugPrint('RGB lights not restored: $error');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
