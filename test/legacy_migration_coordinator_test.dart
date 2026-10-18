import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/android_legacy_migration.dart';
import 'package:chantipoint/src/attendance/journal/android_legacy_migration_coordinator.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';
import 'package:chantipoint/src/attendance/journal/legacy_migration_coordinator.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fictional_migration_context.dart';
import 'support/journal_fixtures.dart';
import 'support/legacy_migration_fixtures.dart';
import 'support/memory_journal_storage.dart';

enum _CasFault { before, afterSync, lostReply }

// A deterministic native-channel SIMULATION, not encrypted/durable Android IO.
class _Harness {
  final binding = migrationBinding(0);
  late final approval = migrationApproval(binding);
  final disk = MemoryJournalDisk();
  late final store = MemoryJournalStorage(disk);
  late final contexts = FictionalMigrationContexts((b) => approval);
  final events = <String>[];
  final sources = <String, List<int>>{};
  final casFaults = <int, _CasFault>{};
  Future<void> Function(MethodCall)? before;
  void Function(MethodCall)? after;
  bool isolated = true;
  bool cleanupBeforeFailure = false;
  bool cleanupAfterFailure = false;
  bool completionBarrierFailure = false;
  bool completedDurable = false;
  bool sidecarRecovery = false;
  int casCalls = 0;
  static const channel = MethodChannel('chantipoint/secure_command_journal');
  LegacyMigrationCoordinator get coordinator => LegacyMigrationCoordinator(
    backend: const AndroidLegacyMigrationBackend(channel: channel),
    contexts: contexts,
  );
  String name(JournalBinding b) => AndroidLegacyMigration.sourceBasename(b);
  String snapshot(JournalBinding b) => sha256
      .convert(utf8.encode('${b.storageIdentity}:${sources[name(b)]}'))
      .toString();
  void seedSource() => sources[name(binding)] = approval.approvedSource;
  JournalRecord? get record {
    final bytes = disk.snapshot(binding);
    return bytes == null ? null : JournalCodec.decode(bytes, binding).record;
  }

  Never fail(String code) => throw PlatformException(code: code);

