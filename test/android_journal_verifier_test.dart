import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_verifier.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidJournalStorage.channelName);
  const verifier = AndroidJournalVerifier(channel: channel);
  final binding = journalBinding();
  final bytes = JournalCodec.encode(recordAt(JournalPhase.confirmed));
  late Future<Object?> Function(MethodCall) handler;
  var calls = 0;
  setUp(() {
    calls = 0;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    handler = (call) async {
      expect(call.method, 'verifyRecordV1');
      final args = call.arguments as Map;
      expect(args.keys.toSet(), {'api_version', 'binding', 'expected_record'});
      expect(args['api_version'], 1);
      expect(args['binding'], binding.toJson());
      expect(args['expected_record'], bytes);
      return {'status': 'record_verified', 'record': Uint8List.fromList(bytes)};
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls++;
          return handler(call);
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('versioned exact-byte barrier', () async {
    expect(await verifier.verify(binding, bytes), isNull);
    expect(calls, 1);
  });
  for (final input in [
    <int>[123],
    <int>[256],
    List<int>.filled(JournalJson.recordLimit + 1, 0),
    utf8.encode(
      JournalJson.encode({
        ...recordAt(JournalPhase.confirmed).toJson(),
        'binding': journalBinding(environment: 'wrong').toJson(),
      }),
    ),
  ]) {
    test('invalid expected record rejected locally ${input.length}', () async {
      expect(await verifier.verify(binding, input), isNotNull);
      expect(calls, 0);
    });
  }
  for (final response in [
    null,
    {'status': 'stored', 'record': Uint8List.fromList(bytes)},
    {'status': 'record_verified'},
    {'status': 'record_verified', 'record': bytes},
    {
      'status': 'record_verified',
      'record': Uint8List.fromList([123]),
    },
    {
      'status': 'record_verified',
      'record': Uint8List.fromList([32, ...bytes]),
    },
    {
      'status': 'record_verified',
      'record': Uint8List.fromList(bytes),
      'extra': true,
    },
  ]) {
    test('nonexact response fails closed ${response.hashCode}', () async {
      handler = (_) async => response;
      expect(await verifier.verify(binding, bytes), isNotNull);
    });
  }
  for (final entry in AndroidJournalStorage.errorCodes.entries) {
    test('safe native error ${entry.key}', () async {
      handler = (_) async =>
          throw PlatformException(code: entry.key, message: 'private fixture');
      expect(await verifier.verify(binding, bytes), entry.value);
    });
  }
  test('missing plugin fails closed', () async {
    handler = (_) async => throw MissingPluginException();
    expect(
      await verifier.verify(binding, bytes),
      JournalIssue.unsupportedPlatform,
    );
  });
  test('unsupported platform makes no call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(
      await verifier.verify(binding, bytes),
      JournalIssue.unsupportedPlatform,
    );
    expect(calls, 0);
  });
}
