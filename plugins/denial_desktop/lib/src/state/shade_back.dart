import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What Back does in the open shade before it closes it, as Android's
/// BackActionInteractor: leave the tile editor, then the full quick settings.
final shadeBackProvider = Provider<ShadeBack>((ref) => ShadeBack());

class ShadeBack {
  /// The shade's own; true when it took the Back.
  bool Function()? handler;

  bool call() => handler?.call() ?? false;
}