  Future<Object?> handle(MethodCall call) async {
    events.add(call.method);
    await before?.call(call);
    final args = Map<String, Object?>.from(call.arguments as Map);
    if (call.method == 'requireMigrationValidationV1') {
      expect(args, {'api_version': 1});
      if (!isolated) fail('journal_illegal_transition');
      after?.call(call);
      return {'status': 'validation_namespace'};
    }
    final b = JournalBinding.fromJson(
      Map<String, dynamic>.from(args['binding'] as Map),
    );
    Object result;
    switch (call.method) {
      case 'inspectLegacySourceV1':
        result = {
          'inspection_version': 1,
          'binding': b.toJson(),
          'snapshot': snapshot(b),
          'basename': name(b),
          'source': sources[name(b)] == null
              ? null
              : Uint8List.fromList(sources[name(b)]!),
          'artifacts': <Object?>[],
        };
      case 'read':
        if (sidecarRecovery) {
          result = {'status': 'recovery_required'};
        } else {
          final read = await store.read(b);
          if (read.issue != null) fail('journal_missing_key');
          result = read.bytes == null
              ? {'status': 'absent'}
              : {'status': 'stored', 'record': Uint8List.fromList(read.bytes!)};
        }
      case 'inspectRecoveryV1':
        // Invalidation here must prevent the subsequent normalization mutation.
        final bytes = Uint8List.fromList(disk.snapshot(b)!);
        result = {
          'recovery_version': 1,
          'snapshot': 'a' * 64,
          'candidates': [
            {'kind': 'main', 'record': bytes},
            {'kind': 'new', 'record': bytes},
          ],
        };
      case 'normalizeRecoveryV1':
        sidecarRecovery = false;
        result = {
          'status': 'stored',
          'record': Uint8List.fromList(disk.snapshot(b)!),
        };
      case 'compareAndSwap':
        casCalls++;
        final fault = casFaults.remove(casCalls);
        if (fault == _CasFault.before) fail('journal_storage_failure');
        final issue = await store.compareAndSwap(
          binding: b,
          expectedRevision: args['expected_revision'] as int,
          expectedKey: args['expected_key'] as String?,
          replacement: args['replacement'] as Uint8List,
        );
        if (issue != null) fail('journal_revision_conflict');
        if (fault != null) {
          fail(
            fault == _CasFault.afterSync
                ? 'journal_sync_failure'
                : 'journal_native_failure',
          );
        }
        result = {
          'status': 'written',
          'revision': (args['expected_revision'] as int) + 1,
        };
      case 'cleanupLegacySourceV1':
        expect(disk.snapshot(b), args['expected_record']);
        expect(
          JournalCodec.decode(
            args['expected_record'] as Uint8List,
            b,
          ).record!.migration!.plaintextCleanupComplete,
          false,
        );
        if (args['source_snapshot'] != snapshot(b)) {
          fail('journal_revision_conflict');
        }
        if (cleanupBeforeFailure) fail('journal_sync_failure');
        sources.remove(name(b));
        if (cleanupAfterFailure) fail('journal_sync_failure');
        result = {'status': 'source_absent', 'record': args['expected_record']};
      case 'verifyCompletedMigrationV1':
        expect(disk.snapshot(b), args['expected_record']);
        expect(
          JournalCodec.decode(
            args['expected_record'] as Uint8List,
            b,
          ).record!.migration!.plaintextCleanupComplete,
          true,
        );
        if (completionBarrierFailure) fail('journal_sync_failure');
        completedDurable = true;
        result = {
          'status': 'target_verified',
          'record': args['expected_record'],
        };
      default:
        throw StateError('Unexpected fictional channel method');
    }
    after?.call(call);
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    h = _Harness()..seedSource();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_Harness.channel, (c) => h.handle(c));
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_Harness.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final operation in AttendanceCommandKind.values) {
    test(
      'complete $operation preserves original full record, key and timestamp',
      () async {
        final approval = migrationApproval(h.binding, operation: operation);
        final contexts = FictionalMigrationContexts((_) => approval);
        h.sources[h.name(h.binding)] = approval.approvedSource;
        final coordinator = LegacyMigrationCoordinator(
          backend: const AndroidLegacyMigrationBackend(),
          contexts: contexts,
        );
        final result = await coordinator.migrate(h.binding);
        final expected = migrationRecord(
          h.binding,
          operation: operation,
        ).markLegacyCleanupComplete(approval.metadata.sourceSha256);
        expect(result.outcome, LegacyMigrationOutcome.completed);
        expect(
          JournalCodec.encode(result.record!),
          JournalCodec.encode(expected),
        );
        expect(h.disk.snapshot(h.binding), JournalCodec.encode(expected));
        expect(result.record!.phase, JournalPhase.uncertain);
        expect(h.completedDurable, true);
        expect(h.sources, isEmpty);
        expect(contexts.leases.single.released, true);
      },
    );
  }
  for (final present in [true, false]) {
    for (final confirmed in [true, false]) {
      test(
        'resume pending present=$present confirmed=$confirmed without import',
        () async {
          final original = migrationRecord(h.binding, confirmed: confirmed);
          h.disk.inject(h.binding, JournalCodec.encode(original));
          if (!present) h.sources.clear();
          final result = await h.coordinator.migrate(h.binding);
          expect(result.outcome, LegacyMigrationOutcome.completed);
          expect(
            JournalCodec.encode(result.record!),
            JournalCodec.encode(
              original.markLegacyCleanupComplete(
                h.approval.metadata.sourceSha256,
              ),
            ),
          );
          expect(h.casCalls, 1);
        },
      );
    }
  }
  test(
    'normal namespace rejects before context, inspection, import or any write',
    () async {
      h.isolated = false;
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.blocked,
      );
      expect(h.events, ['requireMigrationValidationV1']);
      expect(h.contexts.leases, isEmpty);
      expect(h.disk.writes, 0);
    },
  );
  for (final condition in ['missing', 'fence', 'assignment']) {
    test(
      'missing prerequisite $condition prevents any inspection or mutation',
      () async {
        h.contexts.available = condition != 'missing';
        h.contexts.fenced = condition != 'fence';
        h.contexts.exclusive = condition != 'assignment';
        expect(
          (await h.coordinator.migrate(h.binding)).outcome,
          LegacyMigrationOutcome.prerequisitesRequired,
        );
        expect(h.events, ['requireMigrationValidationV1']);
        expect(h.disk.writes, 0);
      },
    );
  }
  for (final trust in LegacyApprovalTrust.values) {
    test('approval trust $trust controls execution', () async {
      h.contexts.trust = trust;
      final result = await h.coordinator.migrate(h.binding);
      expect(
        result.outcome,
        trust == LegacyApprovalTrust.established
            ? LegacyMigrationOutcome.completed
            : LegacyMigrationOutcome.bindingRequired,
      );
      if (trust == LegacyApprovalTrust.unverified) expect(h.disk.writes, 0);
    });
  }
  test(
    'absent external approval is not reconstructed from pending target',
    () async {
      h.disk.inject(h.binding, JournalCodec.encode(migrationRecord(h.binding)));
      h.sources.clear();
      final result = await LegacyMigrationCoordinator(
        backend: const AndroidLegacyMigrationBackend(),
        contexts: FictionalMigrationContexts((_) => null),
      ).migrate(h.binding);
      expect(result.outcome, LegacyMigrationOutcome.bindingRequired);
      expect(h.disk.writes, 0);
    },
  );
  test('conflicting approval and binding assignment stay blocked', () async {
    h.contexts.assignments[h.name(h.binding)] = journalBinding();
    expect(
      (await h.coordinator.migrate(h.binding)).issue,
      JournalIssue.identityMismatch,
    );
    h.contexts.assignments.clear();
    final result = await h.coordinator.migrate(
      journalBinding(
        environment: 'fictional-conflicting-approval',
        company: h.binding.companyId,
        profile: h.binding.profileId,
      ),
    );
    expect(result.issue, JournalIssue.identityMismatch);
    expect(h.disk.writes, 0);
  });
  for (final method in [
    'inspectLegacySourceV1',
    'read',
    'compareAndSwap',
    'cleanupLegacySourceV1',
    'verifyCompletedMigrationV1',
  ]) {
    test(
      'context invalidation after $method stops further mutations',
      () async {
        h.after = (call) {
          if (call.method == method) h.contexts.leases.last.valid = false;
        };
        final result = await h.coordinator.migrate(h.binding);
        expect(result.outcome, LegacyMigrationOutcome.invalidated);
        final last = h.events.lastIndexOf(method);
        expect(last, h.events.length - 1);
        expect(h.contexts.leases.single.released, true);
        if (method == 'cleanupLegacySourceV1') {
          expect(h.record!.migration!.plaintextCleanupComplete, false);
        }
      },
    );
  }
  test(
    'invalidation between internal journal read and import CAS prevents write',
    () async {
      var reads = 0;
      h.after = (c) {
        if (c.method == 'read' && ++reads == 2) {
          h.contexts.leases.last.valid = false;
        }
      };
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.invalidated,
      );
      expect(h.casCalls, 0);
    },
  );
  test(
    'invalidation within recovery inspection prevents internal normalization',
    () async {
      h.disk.inject(h.binding, JournalCodec.encode(migrationRecord(h.binding)));
      h.sidecarRecovery = true;
      h.after = (c) {
        if (c.method == 'inspectRecoveryV1') {
          h.contexts.leases.last.valid = false;
        }
      };
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.invalidated,
      );
      expect(h.events, isNot(contains('normalizeRecoveryV1')));
      expect(h.disk.writes, 0);
    },
  );
  for (final boundary in [1, 2]) {
    for (final fault in _CasFault.values) {
      test(
        'CAS $boundary $fault is reconciled with complete records and fresh barrier',
        () async {
          h.casFaults[boundary] = fault;
          final first = await h.coordinator.migrate(h.binding);
          if (fault == _CasFault.before) {
            expect(first.outcome, LegacyMigrationOutcome.retryable);
            if (boundary == 1) {
              expect(h.sources, isNotEmpty);
              expect(h.record, isNull);
            } else {
              expect(h.sources, isEmpty);
              expect(h.record!.migration!.plaintextCleanupComplete, false);
            }
            expect(
              (await h.coordinator.migrate(h.binding)).outcome,
              LegacyMigrationOutcome.completed,
            );
            expect(h.contexts.leases.length, 2);
          } else {
            expect(first.outcome, LegacyMigrationOutcome.completed);
          }
          expect(h.record!.phase, JournalPhase.uncertain);
          expect(h.completedDurable, true);
          expect(h.disk.writes, 2);
        },
      );
    }
  }
  for (final afterDelete in [true, false]) {
    test(
      'cleanup failure afterDelete=$afterDelete never prematurely attests and resumes',
      () async {
        h.cleanupBeforeFailure = !afterDelete;
        h.cleanupAfterFailure = afterDelete;
        expect(
          (await h.coordinator.migrate(h.binding)).outcome,
          LegacyMigrationOutcome.retryable,
        );
        expect(h.record!.migration!.plaintextCleanupComplete, false);
        expect(h.sources.isEmpty, afterDelete);
        h.cleanupBeforeFailure = h.cleanupAfterFailure = false;
        expect(
          (await h.coordinator.migrate(h.binding)).outcome,
          LegacyMigrationOutcome.completed,
        );
        expect(h.disk.writes, 2);
      },
    );
  }
  test(
    'readable failed completion CAS cannot claim durability when barrier fails',
    () async {
      h.casFaults[2] = _CasFault.afterSync;
      h.completionBarrierFailure = true;
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.retryable,
      );
      expect(h.record!.migration!.plaintextCleanupComplete, true);
      expect(h.completedDurable, false);
      h.completionBarrierFailure = false;
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.noAction,
      );
      expect(h.completedDurable, true);
      expect(h.disk.writes, 2);
    },
  );
  test(
    'changed source after import blocks cleanup and retains evidence',
    () async {
      h.after = (c) {
        if (c.method == 'compareAndSwap') {
          h.sources[h.name(h.binding)] = [...h.approval.approvedSource, 32];
        }
      };
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.blocked,
      );
      expect(h.record!.migration!.plaintextCleanupComplete, false);
      expect(h.sources, isNotEmpty);
    },
  );
  test('CAS conflict with a later independently confirmed record stays blocked until replan', () async {
    final later = migrationRecord(h.binding, confirmed: true);
    h.before = (c) async {
      if (c.method == 'compareAndSwap') {
        h.disk.inject(h.binding, JournalCodec.encode(later));
      }
    };
    expect(
      (await h.coordinator.migrate(h.binding)).outcome,
      LegacyMigrationOutcome.blocked,
    );
    expect(h.disk.snapshot(h.binding), JournalCodec.encode(later));
    expect(h.sources, isNotEmpty);
    h.before = null;
    final result = await h.coordinator.migrate(h.binding);
    expect(result.outcome, LegacyMigrationOutcome.completed);
    expect(
      JournalCodec.encode(result.record!),
      JournalCodec.encode(
        later.markLegacyCleanupComplete(h.approval.metadata.sourceSha256),
      ),
    );
  });
  test(
    'completed metadata with reappearing source is blocked without deletion',
    () async {
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.completed,
      );
      final expected = h.disk.snapshot(h.binding);
      h.seedSource();
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.blocked,
      );
      expect(h.disk.snapshot(h.binding), expected);
      expect(h.sources, isNotEmpty);
    },
  );
  test(
    'unrelated conflicting target never changes phase or deletes source',
    () async {
      final target = JournalRecord.absent(h.binding).prepare(journalCommand());
      h.disk.inject(h.binding, JournalCodec.encode(target));
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.blocked,
      );
      expect(h.disk.snapshot(h.binding), JournalCodec.encode(target));
      expect(h.sources, isNotEmpty);
      expect(h.disk.writes, 0);
    },
  );
  test('failed import with readable bytes still requires the cleanup durability barrier', () async {
    h.casFaults[1] = _CasFault.afterSync;
    h.cleanupBeforeFailure = true;
    expect(
      (await h.coordinator.migrate(h.binding)).outcome,
      LegacyMigrationOutcome.retryable,
    );
    expect(h.record!.migration!.plaintextCleanupComplete, false);
    expect(h.sources, isNotEmpty);
    expect(h.completedDurable, false);
    h.cleanupBeforeFailure = false;
    expect(
      (await h.coordinator.migrate(h.binding)).outcome,
      LegacyMigrationOutcome.completed,
    );
    expect(h.disk.writes, 2);
  });
  test('full original timestamp precision and custom key survive migration unchanged', () async {
    final source = jsonDecode(
      utf8.decode(h.approval.approvedSource),
    ) as Map<String, dynamic>;
    final payload = source['payload'] as Map<String, dynamic>;
    payload['p_device_observed_at'] = '2026-10-17T14:30:00.123456Z';
    payload['p_idempotency_key'] = 'fictional-original-key-with-precision';
    final bytes = utf8.encode(jsonEncode(source));
    final approval = LegacyBindingApproval(
      binding: h.binding,
      approvedSource: bytes,
      metadata: JournalMigration(
        sourceBasename: h.name(h.binding),
        sourceSha256: sha256.convert(bytes).toString(),
        legacyOwner: h.approval.metadata.legacyOwner,
        bindingApprovalRef: 'fictional-original-source-review',
      ),
    );
    h.sources[h.name(h.binding)] = bytes;
    final result = await LegacyMigrationCoordinator(
      backend: const AndroidLegacyMigrationBackend(),
      contexts: FictionalMigrationContexts((_) => approval),
    ).migrate(h.binding);
    final parsed = LegacyJournalImport.prepare(bytes, approval: approval);
    expect(result.outcome, LegacyMigrationOutcome.completed);
    expect(
      result.record!.command!.parametersJson,
      parsed.command!.parametersJson,
    );
    expect(
      result.record!.command!.parameters['p_device_observed_at'],
      payload['p_device_observed_at'],
    );
    expect(result.record!.command!.key, payload['p_idempotency_key']);
  });
  test('resume preserves a valid later revision instead of resetting to import revision', () async {
    final later = JournalRecord.fromJson({
      ...migrationRecord(h.binding, confirmed: true).toJson(),
      'revision': 9,
    });
    h.disk.inject(h.binding, JournalCodec.encode(later));
    final result = await h.coordinator.migrate(h.binding);
    expect(result.outcome, LegacyMigrationOutcome.completed);
    expect(
      JournalCodec.encode(result.record!),
      JournalCodec.encode(
        later.markLegacyCleanupComplete(h.approval.metadata.sourceSha256),
      ),
    );
    expect(h.casCalls, 1);
  });
  test(
    'missing key blocks without mutations or terminal journal blocking',
    () async {
      h.disk.readIssues[h.binding.storageIdentity] = JournalIssue.missingKey;
      expect(
        (await h.coordinator.migrate(h.binding)).issue,
        JournalIssue.missingKey,
      );
      expect(h.disk.writes, 0);
      expect(h.sources, isNotEmpty);
    },
  );
  test('unexplained later completion response stays blocked instead of choosing a revision', () async {
    h.after = (call) {
      if (call.method == 'compareAndSwap' && h.casCalls == 2) {
        h.disk.inject(
          h.binding,
          JournalCodec.encode(
            JournalRecord.fromJson({...h.record!.toJson(), 'revision': 10}),
          ),
        );
      }
    };
    expect(
      (await h.coordinator.migrate(h.binding)).outcome,
      LegacyMigrationOutcome.blocked,
    );
    expect(h.completedDurable, false);
  });
  test('completed record whose source reappears during verification is not reported complete', () async {
    h.after = (call) {
      if (call.method == 'verifyCompletedMigrationV1') h.seedSource();
    };
    expect(
      (await h.coordinator.migrate(h.binding)).outcome,
      LegacyMigrationOutcome.blocked,
    );
    expect(h.sources, isNotEmpty);
  });
  test(
    'empty source and target returns honest noAction without writes',
    () async {
      h.sources.clear();
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.noAction,
      );
      expect(h.disk.writes, 0);
    },
  );
  for (final differentBinding in [false, true]) {
    test(
      'same-source serialization across instances differentBinding=$differentBinding',
      () async {
        final entered = Completer<void>();
        final resume = Completer<void>();
        var held = false;
        h.before = (c) async {
          if (c.method == 'inspectLegacySourceV1' && !held) {
            held = true;
            entered.complete();
            await resume.future;
          }
        };
        final first = h.coordinator.migrate(h.binding);
        await entered.future;
        final b = differentBinding
            ? journalBinding(
                environment: 'fictional-other',
                auth: journalOtherId,
                company: h.binding.companyId,
                profile: h.binding.profileId,
              )
            : h.binding;
        final second = h.coordinator.migrate(b);
        await Future<void>.delayed(Duration.zero);
        expect(h.contexts.leases.length, 1);
        expect(h.contexts.leases.single.released, false);
        resume.complete();
        expect((await first).outcome, LegacyMigrationOutcome.completed);
        expect(
          (await second).outcome,
          differentBinding
              ? LegacyMigrationOutcome.blocked
              : LegacyMigrationOutcome.noAction,
        );
        expect(h.disk.writes, 2);
      },
    );
  }
  test('caller timeout does not release fence or source queue while native work is in flight', () async {
    final entered = Completer<void>();
    final reply = Completer<void>();
    h.before = (c) async {
      if (c.method == 'compareAndSwap' && !entered.isCompleted) {
        entered.complete();
        await reply.future;
      }
    };
    final operation = h.coordinator.migrate(h.binding);
    await entered.future;
    await expectLater(
      operation.timeout(Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    final queued = h.coordinator.migrate(h.binding);
    await Future<void>.delayed(Duration.zero);
    expect(h.contexts.leases.single.released, false);
    reply.complete();
    expect((await operation).outcome, LegacyMigrationOutcome.completed);
    expect((await queued).outcome, LegacyMigrationOutcome.noAction);
    expect(h.contexts.leases.every((c) => c.released), true);
  });
  test(
    'completed noAction rechecks source after the verification-only barrier',
    () async {
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.completed,
      );
      h.after = (call) {
        if (call.method == 'verifyCompletedMigrationV1') h.seedSource();
      };
      expect(
        (await h.coordinator.migrate(h.binding)).outcome,
        LegacyMigrationOutcome.blocked,
      );
      expect(h.sources, isNotEmpty);
      expect(h.disk.writes, 2);
    },
  );
}
