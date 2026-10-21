import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/notes/session_note_coordinator.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/employee_workflow_fixture.dart';
import 'support/journal_fixtures.dart';
import 'support/session_note_fixture.dart';

void main() {
  late SessionNoteFixture f;
  setUp(() => f = SessionNoteFixture());
  tearDown(() => f.close());
  test('durable pending before HTTP; terminal proof before canonical; current note from SELECT', () async {
    f.beforeResponse = (_) async {
      expect(f.record!.phase, SessionNotePhase.pending);
      expect(f.store.events, contains('verify:pending'));
    };
    f.operations.canonical.onRead = () async {
      expect(f.record!.phase, SessionNotePhase.terminal);
      expect(f.store.events, contains('verify:terminal'));
      return workflowSession(note: 'Valeur canonique différente');
    };
    final result = await f.save();
    expect(result.outcome, NoteOperationOutcome.applied);
    expect(result.session!.employeeNote, 'Valeur canonique différente');
    expect(f.requests.single.body, f.command().parametersJson);
    expect(f.contexts.single.releaseCalls, 1);
    expect(
      f.operations.disk.writes,
      0,
    ); // No note intent in attendance journal.
  });
  for (final after in [false, true]) {
    test(
      'lost reply ${after ? "after" : "before"} commit; restart always replay-only',
      () async {
        f.loseAfterCommit = after;
        f.loseBeforeCommit = !after;
        final original = f.command();
        expect(
          (await f.save(original)).outcome,
          NoteOperationOutcome.uncertain,
        );
        final originalBytes = f.record!.command!.parametersJson;
        final restarted = f.newCoordinator(storage: NoteMemoryStorage(f.disk));
        f.operations.issuer.relogin(); // Stored generation remains 1; new authorization only replays.
        final result = await restarted.recover(f.context());
        expect(
          result.outcome,
          after
              ? NoteOperationOutcome.applied
              : NoteOperationOutcome.notApplied,
        );
        expect(jsonDecode(f.requests.last.body)['p_replay_only'], true);
        expect(f.record!.command!.parametersJson, originalBytes);
        expect(f.record!.command!.identity.generation, 1);
        if (!after) {
          // A delayed original after the replay fence cannot apply (server simulation).
          await f.client.post(
            Uri.parse(
              '${f.operations.binding.baseUrl}/rest/v1/rpc/save_employee_note',
            ),
            body: original.parametersJson,
          );
          expect(f.serverNotes, isEmpty);
        }
        expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
      },
    );
  }
  for (final phase in [SessionNotePhase.pending, SessionNotePhase.terminal]) {
    for (final stage in ['before', 'after', 'verify']) {
      test(
        '$stage persistence failure at ${phase.name} never falsely releases note gate',
        () async {
          f.store.fail(stage, phase);
          final result = await f.save();
          expect(result.outcome, NoteOperationOutcome.uncertain);
          if (phase == SessionNotePhase.pending) expect(f.requests, isEmpty);
          if (f.record != null) {
            final again = f.newCoordinator(storage: NoteMemoryStorage(f.disk));
            final recovered = await again.recover(f.context());
            expect(
              recovered.outcome,
              phase == SessionNotePhase.pending
                  ? NoteOperationOutcome.notApplied
                  : NoteOperationOutcome.applied,
            );
          }
          expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
        },
      );
    }
  }
  test('pending operation blocks another key and checkout across coordinator replacement', () async {
    f.loseAfterCommit = true;
    await f.save();
    final again = f.newCoordinator(storage: NoteMemoryStorage(f.disk));
    expect(
      (await again.save(
        f.context(),
        f.command(key: 'new-note-operation'),
      )).outcome,
      NoteOperationOutcome.blocked,
    );
    expect(
      (await again.checkOut(
        f.context(),
        journalCommand(operation: AttendanceCommandKind.checkOut),
      )).outcome,
      NoteOperationOutcome.blocked,
    );
    expect(f.requests, hasLength(1));
    expect(f.operations.transport.calls, isEmpty);
  });
  test(
    'same-key double tap uses one HTTP attempt; changed text conflicts locally',
    () async {
      final command = f.command();
      final results = await Future.wait([
        f.coordinator.save(f.context(), command),
        f.coordinator.save(f.context(), command),
      ]);
      expect(
        results.every((r) => r.outcome == NoteOperationOutcome.applied),
        isTrue,
      );
      expect(f.requests, hasLength(1));
      expect(
        (await f.save(f.command(text: 'Changed under same key'))).problem,
        NoteOperationProblem.conflict,
      );
      expect(f.requests, hasLength(1));
    },
  );
  test(
    'another note can replace terminal only after current canonical read',
    () async {
      await f.save();
      f.operations.canonical.onRead = () async =>
          throw StateError('fictional offline');
      expect(
        (await f.save(f.command(key: 'second-note-key'))).outcome,
        NoteOperationOutcome.terminalNeedsRefresh,
      );
      expect(f.requests, hasLength(1));
      f.operations.canonical.onRead = null;
      expect(
        (await f.save(f.command(key: 'second-note-key'))).outcome,
        NoteOperationOutcome.applied,
      );
      expect(f.requests, hasLength(2));
    },
  );
  test('late response persists original receipt after logout, without stale SELECT', () async {
    final submitted = Completer<void>(), response = Completer<void>();
    f.beforeResponse = (_) async {
      submitted.complete();
      await response.future;
    };
    final context = f.context();
    final future = f.coordinator.save(context, f.command());
    await submitted.future;
    f.operations.issuer.relogin();
    expect(context.releaseCalls, 0);
    response.complete();
    final result = await future;
    expect(result.outcome, NoteOperationOutcome.invalidated);
    expect(result.receipt, isNull);
    expect(result.session, isNull);
    expect(f.record!.phase, SessionNotePhase.terminal);
    expect(f.operations.canonical.calls, isEmpty);
    expect(context.releaseCalls, 1);
  });
  test(
    'caller timeout does not cancel response work or release ownership/gate',
    () async {
      final submitted = Completer<void>(), response = Completer<void>();
      f.beforeResponse = (_) async {
        submitted.complete();
        await response.future;
      };
      final ctx = f.context();
      final work = f.coordinator.save(ctx, f.command());
      await submitted.future;
      await expectLater(
        work.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      expect(ctx.releaseCalls, 0);
      expect(f.record!.phase, SessionNotePhase.pending);
      response.complete();
      expect((await work).outcome, NoteOperationOutcome.applied);
      expect(ctx.releaseCalls, 1);
    },
  );
  for (final binding in [
    journalBinding(environment: 'wrong-environment'),
    journalBinding(profile: journalOtherId),
  ]) {
    test('wrong environment/owner evidence fails closed', () async {
      f.disk.records[f.operations.binding.storageIdentity] =
          SessionNoteRecord.absent(binding)
              .prepare(
                SessionNoteCommand.capture(
                  identity: AttendanceOperationIdentity(binding, 1),
                  sessionId: journalSessionId,
                  operationKey: 'wrong-owner-note-key',
                  note: const CheckoutNoteIntent.replace('private fixture'),
                ),
              )
              .bytes;
      expect((await f.save()).outcome, NoteOperationOutcome.uncertain);
      expect(f.requests, isEmpty);
    });
  }
  test(
    'missing/corrupt known storage never becomes a fresh operation',
    () async {
      await f.save();
      f.disk.records.remove(f.operations.binding.storageIdentity);
      expect(
        (await f.newCoordinator().save(
          f.context(),
          f.command(key: 'after-disappearance'),
        )).outcome,
        NoteOperationOutcome.uncertain,
      );
      expect(f.requests, hasLength(1));
    },
  );
  test(
    'authorization changes during canonical read suppress stale publication',
    () async {
      f.operations.canonical.onRead = () async {
        f.operations.issuer.relogin();
        return workflowSession();
      };
      final result = await f.save();
      expect(result.outcome, NoteOperationOutcome.invalidated);
      expect(result.session, isNull);
      expect(f.record!.phase, SessionNotePhase.terminal);
    },
  );
  test(
    'parent checkout ownership spans C3 child and native reservation cleanup',
    () async {
      f.operations.canonical.result = workflowSession(closed: true);
      final parent = f.context();
      final cleanup = Completer<void>(), started = Completer<void>();
      f.store.afterCas = (r) async {
        if (r.phase == SessionNotePhase.empty) {
          started.complete();
          await cleanup.future;
        }
      };
      final future = f.coordinator.checkOut(
        parent,
        journalCommand(operation: AttendanceCommandKind.checkOut),
      );
      await started.future;
      expect(parent.releaseCalls, 0);
      expect(f.contexts, hasLength(2));
      expect(f.contexts.last.releaseCalls, 1);
      cleanup.complete();
      expect((await future).outcome, NoteOperationOutcome.checkoutFinished);
      expect(parent.releaseCalls, 1);
      expect(f.record!.phase, SessionNotePhase.empty);
    },
  );
  test(
    'checkout first blocks note send until attendance confirmation is consumed',
    () async {
      final reply = Completer<AttendanceTransportReply>(),
          submitted = Completer<void>();
      f.operations.transport.onDispatch = (command, _) async {
        submitted.complete();
        return reply.future;
      };
      f.operations.canonical.result = workflowSession(closed: true);
      final command = journalCommand(operation: AttendanceCommandKind.checkOut);
      final checkout = f.coordinator.checkOut(f.context(), command);
      await submitted.future;
      expect(f.record!.phase, SessionNotePhase.checkout);
      final save = f.coordinator.save(f.context(), f.command());
      reply.complete(
        AttendanceTransportReply.acknowledged(
          JournalJson.encode(journalReceipt(command)),
        ),
      );
      expect((await checkout).outcome, NoteOperationOutcome.checkoutFinished);
      expect((await save).problem, NoteOperationProblem.attendancePending);
      expect(f.requests, isEmpty);
    },
  );
  test('uncertain checkout survives restart; approved C3 replay clears reservation', () async {
    f.operations.transport.onDispatch = (_, _) async =>
        throw StateError('fixture disconnect');
    final command = journalCommand(operation: AttendanceCommandKind.checkOut);
    await f.coordinator.checkOut(f.context(), command);
    expect(f.record!.phase, SessionNotePhase.checkout);
    expect(f.operations.record!.phase, JournalPhase.mayHaveSent);
    f.operations.transport.onDispatch = null;
    f.operations.canonical.result = workflowSession(closed: true);
    final result = await f.newCoordinator().recoverCheckout(f.context());
    expect(result.outcome, NoteOperationOutcome.checkoutFinished);
    expect(f.operations.transport.calls.last.replayOnly, isTrue);
    expect(f.record!.phase, SessionNotePhase.empty);
  });
  for (final phase in [SessionNotePhase.checkout, SessionNotePhase.empty]) {
    for (final stage in ['before', 'after', 'verify']) {
      test(
        '$stage failure at checkout ${phase.name} keeps evidence through restart',
        () async {
          f.operations.canonical.result = workflowSession(closed: true);
          f.store.fail(stage, phase);
          final command = journalCommand(
            operation: AttendanceCommandKind.checkOut,
          );
          expect(
            (await f.coordinator.checkOut(f.context(), command)).outcome,
            NoteOperationOutcome.uncertain,
          );
          if (phase == SessionNotePhase.checkout) {
            expect(f.operations.transport.calls, isEmpty);
            if (f.record != null) {
              expect(
                (await f.newCoordinator().recoverCheckout(f.context())).outcome,
                NoteOperationOutcome.blocked,
              );
            }
          } else if (f.record!.phase == SessionNotePhase.checkout) {
            expect(
              (await f.newCoordinator().recoverCheckout(f.context())).outcome,
              NoteOperationOutcome.checkoutFinished,
            );
          } else {
            expect(f.record!.phase, SessionNotePhase.empty);
            expect(f.operations.record!.phase, JournalPhase.confirmed);
            expect(
              (await f.save()).problem,
              NoteOperationProblem.attendancePending,
            );
          }
        },
      );
    }
  }
  test('invalidation after durable pending write sends nothing; explicit recovery fences', () async {
    f.store.afterCas = (record) async {
      if (record.phase == SessionNotePhase.pending) {
        f.operations.issuer.relogin();
      }
    };
    expect((await f.save()).outcome, NoteOperationOutcome.invalidated);
    expect(f.requests, isEmpty);
    f.store.afterCas = null;
    expect(
      (await f.newCoordinator().recover(f.context())).outcome,
      NoteOperationOutcome.notApplied,
    );
    expect(jsonDecode(f.requests.single.body)['p_replay_only'], true);
  });
  test(
    'same context reused while HTTP outstanding cannot release its owner early',
    () async {
      final submitted = Completer<void>(), response = Completer<void>();
      f.beforeResponse = (_) async {
        submitted.complete();
        await response.future;
      };
      final context = f.context(), command = f.command();
      final work = f.coordinator.save(context, command);
      await submitted.future;
      expect(
        (await f.coordinator.save(context, command)).outcome,
        NoteOperationOutcome.blocked,
      );
      expect(context.releaseCalls, 0);
      response.complete();
      await work;
      expect(context.releaseCalls, 1);
      expect(f.requests, hasLength(1));
    },
  );
  test('server changed-payload conflict retains pending key, never substitutes intent', () async {
    final command = f.command();
    f.server[command.key] = (
      parameters: 'another frozen payload',
      receipt: '{}',
    );
    expect((await f.save(command)).outcome, NoteOperationOutcome.uncertain);
    expect(
      (await f.newCoordinator().recover(f.context())).outcome,
      NoteOperationOutcome.uncertain,
    );
    expect(f.record!.command!.parametersJson, command.parametersJson);
    expect(
      (await f.save(f.command(key: 'replacement-key-unsafe'))).outcome,
      NoteOperationOutcome.blocked,
    );
    expect(f.requests, hasLength(2));
  });
  test(
    'checkout recovery requires COMPLETE original command fingerprint',
    () async {
      final original = journalCommand(
        operation: AttendanceCommandKind.checkOut,
      );
      final changed = journalCommand(
        operation: AttendanceCommandKind.checkOut,
        note: const CheckoutNoteIntent.replace(
          'Changed final note under same key',
        ),
      );
      final lease = SessionNoteRecord.absent(f.operations.binding)
          .reserveCheckout(
            SessionNoteCheckout(
              sessionId: journalSessionId,
              key: original.key,
              generation: 1,
              commandSha256: SessionNoteCheckout.fingerprint(original),
            ),
          );
      f.disk.records[f.operations.binding.storageIdentity] = lease.bytes;
      f.operations.inject(
        JournalRecord.absent(f.operations.binding)
            .prepare(changed)
            .markMayHaveSent(),
      );
      expect(
        (await f.coordinator.recoverCheckout(f.context())).outcome,
        NoteOperationOutcome.blocked,
      );
      expect(f.operations.transport.calls, isEmpty);
    },
  );
  test('logout after checkout submission retains receipt and reservation for fresh recovery', () async {
    final submitted = Completer<void>(),
        response = Completer<AttendanceTransportReply>();
    f.operations.transport.onDispatch = (_, _) async {
      submitted.complete();
      return response.future;
    };
    final command = journalCommand(operation: AttendanceCommandKind.checkOut);
    final parent = f.context();
    final checkout = f.coordinator.checkOut(parent, command);
    await submitted.future;
    f.operations.issuer.relogin();
    expect(parent.releaseCalls, 0);
    response.complete(
      AttendanceTransportReply.acknowledged(
        JournalJson.encode(journalReceipt(command)),
      ),
    );
    expect((await checkout).outcome, NoteOperationOutcome.invalidated);
    expect(f.record!.phase, SessionNotePhase.checkout);
    expect(f.operations.record!.phase, JournalPhase.confirmed);
    expect(f.operations.canonical.calls, isEmpty);
    f.operations.canonical.result = workflowSession(closed: true);
    expect(
      (await f.newCoordinator().recoverCheckout(f.context())).outcome,
      NoteOperationOutcome.checkoutFinished,
    );
    expect(f.operations.transport.calls, hasLength(1));
    expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
  });
  test(
    'checkout reservation with missing attendance evidence remains blocked',
    () async {
      final lease = SessionNoteRecord.absent(f.operations.binding)
          .reserveCheckout(
            SessionNoteCheckout(
              sessionId: journalSessionId,
              key: journalKey,
              generation: 1,
              commandSha256: 'b' * 64,
            ),
          );
      f.disk.records[f.operations.binding.storageIdentity] = lease.bytes;
      expect(
        (await f.coordinator.recoverCheckout(f.context())).outcome,
        NoteOperationOutcome.blocked,
      );
      expect(f.operations.transport.calls, isEmpty);
      expect(f.requests, isEmpty);
    },
  );
}
