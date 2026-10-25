import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Old-adapter host tests explicitly simulate a native installation that has
/// NOT been retired. This fixture never serves the enrollment approval API.
void legacyWriterNativeFixture() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidJournalStorage.channelName);
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'requireOldWriterAllowedV1') {
            throw PlatformException(code: 'journal_illegal_transition');
          }
          return {'status': 'allowed'};
        }),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}
