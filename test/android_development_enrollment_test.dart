import 'package:chantipoint/src/attendance/integration/attendance_integration_guard.dart';
import 'package:chantipoint/src/attendance/integration/development_attendance_authority.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fictional/enrollment');
  final binding = journalBinding();
  Object? response;
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    response = {
      'status': 'approved',
      'binding': binding.toJson(),
      'approval_ref': 'fictional-approval',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (response is Exception) throw response!;
          return response;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  const adapter = AndroidDevelopmentEnrollment(
    operatorPublicKey: 'fictional-public-key',
    channel: channel,
  );
  test(
    'verification is exact and cannot call enrollment or journal mutations',
    () async {
      await adapter.verify(binding);
      expect(calls.single.method, 'readDevelopmentEnrollmentV1');
      expect(calls.single.arguments, {
        'api_version': 1,
        'binding': binding.toJson(),
        'operator_public_key': 'fictional-public-key',
      });
    },
  );
  for (final invalid in [
    null,
    {'status': 'absent'},
    {'status': 'approved'},
    {
      'status': 'approved',
      'binding': binding.toJson(),
      'approval_ref': 'ok',
      'extra': true,
    },
    {
      'status': 'approved',
      'binding': journalBinding(auth: journalOtherId).toJson(),
      'approval_ref': 'ok',
    },
    {'status': 'approved', 'binding': binding.toJson(), 'approval_ref': ''},
    PlatformException(code: 'journal_missing_key', message: 'private fixture'),
    PlatformException(code: 'journal_unreadable'),
    MissingPluginException(),
  ]) {
    test(
      'malformed or unavailable native evidence ${invalid.runtimeType} denies safely',
      () async {
        response = invalid;
        await expectLater(
          adapter.verify(binding),
          throwsA(
            isA<AttendanceIntegrationFailure>().having(
              (e) => e.toString(),
              'sanitized',
              'AttendanceIntegrationFailure',
            ),
          ),
        );
        expect(
          calls.every((c) => c.method == 'readDevelopmentEnrollmentV1'),
          true,
        );
      },
    );
  }
  test('missing independent trust key does not call native storage', () async {
    await expectLater(
      const AndroidDevelopmentEnrollment(
        operatorPublicKey: '',
        channel: channel,
      ).verify(binding),
      throwsA(isA<AttendanceIntegrationFailure>()),
    );
    expect(calls, isEmpty);
  });
}
