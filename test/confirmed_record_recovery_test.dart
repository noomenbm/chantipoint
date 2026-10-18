import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance_operation_ports.dart';
import 'support/journal_fixtures.dart';
import 'support/memory_journal_storage.dart';

class _Verifier implements JournalVerifier {
  int calls = 0;
  Future<JournalIssue?> Function(JournalBinding, List<int>)? onVerify;
  @override
  Future<JournalIssue?> verify(
    JournalBinding binding,
    List<int> expectedRecord,
  ) async {
    calls++;
    return await onVerify?.call(binding, expectedRecord);
  }
}

void main() {
  late FictionalAttendanceOperations h;
  late _Verifier verifier;
  late AttendanceOperationCoordinator coordinator;
  final original = recordAt(JournalPhase.confirmed);
  setUp(() {
    h = FictionalAttendanceOperations()..inject(original);
    verifier = _Verifier();
    coordinator = AttendanceOperationCoordinator(
      storage: h.storage,
      transport: h.transport,
      canonical: h.canonical,
      verifier: verifier,
    );
  });
  tearDown(() {
    // Recovery never submits attendance or mutates storage, including on errors.
    expect(h.transport.calls, isEmpty);
    expect(h.storage.attempts, isEmpty);
  });

  test(
    'replacement requires explicit barrier, complete bytes, original receipt',
    () async {
      expect(
        (await coordinator.refresh(h.issuer.context())).problem,
        AttendanceOperationProblem.recoveryRequired,
      );
      verifier.onVerify = (binding, bytes) async {
        expect(binding.matches(original.binding), isTrue);
        expect(bytes, JournalCodec.encode(original));
        expect(() => bytes[0] = 0, throwsUnsupportedError);
        expect(h.canonical.calls, isEmpty);
        return null;
      };
      final result = await coordinator.recoverConfirmed(h.issuer.context());
      expect(result.outcome, AttendanceOperationOutcome.confirmed);
      expect(
        result.snapshot!.record.confirmation!.dataJson,
        original.confirmation!.dataJson,
      );
      expect(verifier.calls, 1);
      expect(h.canonical.calls.single.sessionId, journalSessionId);
      expect(h.disk.snapshot(h.binding), JournalCodec.encode(original));
      expect(
        (await h.newCoordinator().refresh(h.issuer.context())).problem,
        AttendanceOperationProblem.recoveryRequired,
      );
    },
  );

  test('missing verifier never grants proof', () async {
    final result = await h.coordinator.recoverConfirmed(h.issuer.context());
    expect(result.problem, AttendanceOperationProblem.recoveryRequired);
    expect(h.canonical.calls, isEmpty);
  });

  for (final issue in [
    JournalIssue.synchronizationFailure,
    JournalIssue.authenticationFailed,
    JournalIssue.missingKey,
    JournalIssue.unreadable,
    JournalIssue.revisionConflict,
  ]) {
    test('barrier $issue blocks snapshot and canonical', () async {
      verifier.onVerify = (_, _) async => issue;
      final result = await coordinator.recoverConfirmed(h.issuer.context());
      expect(result.outcome, AttendanceOperationOutcome.unresolved);
      expect(result.journalIssue, issue);
      expect(result.snapshot, isNull);
      expect(h.canonical.calls, isEmpty);
      expect(h.disk.snapshot(h.binding), JournalCodec.encode(original));
    });
  }

  test('throwing verifier fails closed', () async {
    verifier.onVerify = (_, _) async => throw StateError('fictional');
    expect(
      (await coordinator.recoverConfirmed(h.issuer.context())).journalIssue,
      JournalIssue.nativeFailure,
    );
    expect(h.canonical.calls, isEmpty);
  });

  for (final field in [
    'revision',
    'command',
    'confirmation',
    'migration',
    'lexical',
  ]) {
    test('changed complete record during verification: $field', () async {
      verifier.onVerify = (_, _) async {
        final map = original.toJson();
        switch (field) {
          case 'revision':
            map['revision'] = original.revision + 1;
          case 'command':
            final command = journalCommand(key: 'fictional-changed-command');
            map['command'] = command.toJson();
          case 'confirmation':
            map['confirmation'] = {
              ...map['confirmation'] as Map,
              'data_json': ' ${original.confirmation!.dataJson}',
            };
          case 'migration':
            map['migration'] = legacyApproval(legacySource()).metadata
                .completed()
                .toJson();
          case 'lexical':
            h.disk.inject(h.binding, [32, ...JournalCodec.encode(original)]);
            return null;
        }
        final changed = utf8.encode(JournalJson.encode(map));
        expect(JournalCodec.decode(changed, h.binding).issue, isNull);
        h.disk.inject(h.binding, changed);
        return null;
      };
      final result = await coordinator.recoverConfirmed(h.issuer.context());
      expect(result.outcome, AttendanceOperationOutcome.unresolved);
      expect(result.snapshot, isNull);
      expect(h.canonical.calls, isEmpty);
    });
  }

  for (final state in [
    'missing',
    'corrupt',
    'wrong binding',
    'prepared',
    'mayHaveSent',
    'uncertain',
    'blocked',
    'legacy',
    'migration',
  ]) {
    test('$state gated before verifier', () async {
      if (state == 'missing') {
        h = FictionalAttendanceOperations();
      } else if (state == 'corrupt') {
        h.disk.inject(h.binding, [123]);
      } else if (state == 'wrong binding') {
        h.disk.inject(
          h.binding,
          utf8.encode(
            JournalJson.encode({
              ...original.toJson(),
              'binding': journalBinding(environment: 'other').toJson(),
            }),
          ),
        );
      } else if (state == 'legacy') {
        h.inject(
          recordAt(
            JournalPhase.confirmed,
            command: journalCommand(protocol: JournalProtocol.legacyV1),
          ),
        );
      } else if (state == 'migration') {
        h.inject(
          JournalRecord.fromJson({
            ...recordAt(
              JournalPhase.confirmed,
              command: journalCommand(protocol: JournalProtocol.legacyV1),
            ).toJson(),
            'migration': legacyApproval(legacySource()).metadata.toJson(),
          }),
        );
      } else {
        h.inject(recordAt(JournalPhase.values.byName(state)));
      }
      coordinator = AttendanceOperationCoordinator(
        storage: h.storage,
        transport: h.transport,
        canonical: h.canonical,
        verifier: verifier,
      );
      final result = await coordinator.recoverConfirmed(h.issuer.context());
      expect(result.snapshot, isNull);
      expect(verifier.calls, 0);
      expect(h.canonical.calls, isEmpty);
    });
  }

  for (final boundary in [
    'before',
    'read',
    'read throws',
    'barrier',
    'after read',
    'canonical',
  ]) {
    test('auth invalidation at $boundary', () async {
      final context = h.issuer.context();
      if (boundary == 'before') h.issuer.relogin();
      if (boundary == 'read') {
        h.storage.afterRead = () async => h.issuer.relogin();
      }
      if (boundary == 'read throws') {
        h.storage.afterRead = () async {
          h.issuer.relogin();
          throw StateError('fictional storage error');
        };
      }
      if (boundary == 'barrier') {
        verifier.onVerify = (_, _) async {
          h.issuer.relogin();
          return null;
        };
      }
      if (boundary == 'after read') {
        h.storage.afterRead = () async {
          if (h.storage.reads == 2) h.issuer.relogin();
        };
      }
      if (boundary == 'canonical') {
        h.canonical.onRead = () async {
          h.issuer.relogin();
          return journalSession();
        };
      }
      final result = await coordinator.recoverConfirmed(context);
      expect(result.outcome, AttendanceOperationOutcome.invalidated);
      expect(result.snapshot, isNull);
      expect(context.releaseCalls, 1);
      expect(h.canonical.calls.length, boundary == 'canonical' ? 1 : 0);
    });
  }

  test(
    'canonical failure retains receipt and proof for explicit refresh',
    () async {
      h.canonical.onRead = () async => throw StateError('fictional');
      final result = await coordinator.recoverConfirmed(h.issuer.context());
      expect(result.outcome, AttendanceOperationOutcome.confirmedNeedsRefresh);
      expect(
        JournalCodec.encode(result.snapshot!.record),
        JournalCodec.encode(original),
      );
      h.canonical.onRead = null;
      expect(
        (await coordinator.refresh(h.issuer.context())).outcome,
        AttendanceOperationOutcome.confirmed,
      );
      expect(verifier.calls, 1);
    },
  );

  test(
    'delayed barrier keeps context and binding queue through settlement',
    () async {
      final entered = Completer<void>();
      final finish = Completer<void>();
      verifier.onVerify = (_, _) async {
        entered.complete();
        await finish.future;
        return null;
      };
      final context = h.issuer.context();
      final first = coordinator.recoverConfirmed(context);
      await entered.future;
      final second = h.coordinator.refresh(h.issuer.context());
      expect(context.released, isFalse);
      expect(
        (await coordinator.recoverConfirmed(context)).problem,
        AttendanceOperationProblem.contextUnavailable,
      );
      h.issuer.relogin();
      finish.complete();
      expect((await first).outcome, AttendanceOperationOutcome.invalidated);
      expect((await second).outcome, AttendanceOperationOutcome.invalidated);
      expect(context.releaseCalls, 1);
      expect(h.canonical.calls, isEmpty);
    },
  );

  test(
    'reported confirmation CAS failure after commit requires fresh barrier',
    () async {
      // Separate fixture: this test alone submits once BEFORE recovery.
      final initial = FictionalAttendanceOperations();
      initial.storage.faults[JournalPhase.confirmed] = JournalFault.afterWrite;
      expect(
        (await initial.coordinator.submit(
          initial.issuer.context(),
          journalCommand(),
        )).problem,
        AttendanceOperationProblem.persistenceUncertain,
      );
      expect(initial.record!.phase, JournalPhase.confirmed);
      final replacement = AttendanceOperationCoordinator(
        storage: initial.storage,
        transport: initial.transport,
        canonical: initial.canonical,
        verifier: verifier,
      );
      final frozen = initial.disk.snapshot(initial.binding);
      final writes = initial.disk.writes;
      expect(
        (await replacement.recoverConfirmed(initial.issuer.context())).outcome,
        AttendanceOperationOutcome.confirmed,
      );
      expect(initial.transport.calls.length, 1);
      expect(initial.disk.writes, writes);
      expect(initial.disk.snapshot(initial.binding), frozen);
      expect(verifier.calls, 1);
    },
  );
}
