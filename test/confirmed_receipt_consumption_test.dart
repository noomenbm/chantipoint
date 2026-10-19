import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance_operation_ports.dart';
import 'support/journal_fixtures.dart';
import 'support/legacy_migration_fixtures.dart';
import 'support/memory_journal_storage.dart';

class ConsumptionVerifier implements JournalVerifier {
  final records = <List<int>>[];
  JournalIssue? issue;
  Future<void> Function()? during;
  @override
  Future<JournalIssue?> verify(
    JournalBinding binding,
    List<int> expectedRecord,
  ) async {
    records.add(List.of(expectedRecord));
    await during?.call();
    return issue;
  }
}

class ConsumptionQuery implements AttendanceActiveSessionQuery {
  WorkSession? result = journalSession();
  int calls = 0;
  Future<WorkSession?> Function()? during;
  @override
  Future<WorkSession?> readActiveSession(
    AttendanceOperationIdentity identity,
  ) async {
    calls++;
    return during == null ? result : await during!();
  }
}

void main() {
  late FictionalAttendanceOperations h;
  late ConsumptionVerifier verifier;
  late AttendanceOperationCoordinator core;
  late ConsumptionQuery query;
  AttendanceOperationCoordinator replacement() =>
      AttendanceOperationCoordinator(
        storage: h.storage,
        transport: h.transport,
        canonical: h.canonical,
        verifier: verifier,
      );
  Future<void> confirm() async {
    final result = await core.submit(h.issuer.context(), journalCommand());
    expect(result.outcome, AttendanceOperationOutcome.confirmed);
  }

  setUp(() {
    h = FictionalAttendanceOperations();
    verifier = ConsumptionVerifier();
    core = replacement();
    query = ConsumptionQuery();
  });

  test('queued duplicate consumption cannot consume a newer command', () async {
    await confirm();
    final entered = Completer<void>();
    final finish = Completer<void>();
    var first = true;
    h.canonical.onRead = () async {
      if (first) {
        first = false;
        entered.complete();
        await finish.future;
      }
      return journalSession();
    };
    final consuming = core.consumeConfirmed(h.issuer.context());
    await entered.future;
    final newCommand = journalCommand(key: 'fictional-new-queued-key');
    final next = core.submit(h.issuer.context(), newCommand);
    final duplicate = core.consumeConfirmed(h.issuer.context());
    finish.complete();
    expect((await consuming).outcome, AttendanceOperationOutcome.consumed);
    expect((await next).outcome, AttendanceOperationOutcome.confirmed);
    expect(
      (await duplicate).problem,
      AttendanceOperationProblem.commandConflict,
    );
    expect(h.record!.phase, JournalPhase.confirmed);
    expect(h.record!.command!.key, newCommand.key);
    expect(h.record!.revision, 7);
  });

  test(
    'same key/revision with changed full receipt is not consumption-equivalent',
    () async {
      await confirm();
      final original = h.record!;
      h.canonical.onRead = () async {
        h.inject(
          JournalRecord.fromJson({
            ...original.toJson(),
            'confirmation': {
              ...original.confirmation!.toJson(),
              'data_json': ' ${original.confirmation!.dataJson} ',
            },
          }),
        );
        return journalSession();
      };
      expect(
        (await core.consumeConfirmed(h.issuer.context())).problem,
        AttendanceOperationProblem.consumptionUncertain,
      );
      expect(h.record!.phase, JournalPhase.confirmed);
      expect(h.record!.revision, original.revision);
      expect(
        h.record!.confirmation!.dataJson,
        ' ${original.confirmation!.dataJson} ',
      );
    },
  );

  test('native-style revision conflict after full read preserves conflicting record', () async {
    await confirm();
    final original = h.record!;
    h.storage.beforeCas = (record) async {
      if (record.phase == JournalPhase.empty) {
        h.inject(JournalRecord.fromJson({...original.toJson(), 'revision': 4}));
      }
    };
    final result = await core.consumeConfirmed(h.issuer.context());
    expect(result.journalIssue, JournalIssue.revisionConflict);
    expect(h.record!.phase, JournalPhase.confirmed);
    expect(h.record!.confirmation!.dataJson, original.confirmation!.dataJson);
  });

  test('throwing empty barrier cannot create readiness', () async {
    await confirm();
    await core.consumeConfirmed(h.issuer.context());
    core = replacement();
    verifier.during = () async => throw StateError('private fictional failure');
    expect(
      (await core.recoverEmpty(h.issuer.context())).journalIssue,
      JournalIssue.nativeFailure,
    );
    expect(
      (await core.readActive(h.issuer.context(), query)).problem,
      AttendanceOperationProblem.emptyRecoveryRequired,
    );
    expect(query.calls, 0);
  });

  test('active SELECT auth invalidation cannot publish even after durable consumption', () async {
    await confirm();
    await core.consumeConfirmed(h.issuer.context());
    query.during = () async {
      h.issuer.relogin();
      return journalSession();
    };
    final result = await core.readActive(h.issuer.context(), query);
    expect(result.outcome, AttendanceOperationOutcome.invalidated);
    expect(result.snapshot, isNull);
  });

  test(
    'caller timeout cannot cancel compaction or release submitted ownership',
    () async {
      await confirm();
      final entered = Completer<void>();
      final finish = Completer<void>();
      h.storage.beforeCas = (record) async {
        if (record.phase == JournalPhase.empty) {
          entered.complete();
          await finish.future;
        }
      };
      final context = h.issuer.context();
      final work = core.consumeConfirmed(context);
      await entered.future;
      try {
        await expectLater(
          work.timeout(Duration.zero),
          throwsA(isA<TimeoutException>()),
        );
        expect(context.releaseCalls, 0);
        expect(h.record!.phase, JournalPhase.confirmed);
      } finally {
        finish.complete();
      }
      expect((await work).outcome, AttendanceOperationOutcome.consumed);
      expect(context.releaseCalls, 1);
    },
  );

  test(
    'check-in, consume, checkout, consume advances exact revisions 3/4/7/8',
    () async {
      await confirm();
      final firstReceipt = h.record!.confirmation!.dataJson;
      expect(h.record!.revision, 3);
      final consumed = await core.consumeConfirmed(h.issuer.context());
      expect(consumed.outcome, AttendanceOperationOutcome.consumed);
      expect(consumed.snapshot!.record.phase, JournalPhase.empty);
      expect(h.record!.revision, 4);
      expect(h.record!.command, isNull);
      expect(h.transport.calls, hasLength(1));
      expect(firstReceipt, isNotEmpty);
      final active = await core.readActive(h.issuer.context(), query);
      expect(active.outcome, AttendanceOperationOutcome.ready);
      expect(active.snapshot!.canonicalSession!.isActive, isTrue);
      final out = journalCommand(
        operation: AttendanceCommandKind.checkOut,
        key: 'fictional-checkout-key',
      );
      h.canonical.result = WorkSession.fromJson(journalReceipt(out));
      expect(
        (await core.submit(h.issuer.context(), out)).outcome,
        AttendanceOperationOutcome.confirmed,
      );
      expect(h.record!.revision, 7);
      expect(
        (await core.consumeConfirmed(h.issuer.context())).outcome,
        AttendanceOperationOutcome.consumed,
      );
      expect(h.record!.revision, 8);
      query.result = null;
      expect(
        (await core.readActive(
          h.issuer.context(),
          query,
        )).snapshot!.canonicalSession,
        isNull,
      );
      expect(h.transport.calls, hasLength(2));
    },
  );

  for (final phase in [
    JournalPhase.prepared,
    JournalPhase.mayHaveSent,
    JournalPhase.uncertain,
    JournalPhase.blocked,
  ]) {
    test('$phase is never consumed or overwritten', () async {
      h.inject(recordAt(phase));
      final before = h.disk.snapshot(h.binding);
      final result = await core.consumeConfirmed(h.issuer.context());
      expect(result.outcome, isNot(AttendanceOperationOutcome.consumed));
      expect(h.disk.snapshot(h.binding), before);
      expect(h.storage.attempts, isEmpty);
      expect(h.canonical.calls, isEmpty);
    });
  }
  for (final pending in [true, false]) {
    test('legacy migration, cleanup pending=$pending remains gated', () async {
      var record = migrationRecord(h.binding, confirmed: true);
      if (!pending) {
        record = record.markLegacyCleanupComplete(
          record.migration!.sourceSha256,
        );
      }
      h.inject(record);
      final result = await core.consumeConfirmed(h.issuer.context());
      expect(result.outcome, AttendanceOperationOutcome.gated);
      expect(h.storage.attempts, isEmpty);
    });
  }

  test('replacement needs confirmed barrier, then its own canonical read before consumption', () async {
    await confirm();
    core = replacement();
    expect(
      (await core.consumeConfirmed(h.issuer.context())).problem,
      AttendanceOperationProblem.recoveryRequired,
    );
    final bytes = h.disk.snapshot(h.binding);
    expect(
      (await core.recoverConfirmed(h.issuer.context())).outcome,
      AttendanceOperationOutcome.confirmed,
    );
    expect(verifier.records.single, bytes);
    final canonicalBefore = h.canonical.calls.length;
    expect(
      (await core.consumeConfirmed(h.issuer.context())).outcome,
      AttendanceOperationOutcome.consumed,
    );
    expect(h.canonical.calls.length, canonicalBefore + 1);
  });

  for (final response in ['null', 'wrong-id', 'failure']) {
    test('canonical $response retains complete receipt and command', () async {
      await confirm();
      final before = h.disk.snapshot(h.binding);
      if (response == 'null') h.canonical.result = null;
      if (response == 'wrong-id') {
        h.canonical.result = WorkSession(
          id: journalOtherId,
          locationContext: 'factory',
          lifecycleStatus: 'active',
          startedAt: journalTime,
        );
      }
      if (response == 'failure') {
        h.canonical.onRead = () async => throw StateError('fictional');
      }
      final result = await core.consumeConfirmed(h.issuer.context());
      expect(result.outcome, AttendanceOperationOutcome.confirmedNeedsRefresh);
      expect(h.disk.snapshot(h.binding), before);
    });
  }

  for (final fault in [
    JournalFault.beforeWrite,
    JournalFault.afterWrite,
    JournalFault.readback,
  ]) {
    test(
      'compaction $fault never grants readiness by a plain reread or replacement',
      () async {
        await confirm();
        h.storage.faults[JournalPhase.empty] = fault;
        final result = await core.consumeConfirmed(h.issuer.context());
        expect(result.problem, AttendanceOperationProblem.consumptionUncertain);
        expect(result.snapshot, isNull);
        expect(
          (await core.readActive(h.issuer.context(), query)).outcome,
          AttendanceOperationOutcome.unresolved,
        );
        expect(query.calls, 0);
        if (fault == JournalFault.beforeWrite) {
          expect(h.record!.phase, JournalPhase.confirmed);
          expect(
            (await core.consumeConfirmed(h.issuer.context())).problem,
            AttendanceOperationProblem.recoveryRequired,
          );
          await core.recoverConfirmed(h.issuer.context());
          expect(
            (await core.consumeConfirmed(h.issuer.context())).outcome,
            AttendanceOperationOutcome.consumed,
          );
        } else {
          expect(h.record!.phase, JournalPhase.empty);
          expect(
            (await core.submit(
              h.issuer.context(),
              journalCommand(key: 'fictional-new-key'),
            )).problem,
            AttendanceOperationProblem.emptyRecoveryRequired,
          );
          final fresh = replacement();
          expect(
            (await fresh.readActive(h.issuer.context(), query)).problem,
            AttendanceOperationProblem.emptyRecoveryRequired,
          );
          expect(
            (await fresh.submit(
              h.issuer.context(),
              journalCommand(key: 'fictional-new-key'),
            )).problem,
            AttendanceOperationProblem.emptyRecoveryRequired,
          );
          final emptyBytes = h.disk.snapshot(h.binding);
          final recovered = await fresh.recoverEmpty(h.issuer.context());
          expect(recovered.outcome, AttendanceOperationOutcome.emptyVerified);
          expect(verifier.records.last, emptyBytes);
          expect(query.calls, 0);
          expect(
            (await fresh.readActive(h.issuer.context(), query)).outcome,
            AttendanceOperationOutcome.ready,
          );
        }
      },
    );
  }

  test(
    'post-CAS read failure is unresolved even though CAS succeeded',
    () async {
      await confirm();
      h.storage.afterCas = (record) async {
        if (record.phase == JournalPhase.empty) {
          h.disk.failNext(JournalFault.beforeRead);
        }
      };
      expect(
        (await core.consumeConfirmed(h.issuer.context())).problem,
        AttendanceOperationProblem.consumptionUncertain,
      );
      expect(h.record!.phase, JournalPhase.empty);
      expect(
        (await core.readActive(h.issuer.context(), query)).problem,
        AttendanceOperationProblem.emptyRecoveryRequired,
      );
      expect(
        (await core.recoverEmpty(h.issuer.context())).outcome,
        AttendanceOperationOutcome.emptyVerified,
      );
    },
  );

  for (final issue in [
    JournalIssue.synchronizationFailure,
    JournalIssue.missingKey,
    JournalIssue.authenticationFailed,
    JournalIssue.revisionConflict,
  ]) {
    test(
      'empty verification $issue blocks all new commands and selection',
      () async {
        await confirm();
        h.storage.faults[JournalPhase.empty] = JournalFault.afterWrite;
        await core.consumeConfirmed(h.issuer.context());
        verifier.issue = issue;
        final emptyBytes = h.disk.snapshot(h.binding);
        expect(
          (await core.recoverEmpty(h.issuer.context())).journalIssue,
          issue,
        );
        expect(
          (await core.readActive(h.issuer.context(), query)).problem,
          AttendanceOperationProblem.emptyRecoveryRequired,
        );
        expect(h.disk.snapshot(h.binding), emptyBytes);
        expect(query.calls, 0);
        expect(h.transport.calls, hasLength(1));
      },
    );
  }

  test(
    'missing verifier cannot establish an uncertain/restarted empty state',
    () async {
      await confirm();
      await core.consumeConfirmed(h.issuer.context());
      final without = h.newCoordinator();
      expect(
        (await without.recoverEmpty(h.issuer.context())).problem,
        AttendanceOperationProblem.emptyRecoveryRequired,
      );
      expect(
        (await without.readActive(h.issuer.context(), query)).problem,
        AttendanceOperationProblem.emptyRecoveryRequired,
      );
    },
  );

  test('empty bytes changed during verification are not proof, even at higher revision', () async {
    await confirm();
    h.storage.faults[JournalPhase.empty] = JournalFault.afterWrite;
    await core.consumeConfirmed(h.issuer.context());
    final empty = h.record!;
    verifier.during = () async => h.inject(
      JournalRecord.fromJson({
        ...empty.toJson(),
        'revision': empty.revision + 1,
      }),
    );
    expect(
      (await core.recoverEmpty(h.issuer.context())).problem,
      AttendanceOperationProblem.consumptionUncertain,
    );
    verifier.during = null;
    expect(
      (await core.recoverEmpty(h.issuer.context())).problem,
      AttendanceOperationProblem.commandConflict,
    );
    expect(query.calls, 0);
  });

  for (final afterWrite in [false, true]) {
    test(
      'record changes ${afterWrite ? "after" : "before"} compaction cannot release wrong intent',
      () async {
        await confirm();
        final original = h.record!;
        if (afterWrite) {
          h.storage.afterCas = (record) async {
            if (record.phase == JournalPhase.empty) {
              h.inject(
                record.prepare(journalCommand(key: 'fictional-concurrent-key')),
              );
            }
          };
        } else {
          h.canonical.onRead = () async {
            h.inject(
              JournalRecord.fromJson({
                ...original.toJson(),
                'revision': original.revision + 1,
              }),
            );
            return journalSession();
          };
        }
        expect(
          (await core.consumeConfirmed(h.issuer.context())).problem,
          AttendanceOperationProblem.consumptionUncertain,
        );
        expect(h.record!.revision, 5 - (afterWrite ? 0 : 1));
        if (afterWrite) {
          expect(h.record!.command!.key, 'fictional-concurrent-key');
        } else {
          expect(
            h.record!.confirmation!.dataJson,
            original.confirmation!.dataJson,
          );
        }
        expect(h.transport.calls, hasLength(1));
      },
    );
  }

  for (final timing in ['before', 'canonical', 'write', 'verifier']) {
    test('auth invalidation at $timing never publishes readiness', () async {
      await confirm();
      final context = h.issuer.context();
      if (timing == 'before') h.issuer.relogin();
      if (timing == 'canonical') {
        h.canonical.onRead = () async {
          h.issuer.relogin();
          return journalSession();
        };
      }
      if (timing == 'write') {
        h.storage.afterCas = (record) async {
          if (record.phase == JournalPhase.empty) h.issuer.relogin();
        };
      }
      AttendanceOperationResult result;
      if (timing == 'verifier') {
        h.storage.faults[JournalPhase.empty] = JournalFault.afterWrite;
        await core.consumeConfirmed(h.issuer.context());
        verifier.during = () async => h.issuer.relogin();
        result = await core.recoverEmpty(context);
      } else {
        result = await core.consumeConfirmed(context);
      }
      expect(result.outcome, AttendanceOperationOutcome.invalidated);
      expect(result.snapshot, isNull);
      expect(context.releaseCalls, 1);
      expect(query.calls, 0);
    });
  }

  test(
    'stale outcomes mask even a previously successful consumed result',
    () async {
      await confirm();
      final result = await core.consumeConfirmed(h.issuer.context());
      h.issuer.relogin(asBinding: journalBinding(profile: journalOtherId));
      expect(result.outcome, AttendanceOperationOutcome.invalidated);
      expect(result.snapshot, isNull);
    },
  );

  test('overlapping consumption and submission are serialized across core instances', () async {
    await confirm();
    final entered = Completer<void>();
    final finish = Completer<void>();
    h.canonical.onRead = () async {
      entered.complete();
      await finish.future;
      return journalSession();
    };
    final consuming = core.consumeConfirmed(h.issuer.context());
    await entered.future;
    final secondContext = h.issuer.context();
    final second = replacement().submit(
      secondContext,
      journalCommand(key: 'fictional-queued-key'),
    );
    try {
      await pumpEventQueue();
      expect(h.record!.phase, JournalPhase.confirmed);
      expect(secondContext.releaseCalls, 0);
    } finally {
      finish.complete();
    }
    expect((await consuming).outcome, AttendanceOperationOutcome.consumed);
    expect(
      (await second).problem,
      AttendanceOperationProblem.emptyRecoveryRequired,
    );
    expect(h.record!.phase, JournalPhase.empty);
  });

  test(
    'selection uses fresh query, never the acknowledged active state',
    () async {
      await confirm();
      await core.consumeConfirmed(h.issuer.context());
      query.result = WorkSession(
        id: journalOtherId,
        locationContext: 'external_worksite',
        lifecycleStatus: 'active',
        startedAt: journalTime,
      );
      final result = await core.readActive(h.issuer.context(), query);
      expect(result.snapshot!.canonicalSession!.id, journalOtherId);
    },
  );

  test('outbox mutation during active SELECT hides stale data', () async {
    await confirm();
    await core.consumeConfirmed(h.issuer.context());
    query.during = () async {
      h.inject(h.record!.prepare(journalCommand(key: 'fictional-next-key')));
      return journalSession();
    };
    final result = await core.readActive(h.issuer.context(), query);
    expect(result.problem, AttendanceOperationProblem.journalUnavailable);
    expect(result.snapshot, isNull);
  });
}
