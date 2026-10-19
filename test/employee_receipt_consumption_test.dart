import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:chantipoint/src/ui/employee_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/employee_workflow_fixture.dart';
import 'support/memory_journal_storage.dart';

class _Barrier implements JournalVerifier {
  JournalIssue? issue;
  int calls = 0;
  @override
  Future<JournalIssue?> verify(JournalBinding binding, List<int> record) async {
    calls++;
    return issue;
  }
}

void main() {
  late EmployeeWorkflowFixture f;
  late _Barrier barrier;
  setUp(() {
    barrier = _Barrier();
    f = EmployeeWorkflowFixture(verifier: barrier);
  });
  tearDown(() => f.workflow.dispose());
  Future<void> checkIn() async {
    await f.workflow.refresh();
    await f.workflow.checkIn();
    expect(f.workflow.canConsume, isTrue);
    // Change the fictional server answer, not the observed session revision.
    // Only the subsequent owner-scoped SELECT establishes the active selection.
    f.active.result = workflowSession();
    f.active.currentId = f.active.result!.id;
  }

  test('complete isolated check-in/consume/checkout/consume cycle uses fresh active SELECTs', () async {
    await checkIn();
    final reads = f.active.calls.length;
    await f.workflow.consume();
    expect(f.operations.record!.revision, 4);
    expect(f.active.calls.length, reads + 1);
    expect(f.workflow.canCheckOut, isTrue);
    expect(f.workflow.canCheckIn, isFalse);
    f.operations.canonical.result = workflowSession(closed: true);
    await f.workflow.checkOut();
    expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    expect(f.operations.record!.revision, 7);
    f.active.result = null;
    f.active.currentId = null;
    await f.workflow.consume();
    expect(f.operations.record!.revision, 8);
    expect(f.workflow.canCheckIn, isTrue);
    expect(f.workflow.canCheckOut, isFalse);
    expect(f.operations.transport.calls, hasLength(2));
    expect(f.keys.calls, 2);
    expect(f.location.calls, 2);
    expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
  });

  for (final fault in [
    JournalFault.beforeWrite,
    JournalFault.afterWrite,
    JournalFault.readback,
  ]) {
    test(
      'cleanup $fault blocks new commands until explicit safe recovery',
      () async {
        await checkIn();
        f.operations.storage.faults[JournalPhase.empty] = fault;
        await f.workflow.consume();
        expect(
          f.workflow.state.status,
          EmployeeAttendanceStatus.consumptionUnresolved,
        );
        expect(f.workflow.canCheckIn, isFalse);
        expect(f.workflow.canCheckOut, isFalse);
        final keys = f.keys.calls;
        await f.workflow.checkIn();
        await f.workflow.checkOut();
        expect(f.keys.calls, keys);
        await f.workflow.refresh();
        if (fault == JournalFault.beforeWrite) {
          expect(
            f.workflow.state.recovery,
            AttendanceRecoveryAction.recoverConfirmed,
          );
          await f.workflow.recover();
          expect(f.workflow.canConsume, isTrue);
          await f.workflow.consume();
        } else {
          expect(
            f.workflow.state.status,
            EmployeeAttendanceStatus.consumptionUnresolved,
          );
          expect(
            f.workflow.state.recovery,
            AttendanceRecoveryAction.recoverEmpty,
          );
          await f.workflow.recover();
        }
        expect(f.workflow.canCheckOut, isTrue);
        expect(barrier.calls, 1);
        expect(f.operations.transport.calls, hasLength(1));
      },
    );
  }

  test('verifier failure keeps empty-readable cleanup unresolved', () async {
    await checkIn();
    f.operations.storage.faults[JournalPhase.empty] = JournalFault.afterWrite;
    await f.workflow.consume();
    await f.workflow.refresh();
    barrier.issue = JournalIssue.synchronizationFailure;
    await f.workflow.recover();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.consumptionUnresolved,
    );
    expect(f.workflow.canCheckOut, isFalse);
    expect(f.operations.record!.phase, JournalPhase.empty);
    barrier.issue = null;
    await f.workflow.refresh();
    await f.workflow.recover();
    expect(f.workflow.canCheckOut, isTrue);
  });

  test('replacement workflow/core must recover empty state before selecting active session', () async {
    await checkIn();
    await f.workflow.consume();
    f.workflow.dispose();
    final other = EmployeeAttendanceWorkflow(
      issueContext: f.operations.issuer.context,
      authorizationChanges: f.changes,
      activeSessions: f.active,
      capture:
          f.capture, // No action in this replacement/recovery-only fixture.
      coordinator: AttendanceOperationCoordinator(
        storage: f.operations.storage,
        transport: f.operations.transport,
        canonical: f.operations.canonical,
        verifier: barrier,
      ),
    );
    addTearDown(other.dispose);
    final reads = f.active.calls.length;
    await other.refresh();
    expect(other.state.recovery, AttendanceRecoveryAction.recoverEmpty);
    expect(f.active.calls.length, reads);
    await other.recover();
    expect(other.canCheckOut, isTrue);
    expect(barrier.calls, 1);
    expect(f.active.calls.length, reads + 1);
  });

  test('recovered confirmed record still requires explicit consumption and new active read', () async {
    await checkIn();
    final receipt = f.operations.record!;
    final otherCore = AttendanceOperationCoordinator(
      storage: f.operations.storage,
      transport: f.operations.transport,
      canonical: f.operations.canonical,
      verifier: barrier,
    );
    final recovered = await otherCore.recoverConfirmed(
      f.operations.issuer.context(),
    );
    expect(recovered.outcome, AttendanceOperationOutcome.confirmed);
    expect(
      f.operations.record!.confirmation!.dataJson,
      receipt.confirmation!.dataJson,
    );
    await otherCore.consumeConfirmed(f.operations.issuer.context());
    expect(f.operations.record!.phase, JournalPhase.empty);
    expect(f.operations.transport.calls, hasLength(1));
  });

  test(
    'failed active refresh after consumption cannot infer no active session',
    () async {
      await checkIn();
      f.active.onRead = () async => throw StateError('fictional');
      await f.workflow.consume();
      expect(f.operations.record!.phase, JournalPhase.empty);
      expect(
        f.workflow.state.status,
        EmployeeAttendanceStatus.refreshUnavailable,
      );
      expect(f.workflow.canCheckIn, isFalse);
      expect(f.workflow.canCheckOut, isFalse);
      f.active.onRead = null;
      await f.workflow.refresh();
      expect(f.workflow.canCheckOut, isTrue);
    },
  );

  for (final mode in ['logout', 'same-user', 'account', 'session', 'dispose']) {
    test(
      '$mode during consumption suppresses stale access and does not release early',
      () async {
        await checkIn();
        final entered = Completer<void>();
        final finish = Completer<void>();
        f.operations.canonical.onRead = () async {
          entered.complete();
          await finish.future;
          return workflowSession();
        };
        final reads = f.active.calls.length;
        final work = f.workflow.consume();
        await entered.future;
        final context = f.contexts.last;
        try {
          await f.workflow.consume();
          await f.workflow.checkOut();
          await f.workflow.refresh();
          expect(context.releaseCalls, 0);
          if (mode == 'dispose') {
            f.workflow.dispose();
          } else if (mode == 'session') {
            f.setActive(
              workflowSession(id: '00000000-0000-4000-8000-000000000099'),
            );
          } else {
            if (mode == 'logout') f.authorized = false;
            if (mode == 'account') {
              f.operations.issuer.relogin(
                asBinding: JournalBinding(
                  environmentId: f.operations.binding.environmentId,
                  baseUrl: f.operations.binding.baseUrl,
                  authUserId: '00000000-0000-4000-8000-000000000099',
                  companyId: f.operations.binding.companyId,
                  profileId: f.operations.binding.profileId,
                ),
              );
              f.changes.changed();
            } else {
              f.invalidate();
            }
          }
          expect(context.releaseCalls, 0);
        } finally {
          finish.complete();
        }
        await work;
        expect(context.releaseCalls, 1);
        expect(f.active.calls.length, reads);
        expect(f.workflow.canCheckOut, isFalse);
        expect(f.operations.transport.calls, hasLength(1));
        if (mode == 'dispose' || mode == 'session') {
          // Authorized, already-started coordinator work may consume; UI stays detached/stale.
          expect(f.operations.record!.phase, JournalPhase.empty);
        } else {
          expect(f.operations.record!.phase, JournalPhase.confirmed);
        }
      },
    );
  }

  test('same-user relogin during issuance does not adopt a newer consumption context', () async {
    await checkIn();
    f.beforeIssue = () => f.invalidate(notify: false);
    await f.workflow.consume();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.authorizationUnavailable,
    );
    expect(f.operations.record!.phase, JournalPhase.confirmed);
    expect(f.contexts.last.releaseCalls, 1);
  });

  test(
    'known session change during final active read hides stale selection',
    () async {
      await checkIn();
      f.active.onRead = () async {
        f.setActive(
          workflowSession(id: '00000000-0000-4000-8000-000000000099'),
        );
        return workflowSession();
      };
      await f.workflow.consume();
      expect(
        f.workflow.state.status,
        EmployeeAttendanceStatus.refreshUnavailable,
      );
      expect(f.workflow.state.session, isNull);
      expect(f.workflow.canCheckOut, isFalse);
    },
  );

  Future<void> press(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'French screen completes full cycle with explicit verification controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: EmployeeAttendanceScreen(workflow: f.workflow)),
      );
      await tester.pumpAndSettle();
      await press(tester, 'Pointer une entrée');
      expect(find.text('Terminer la vérification'), findsOneWidget);
      expect(f.workflow.canCheckOut, isFalse);
      f.active.result = workflowSession();
      f.active.currentId = f.active.result!.id;
      await press(tester, 'Terminer la vérification');
      expect(f.workflow.canCheckOut, isTrue);
      expect(find.text('Terminer la vérification'), findsNothing);
      f.operations.canonical.result = workflowSession(closed: true);
      await press(tester, 'Pointer une sortie');
      expect(find.text('Session terminée'), findsOneWidget);
      f.active.result = null;
      f.active.currentId = null;
      await press(tester, 'Terminer la vérification');
      expect(find.text('Aucune session active.'), findsOneWidget);
      expect(f.workflow.canCheckIn, isTrue);
      expect(f.operations.record!.revision, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uncertain cleanup is French, gated and recoverable without attendance resend',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: EmployeeAttendanceScreen(workflow: f.workflow)),
      );
      await tester.pumpAndSettle();
      await press(tester, 'Pointer une entrée');
      f.active.result = workflowSession();
      f.active.currentId = f.active.result!.id;
      f.operations.storage.faults[JournalPhase.empty] = JournalFault.afterWrite;
      await press(tester, 'Terminer la vérification');
      expect(
        find.textContaining(
          'La vérification sur cet appareil reste incertaine',
        ),
        findsOneWidget,
      );
      expect(f.workflow.canCheckIn, isFalse);
      await press(tester, 'Actualiser le pointage');
      expect(
        find.text('Réessayer la vérification sur cet appareil'),
        findsOneWidget,
      );
      await press(tester, 'Réessayer la vérification sur cet appareil');
      expect(f.workflow.canCheckOut, isTrue);
      expect(f.operations.transport.calls, hasLength(1));
    },
  );
}
