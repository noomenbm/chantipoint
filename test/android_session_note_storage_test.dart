import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/notes/android_session_note_storage.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';
import 'support/session_note_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidSessionNoteStorage.channelName);
  const storage = AndroidSessionNoteStorage();
  late SessionNoteFixture f;
  setUp(() {
    f = SessionNoteFixture();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    f.close();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  void handler(Future<Object?> Function(MethodCall) call) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, call);
  test(
    'new channel namespace and complete record validation before native CAS',
    () async {
      final before = SessionNoteRecord.absent(f.operations.binding),
          next = SessionNoteRecord.absent(f.operations.binding)
              .prepare(f.command());
      handler((call) async {
        expect(call.method, 'compareAndSwap');
        final a = call.arguments as Map;
        expect(a.keys.toSet(), {
          'api_version',
          'binding',
          'expected_revision',
          'expected_key',
          'replacement',
        });
        expect(a['expected_revision'], 0);
        expect(a['expected_key'], isNull);
        expect(a['replacement'], next.bytes);
        expect(a['binding'], f.operations.binding.toJson());
        return {'status': 'written', 'revision': 1};
      });
      await storage.compareAndSwap(before, next);
    },
  );
  for (final code in [
    'journal_missing_key',
    'journal_invalidated_key',
    'journal_authentication_failed',
    'journal_unreadable',
    'journal_storage_failure',
    'journal_sync_failure',
    'unknown',
  ]) {
    test('native $code fails closed with a data-free exception', () async {
      handler(
        (_) async => throw PlatformException(
          code: code,
          message: 'private fixture note',
        ),
      );
      await expectLater(
        storage.read(f.operations.binding),
        throwsA(isA<JournalException>()),
      );
    });
  }
  test(
    'sidecar presence is unavailable, never absence or implicit recovery',
    () async {
      var calls = 0;
      handler((call) async {
        calls++;
        expect(call.method, 'read');
        return {'status': 'recovery_required'};
      });
      await expectLater(
        storage.read(f.operations.binding),
        throwsA(
          isA<JournalException>().having(
            (e) => e.issue,
            'issue',
            JournalIssue.unreadable,
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  for (final malformed in [
    'wrongOwner',
    'wrongFormat',
    'extra',
    'duplicate',
    'emptyBytes',
  ]) {
    test('reject native stored $malformed', () async {
      final next = SessionNoteRecord.absent(f.operations.binding)
          .prepare(f.command());
      var raw = utf8.decode(next.bytes);
      if (malformed == 'wrongOwner') {
        raw = raw.replaceFirst(f.operations.binding.profileId, journalOtherId);
      }
      if (malformed == 'wrongFormat') {
        raw = raw.replaceFirst('"note_format":1', '"note_format":2');
      }
      if (malformed == 'duplicate') {
        raw = raw.replaceFirst('{', '{"note_format":1,');
      }
      if (malformed == 'emptyBytes') raw = '';
      handler(
        (_) async => {
          'status': 'stored',
          'record': Uint8List.fromList(utf8.encode(raw)),
          if (malformed == 'extra') 'unexpected': true,
        },
      );
      await expectLater(
        storage.read(f.operations.binding),
        throwsA(isA<JournalException>()),
      );
    });
  }
  test('verification compares the complete expected record', () async {
    final next = SessionNoteRecord.absent(f.operations.binding)
        .prepare(f.command());
    final other = SessionNoteRecord.absent(f.operations.binding)
        .prepare(f.command(text: 'Changed'));
    handler((call) async {
      expect(call.method, 'verifyRecordV1');
      return {
        'status': 'record_verified',
        'record': Uint8List.fromList(other.bytes),
      };
    });
    await expectLater(storage.verify(next), throwsA(isA<JournalException>()));
  });
}
