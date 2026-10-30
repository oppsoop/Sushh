import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:worldfriends/core/outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('outgoing entries and stable IDs survive a restart', () async {
    final outbox = await Outbox.load();
    await outbox.add(OutboxEntry(
      clientId: 'stable-client-id', conversationId: 'conversation', kind: 'image',
      localMediaPath: '/private/queued-image.jpg', mimeType: 'image/jpeg', durationMs: 12,
    ));
    await outbox.saveMediaId('stable-client-id', 'server-media-id');
    final restarted = await Outbox.load();
    expect(restarted.entries.length, 1);
    expect(restarted.entries.single.clientId, 'stable-client-id');
    expect(restarted.entries.single.mediaId, 'server-media-id');
    expect(restarted.entries.single.localMediaPath, '/private/queued-image.jpg');
    expect(restarted.entries.single.mimeType, 'image/jpeg');
    await restarted.remove('stable-client-id');
    expect((await Outbox.load()).isEmpty, isTrue);
  });

  test('a permanent failure remains queued until explicitly retried', () async {
    final outbox = await Outbox.load();
    await outbox.add(OutboxEntry(clientId: 'message-123', conversationId: 'chat', kind: 'text', body: 'hello'));
    await outbox.markAttempt('message-123', 'Not allowed');
    expect((await Outbox.load()).entries.single.lastError, 'Not allowed');
    await outbox.resetError('message-123');
    expect((await Outbox.load()).entries.single.lastError, isNull);
  });
}
