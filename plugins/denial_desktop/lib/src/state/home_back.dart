import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the system Back action closes on home, such as the app drawer or an
/// open folder; null when home has nothing open. Back reaches it after the
/// keyboard, the shade and recents.
final homeBackProvider = NotifierProvider<HomeBack, VoidCallback?>(
  HomeBack.new,
);

class HomeBack extends Notifier<VoidCallback?> {
  @override
  VoidCallback? build() => null;

  void set(VoidCallback? back) => state = back;
}
