import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_recovery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

// Scripted native transport only: these tests do not prove Android durability.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chantipoint/secure_command_journal');
  const storage = AndroidJournalStorage(channel: channel);
  final binding = journalBinding();
  final original = JournalCodec.encode(recordAt(JournalPhase.uncertain));
  late Map<String, List<int>> artifacts;
  late List<MethodCall> calls;
  late String snapshot;
  String? inspectError;
  String? normalizeError;
  bool failAfterCleanup = false;
  void Function()? beforeNormalize;
  Object? Function(Object?)? alterInspection;
  Object? normalizationResponse;

  Map<String, Object> inspection() => {
    'recovery_version': 1,
    'snapshot': snapshot,
    'candidates': [
      for (final entry in artifacts.entries)
        {'kind': entry.key, 'record': Uint8List.fromList(entry.value)},
    ],
  };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    artifacts = {'main': List.of(original), 'new': List.of(original)};
    calls = [];
    snapshot = 'a' * 64;
    inspectError = null;
    normalizeError = null;
    failAfterCleanup = false;
    beforeNormalize = null;
    alterInspection = null;
    normalizationResponse = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final args = call.arguments as Map;
          expect(args['api_version'], 1);
          expect(args['binding'], binding.toJson());
          switch (call.method) {
            case 'read':
              if (artifacts.keys.any((kind) => kind != 'main')) {
                return {'status': 'recovery_required'};
              }
              return artifacts['main'] == null
                  ? {'status': 'absent'}
                  : {
                      'status': 'stored',
                      'record': Uint8List.fromList(artifacts['main']!),
                    };
            case 'inspectRecoveryV1':
              if (inspectError != null) {
                throw PlatformException(code: inspectError!);
              }
              final result = inspection();
              return alterInspection == null
                  ? result
                  : alterInspection!(result);
            case 'normalizeRecoveryV1':
              beforeNormalize?.call();
              if (args['snapshot'] != snapshot) {
                throw PlatformException(code: 'journal_revision_conflict');
              }
              if (normalizeError != null) {
                throw PlatformException(code: normalizeError!);
              }
              expect(args.keys.toSet(), {
                'api_version',
                'binding',
                'snapshot',
                'validated_record',
              });
              expect(args['validated_record'], artifacts['main']);
              expect(artifacts.length, 2);
              artifacts.removeWhere((kind, _) => kind != 'main');
              if (failAfterCleanup) {
                throw PlatformException(code: 'journal_sync_failure');
              }
              return normalizationResponse ??
                  {
                    'status': 'stored',
                    'record': Uint8List.fromList(artifacts['main']!),
                  };
            default:
              fail('Unexpected method: ${call.method}');
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('main only uses one normal read without recovery', () async {
    artifacts.remove('new');
    expect((await storage.read(binding)).bytes, original);
    expect(calls.map((c) => c.method), ['read']);
  });

  for (final sidecar in ['new', 'bak']) {
    for (final phase in JournalPhase.values) {
      test(
        'identical main/$sidecar preserves complete $phase record and revision',
        () async {
          final bytes = JournalCodec.encode(recordAt(phase));
          artifacts = {'main': List.of(bytes), sidecar: List.of(bytes)};
          final result = await CommandJournal(storage).read(binding);
          expect(result.issue, isNull);
          expect(result.record!.toJson(), recordAt(phase).toJson());
          expect(result.isBlocked, phase == JournalPhase.blocked);
          expect(artifacts, {'main': bytes});
          expect(calls.map((c) => c.method), [
            'read',
            'inspectRecoveryV1',
            'normalizeRecoveryV1',
          ]);
          expect((calls.last.arguments as Map)['validated_record'], bytes);
        },
      );
    }
  }

  final different = <String, List<int>>{
    'revision': JournalCodec.encode(
      JournalRecord.fromJson({
        ...recordAt(JournalPhase.uncertain).toJson(),
        'revision': 90,
      }),
    ),
    'phase': JournalCodec.encode(recordAt(JournalPhase.mayHaveSent)),
    'command payload': JournalCodec.encode(
      recordAt(
        JournalPhase.uncertain,
        command: journalCommand(key: 'another-fictional-key'),
      ),
    ),
    'request bytes': utf8.encode(
      utf8.decode(original).replaceFirst('45.123456789', '45.123456788'),
    ),
    'JSON representation': utf8.encode('${utf8.decode(original)}\n'),
    'confirmation receipt': JournalCodec.encode(
      recordAt(JournalPhase.confirmed),
    ),
    'empty tombstone': JournalCodec.encode(recordAt(JournalPhase.empty)),
  };
  for (final entry in different.entries) {
    test('different ${entry.key} is retained without normalization', () async {
      artifacts['new'] = entry.value;
      final before = Map<String, List<int>>.of(artifacts);
      expect((await storage.read(binding)).issue, JournalIssue.unreadable);
      expect(artifacts, before);
      expect(calls.map((c) => c.method), ['read', 'inspectRecoveryV1']);
    });
  }
  test('different valid receipts at the same phase/revision block', () async {
    final confirmed = recordAt(JournalPhase.confirmed);
    final first = JournalCodec.encode(confirmed);
    final other = JournalCodec.encode(
      JournalRecord.fromJson({
        ...confirmed.toJson(),
        'confirmation': journalConfirmation(
          confirmed.command!,
          replay: true,
        ).toJson(),
      }),
    );
    artifacts = {'main': first, 'bak': other};
    expect((await storage.read(binding)).issue, JournalIssue.unreadable);
    expect(artifacts.length, 2);
  });

  for (final kind in ['new', 'bak']) {
    test('only $kind never becomes absence or gets promoted', () async {
      artifacts = {kind: original};
      expect((await storage.read(binding)).issue, JournalIssue.unreadable);
      expect(artifacts, {kind: original});
      expect(calls.length, 2);
    });
  }
  test('three artifacts remain blocked even if identical', () async {
    artifacts['bak'] = original;
    expect((await storage.read(binding)).issue, JournalIssue.unreadable);
    expect(artifacts.length, 3);
  });
  for (final patch in <Map<String, dynamic>>[
    {'write_may_have_started': false},
    {'confirmation': null, 'phase': 'confirmed'},
    {'journal_format': 99},
    {'binding': journalBinding(environment: 'different-fixture').toJson()},
  ]) {
    test(
      'complete Dart validation rejects identical invalid candidates $patch',
      () async {
        final bytes = utf8.encode(
          jsonEncode({...recordAt(JournalPhase.uncertain).toJson(), ...patch}),
        );
        artifacts = {'main': bytes, 'new': bytes};
        final result = await storage.read(binding);
        expect(result.issue, isNotNull);
        expect(result.bytes, isNull);
        expect(artifacts.length, 2);
        expect(calls.length, 2);
      },
    );
  }
  for (final nativeError in {
    'journal_corrupt': JournalIssue.corrupt,
    'journal_authentication_failed': JournalIssue.authenticationFailed,
    'journal_missing_key': JournalIssue.missingKey,
    'journal_invalidated_key': JournalIssue.invalidatedKey,
    'journal_unsupported_container': JournalIssue.unsupportedContainer,
  }.entries) {
    test(
      '${nativeError.key} during inspection preserves artifacts with no fallback',
      () async {
        inspectError = nativeError.key;
        expect((await storage.read(binding)).issue, nativeError.value);
        expect(artifacts, {'main': original, 'new': original});
        expect(calls.map((c) => c.method), ['read', 'inspectRecoveryV1']);
      },
    );
  }
  test('changed snapshot blocks cleanup without an automatic retry', () async {
    beforeNormalize = () {
      snapshot = 'b' * 64;
      artifacts['new'] = different['revision']!;
    };
    expect((await storage.read(binding)).issue, JournalIssue.revisionConflict);
    expect(artifacts['main'], original);
    expect(artifacts['new'], different['revision']);
    expect(calls.length, 3);
  });
  for (final failure in ['journal_storage_failure', 'journal_sync_failure']) {
    test(
      '$failure before cleanup blocks and permits a later safe retry',
      () async {
        normalizeError = failure;
        expect(
          (await storage.read(binding)).issue,
          failure == 'journal_sync_failure'
              ? JournalIssue.synchronizationFailure
              : JournalIssue.storageFailure,
        );
        expect(artifacts.length, 2);
        normalizeError = null;
        expect((await storage.read(binding)).bytes, original);
        expect(artifacts, {'main': original});
      },
    );
  }
  test('interruption after duplicate cleanup retains main and repeated reads are safe', () async {
    failAfterCleanup = true;
    expect(
      (await storage.read(binding)).issue,
      JournalIssue.synchronizationFailure,
    );
    expect(artifacts, {'main': original});
    expect((await storage.read(binding)).bytes, original);
    expect((await storage.read(binding)).bytes, original);
    expect(calls.where((c) => c.method == 'normalizeRecoveryV1').length, 1);
  });
  test('normalization response must match all validated bytes', () async {
    normalizationResponse = {
      'status': 'stored',
      'record': Uint8List.fromList(different['revision']!),
    };
    expect((await storage.read(binding)).issue, JournalIssue.nativeFailure);
  });
  test(
    'another reader already normalized: validated main needs no second cleanup',
    () async {
      alterInspection = (_) {
        artifacts.remove('new');
        return inspection();
      };
      expect((await storage.read(binding)).bytes, original);
      expect(calls.length, 2);
    },
  );
  var malformedIndex = 0;
  for (final malformed in <Object?>[
    null,
    {'recovery_version': 2, 'snapshot': 'a' * 64, 'candidates': []},
    {'recovery_version': 1, 'snapshot': 'not-a-digest', 'candidates': []},
    {
      'recovery_version': 1,
      'snapshot': 'a' * 64,
      'candidates': [
        {'kind': '../other', 'record': Uint8List.fromList(original)},
      ],
    },
    {
      'recovery_version': 1,
      'snapshot': 'a' * 64,
      'candidates': [
        {'kind': 'main', 'record': original},
      ],
    },
  ]) {
    test(
      'malformed inspection ${malformedIndex++} cannot authorize cleanup',
      () async {
        alterInspection = (_) => malformed;
        expect((await storage.read(binding)).issue, JournalIssue.nativeFailure);
        expect(artifacts.length, 2);
        expect(calls.length, 2);
      },
    );
  }
  test('policy snapshots bytes without aliasing the native response', () {
    final response = inspection();
    final plan = JournalRecoveryPlan.inspect(response, binding);
    final candidates = response['candidates'] as List;
    ((candidates.first as Map)['record'] as Uint8List)[0] = 0;
    expect(plan.record, original);
    expect(() => plan.record[0] = 0, throwsUnsupportedError);
  });
}
