/// Desktop-entry metadata shared with Denial's application catalog.
///
/// [exec] is desktop-entry data, not a shell command for plugins to execute.
/// Application launching remains a native runtime operation.
class const DesktopApp({
  required final String id,
  required final String name,
  required final String exec,
  required final String desktopPath,
  required final List<String> categories,
  final List<String> keywords = const <String>[],
  final String? icon,
  final String? iconPath,
  final String? startupWmClass,

  /// The Exec of the entry's `new-window` action, when it has one.
  final String? newWindowExec,
}) {
  String get searchableText =>
      <String>[id, name, ...categories, ...keywords].join(' ').toLowerCase();
}
