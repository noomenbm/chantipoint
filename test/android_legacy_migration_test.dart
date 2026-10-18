import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/android_legacy_migration.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';
import 'support/legacy_migration_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chantipoint/secure_command_journal');
  const adapter = AndroidLegacyMigration(channel: channel);
  final binding = migrationBinding(0);
  final approval = migrationApproval(binding);
  final record = migrationRecord(binding, confirmed: true);
  final expected = Uint8List.fromList(JournalCodec.encode(record));
  final identity = 'a' * 64;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handler;

  Map<String, Object?> inspection({Uint8List? source, bool absent = false}) => {
    'inspection_version': 1,
    'binding': binding.toJson(),
    'snapshot': identity,
    'basename': approval.metadata.sourceBasename,
    'source': absent
        ? null
        : source ?? Uint8List.fromList(approval.approvedSource),
    'artifacts': <Object?>[],
  };
  Matcher issue(JournalIssue kind) =>
      throwsA(isA<JournalException>().having((e) => e.issue, 'issue', kind));
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    handler = (call) async => call.method == 'inspectLegacySourceV1'
        ? inspection()
        : {
            'status': call.method == 'cleanupLegacySourceV1'
                ? 'source_absent'
                : 'target_verified',
            'record': expected,
          };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test('inspection gives exact immutable bytes/hash and a narrow binding-only request', () async {
    final source = await adapter.inspect(binding);
    expect(source.source.bytes, approval.approvedSource);
    expect(source.source.sourceSha256, approval.metadata.sourceSha256);
    expect(source.identity, identity);
    expect(calls.single.method, 'inspectLegacySourceV1');
    expect(calls.single.arguments, {
      'api_version': 1,
      'binding': binding.toJson(),
    });
    expect(() => source.source.bytes![0] = 0, throwsUnsupportedError);
  });
  test('absence is an observation, not cleanup certification', () async {
    handler = (_) async => inspection(absent: true);
    expect((await adapter.inspect(binding)).source.bytes, isNull);
  });
  test(
    'temporary/unexpected artifact observations prevent native cleanup',
    () async {
      handler = (_) async => {
        ...inspection(),
        'artifacts': [
          {'suffix': '.bak', 'bytes': Uint8List(0)},
          {'suffix': '.tmp', 'bytes': Uint8List(0)},
        ],
      };
      final source = await adapter.inspect(binding);
      expect(source.source.artifacts, {
        LegacySourceArtifact.temporary,
        LegacySourceArtifact.unexpected,
      });
      await expectLater(
        adapter.cleanup(binding, expected, source),
        issue(JournalIssue.unreadable),
      );
      expect(calls.length, 1);
    },
  );
  for (final patch in <Map<String, Object?>>[
    {'inspection_version': 1.0},
    {'snapshot': 'invalid'},
    {'basename': '../escape'},
    {'source': <int>[]},
    {'source': Uint8List(JournalJson.recordLimit + 1)},
    {'source': Uint8List.fromList(utf8.encode('{'))},
    {'artifacts': null},
    {
      'artifacts': [
        {'suffix': '/../escape', 'bytes': Uint8List(0)},
      ],
    },
    {
      'artifacts': [
        {'suffix': '.tmp', 'bytes': Uint8List(0)},
        {'suffix': '.tmp', 'bytes': Uint8List(0)},
      ],
    },
    {'unexpected': true},
  ]) {
    test('invalid inspection response ${patch.keys} is rejected', () async {
      handler = (_) async => {...inspection(), ...patch};
      await expectLater(
        adapter.inspect(binding),
        throwsA(isA<JournalException>()),
      );
    });
  }
  test('missing nullable source field is not accepted as absence', () async {
    handler = (_) async => (inspection()..remove('source'))..['extra'] = null;
    await expectLater(
      adapter.inspect(binding),
      issue(JournalIssue.nativeFailure),
    );
  });
  test('wrong response binding and wrong owner are rejected', () async {
    handler = (_) async => {
      ...inspection(),
      'binding': journalBinding().toJson(),
    };
    await expectLater(
      adapter.inspect(binding),
      issue(JournalIssue.identityMismatch),
    );
    final wrong = utf8.encode(
      utf8
          .decode(approval.approvedSource)
          .replaceFirst(binding.profileId, journalOtherId),
    );
    handler = (_) async => inspection(source: Uint8List.fromList(wrong));
    await expectLater(
      adapter.inspect(binding),
      issue(JournalIssue.identityMismatch),
    );
  });
  test(
    'verify/cleanup requests preserve the complete record without a transition',
    () async {
      final source = await adapter.inspect(binding);
      await adapter.verifyTarget(binding, expected);
      await adapter.cleanup(binding, expected, source);
      expect(calls[1].arguments, {
        'api_version': 1,
        'binding': binding.toJson(),
        'expected_record': expected,
      });
      expect(calls[2].arguments, {
        'api_version': 1,
        'binding': binding.toJson(),
        'expected_record': expected,
        'source_snapshot': identity,
      });
      expect(record.migration!.plaintextCleanupComplete, isFalse);
      expect(record.phase, JournalPhase.confirmed);
    },
  );
  for (final target in [
    record.blockRecovery(JournalBlockReason.manualReview),
    record.markLegacyCleanupComplete(approval.metadata.sourceSha256),
    recordAt(JournalPhase.prepared),
  ]) {
    test(
      'inappropriate target ${target.phase}/${target.migration?.plaintextCleanupComplete} rejected locally',
      () async {
        await expectLater(
          adapter.verifyTarget(binding, JournalCodec.encode(target)),
          throwsA(isA<JournalException>()),
        );
        expect(calls, isEmpty);
      },
    );
  }
  test('full state validation and bounds precede channel invocation', () async {
    final invalid = utf8.encode(
      jsonEncode({...record.toJson(), 'write_may_have_started': false}),
    );
    for (final bytes in [
      invalid,
      [-1],
      [256],
      List<int>.filled(JournalJson.recordLimit + 1, 32),
    ]) {
      await expectLater(
        adapter.verifyTarget(binding, bytes),
        issue(JournalIssue.corrupt),
      );
    }
    expect(calls, isEmpty);
  });
  test('wrong target basename and inspection binding fail locally', () async {
    final wrong = JournalRecord.fromJson({
      ...record.toJson(),
      'migration': {
        ...record.migration!.toJson(),
        'source_basename': 'attendance_other.json',
      },
    });
    await expectLater(
      adapter.verifyTarget(binding, JournalCodec.encode(wrong)),
      issue(JournalIssue.identityMismatch),
    );
    final source = await adapter.inspect(binding);
    await expectLater(
      adapter.cleanup(
        journalBinding(),
        JournalCodec.encode(migrationRecord(journalBinding())),
        source,
      ),
      issue(JournalIssue.identityMismatch),
    );
    expect(calls.length, 1);
  });
  for (final response in <Object?>[
    null,
    {'status': 'target_verified'},
    {'status': 'source_absent', 'record': expected},
    {'status': 'target_verified', 'record': expected, 'extra': true},
    {
      'status': 'target_verified',
      'record': Uint8List.fromList(
        JournalCodec.encode(migrationRecord(binding)),
      ),
    },
  ]) {
    test(
      'malformed/stale target success response rejected (${response.runtimeType})',
      () async {
        handler = (_) async => response;
        await expectLater(
          adapter.verifyTarget(binding, expected),
          issue(JournalIssue.nativeFailure),
        );
      },
    );
  }
  test(
    'recovery delegates to existing storage then retries the barrier once',
    () async {
      handler = (call) async {
        if (calls.length == 1) return {'status': 'recovery_required'};
        if (call.method == 'read') {
          return {'status': 'stored', 'record': expected};
        }
        return {'status': 'target_verified', 'record': expected};
      };
      await adapter.verifyTarget(binding, expected);
      expect(calls.map((c) => c.method), [
        'verifyMigrationTargetV1',
        'read',
        'verifyMigrationTargetV1',
      ]);
    },
  );
  test('a second recovery race fails without looping', () async {
    handler = (call) async => call.method == 'read'
        ? {'status': 'stored', 'record': expected}
        : {'status': 'recovery_required'};
    await expectLater(
      adapter.verifyTarget(binding, expected),
      issue(JournalIssue.unreadable),
    );
    expect(calls.length, 3);
  });
  for (final code in [
    'journal_unreadable',
    'journal_missing_key',
    'journal_sync_failure',
    'journal_storage_failure',
    'journal_illegal_transition',
    'unknown',
  ]) {
    test(
      'native failure $code cannot become successful verification',
      () async {
        handler = (_) async => throw PlatformException(
          code: code,
          message: 'private provider error',
        );
        await expectLater(
          adapter.inspect(binding),
          throwsA(isA<JournalException>()),
        );
        await expectLater(
          adapter.verifyTarget(binding, expected),
          throwsA(isA<JournalException>()),
        );
      },
    );
  }
  test('unsupported platform makes no channel calls', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await expectLater(
      adapter.inspect(binding),
      issue(JournalIssue.unsupportedPlatform),
    );
    await expectLater(
      adapter.verifyTarget(binding, expected),
      issue(JournalIssue.unsupportedPlatform),
    );
    expect(calls, isEmpty);
  });
  test(
    'preflight uses only version, never a caller enabling flag or binding',
    () async {
      handler = (_) async => {'status': 'validation_namespace'};
      await adapter.requireIsolatedExecution();
      expect(calls.single.method, 'requireMigrationValidationV1');
      expect(calls.single.arguments, {'api_version': 1});
    },
  );
  for (final response in <Object?>[
    null,
    true,
    {'status': 'stored'},
    {'status': 'validation_namespace', 'allowed': true},
  ]) {
    test('malformed preflight ${response.runtimeType} is rejected', () async {
      handler = (_) async => response;
      await expectLater(
        adapter.requireIsolatedExecution(),
        issue(JournalIssue.nativeFailure),
      );
    });
  }
  test(
    'completed verification uses separate method with exact validated bytes',
    () async {
      final complete = record.markLegacyCleanupComplete(
        approval.metadata.sourceSha256,
      );
      final bytes = Uint8List.fromList(JournalCodec.encode(complete));
      handler = (_) async => {'status': 'target_verified', 'record': bytes};
      await adapter.verifyCompleted(binding, bytes);
      expect(calls.single.method, 'verifyCompletedMigrationV1');
      expect(calls.single.arguments, {
        'api_version': 1,
        'binding': binding.toJson(),
        'expected_record': bytes,
      });
    },
  );
  test('completed verifier rejects pending, pending verifier rejects completed locally', () async {
    await expectLater(
      adapter.verifyCompleted(binding, expected),
      issue(JournalIssue.illegalTransition),
    );
    final complete = record.markLegacyCleanupComplete(
      approval.metadata.sourceSha256,
    );
    await expectLater(
      adapter.verifyTarget(binding, JournalCodec.encode(complete)),
      issue(JournalIssue.illegalTransition),
    );
    expect(calls, isEmpty);
  });
  test(
    'completed verifier retains bounded recovery and exact record matching',
    () async {
      final bytes = Uint8List.fromList(
        JournalCodec.encode(
          record.markLegacyCleanupComplete(approval.metadata.sourceSha256),
        ),
      );
      handler = (call) async => calls.length == 1
          ? {'status': 'recovery_required'}
          : {
              'status': call.method == 'read' ? 'stored' : 'target_verified',
              'record': bytes,
            };
      await adapter.verifyCompleted(binding, bytes);
      expect(calls.map((c) => c.method), [
        'verifyCompletedMigrationV1',
        'read',
        'verifyCompletedMigrationV1',
      ]);
    },
  );
}
