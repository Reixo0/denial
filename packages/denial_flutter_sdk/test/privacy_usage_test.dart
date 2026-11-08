import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads what is in use and by which apps', () {
    final usage = PrivacyUsage.parse(
      '{"inUse": {"microphone": true, "camera": false, "location": true},'
      ' "microphone": ["firefox", "pw-cat"], "camera": [], "location": []}',
    );
    expect(usage.microphone, isTrue);
    expect(usage.camera, isFalse);
    expect(usage.location, isTrue);
    expect(usage.any, isTrue);
    expect(usage.microphoneApps, ['firefox', 'pw-cat']);
    expect(usage.locationApps, isEmpty);
  });

  test('anything unreadable means nothing in use', () {
    for (final text in ['', 'not json', '[]', '{"inUse": 3}']) {
      final usage = PrivacyUsage.parse(text);
      expect(usage.any, isFalse, reason: text);
    }
  });

  test('ignores names that are not strings', () {
    final usage = PrivacyUsage.parse(
      '{"inUse": {"camera": true}, "camera": ["braun", 7, null]}',
    );
    expect(usage.cameraApps, ['braun']);
  });

  test('equal contents are equal', () {
    const text = '{"inUse": {"microphone": true}, "microphone": ["firefox"]}';
    expect(PrivacyUsage.parse(text), PrivacyUsage.parse(text));
  });
}
