// Fictional auth/HTTP/storage simulations; no external accounts or note data.
import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:chantipoint/src/ui/employee_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'normal_attendance_integration_test.dart' show Harness;
import 'support/journal_fixtures.dart';

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() async {
    if (h.responseGate != null && !h.responseGate!.isCompleted) {
      h.responseGate!.complete();
    }
    await h.close();
  });
  Future<void> start() async {
    await h.start();
    h.active = true;
    await h.workflow.refresh();
    expect(h.workflow.canSaveNote, true);
  }

  SessionNoteRecord record() => SessionNoteRecord.decode(
    h.notes.disk.records[journalBinding().storageIdentity]!,
    journalBinding(),
  );

  test(
    'create edit empty and explicit clear preserve exact values; no GPS',
    () async {
      await start();
      for (final value in ['  e\u0301 😀  ', 'second', '']) {
        await h.workflow.saveNote(value);
        expect(h.note, value);
        expect(h.workflow.state.session!.employeeNote, value);
        expect(h.workflow.state.noteSaveConfirmed, true);
        expect(h.workflow.canSaveNote, true);
      }
      expect(h.noteReceipts.length, 3);
      await h.workflow.clearNote();
      expect(h.note, null);
      expect(h.workflow.state.session!.employeeNote, null);
      expect(h.noteReceipts.length, 4);
      expect(h.location.calls, 0);
      expect(h.operations.record, null);
      expect(record().command!.contractVersion, 2);
      expect(
        h.requests
            .where((r) => r.method == 'POST')
            .every(
              (r) =>
                  r.url.path.endsWith('/save_employee_note_v2') &&
                  r.headers['x-chantipoint-attendance-epoch'] ==
                      journalBinding().environmentId,
            ),
        true,
      );
    },
  );

  test(
    'Unicode code point limit and invalid text fail before persistence',
    () async {
      await start();
      await h.workflow.saveNote('😀' * 1000);
      expect(h.note!.runes.length, 1000);
      final bytes = List<int>.of(record().bytes);
      for (final value in [
        '😀' * 1001,
        '\u0000',
        String.fromCharCode(0xd800),
      ]) {
        await h.workflow.saveNote(value);
        expect(h.workflow.state.status, EmployeeAttendanceStatus.invalidInput);
        expect(record().bytes, bytes);
      }
      expect(h.noteReceipts.length, 1);
    },
  );

  for (final intent in [
    const CheckoutNoteIntent.preserve(),
    CheckoutNoteIntent.replace('final'),
    const CheckoutNoteIntent.clear(),
  ]) {
    test(
      'Save then checkout ${intent.action.name} settles lease before consumption',
      () async {
        await start();
        await h.workflow.saveNote('saved');
        await h.workflow.checkOut(note: intent);
        expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        expect(h.note, switch (intent.action) {
          CheckoutNoteAction.preserve => 'saved',
          CheckoutNoteAction.replace => 'final',
          CheckoutNoteAction.clear => null,
        });
        expect(record().phase, SessionNotePhase.terminal);
        await h.workflow.consume();
        expect(h.operations.record!.phase, JournalPhase.empty);
        expect(h.workflow.canCheckIn, true);
      },
    );
  }

  test(
    'lost Save acknowledgement restart uses original key and replay only',
    () async {
      await start();
      h.loseReply = true;
      await h.workflow.saveNote('pending');
      final original = record().command!;
      expect(h.workflow.state.recovery, AttendanceRecoveryAction.recoverNote);
      expect(h.workflow.canCheckOut, false);
      h.workflow.dispose();
      h.workflow = h.composition.createWorkflow(h.auth.controller.state.user!);
      await h.workflow.refresh();
      expect(h.workflow.canSaveNote, false);
      expect(record().command!.same(original), true);
      h.loseReply = false;
      await h.workflow.recover();
      expect(h.workflow.state.noteSaveConfirmed, true);
      expect(h.noteReceipts.length, 1);
      final posts = h.requests.where((r) => r.method == 'POST').toList();
      expect(posts.length, 2);
      final replay = jsonDecode(posts.last.body) as Map;
      expect(replay['p_operation_key'], original.key);
      expect(replay['p_replay_only'], true);
      expect(record().command!.parametersJson, original.parametersJson);
      expect(h.location.calls, 0);
    },
  );

  test(
    'restart confirmed note reads proof and canonical without another POST',
    () async {
      await start();
      await h.workflow.saveNote('settled');
      h.workflow.dispose();
      h.workflow = h.composition.createWorkflow(h.auth.controller.state.user!);
      await h.workflow.refresh();
      expect(h.workflow.canSaveNote, true);
      expect(h.requests.where((r) => r.method == 'POST').length, 1);
    },
  );

  for (final next in ['save', 'checkout']) {
    test(
      'cold composition pending recovery restores selection and empty proof before $next',
      () async {
        await h.start();
        await h.workflow.refresh();
        await h.workflow.checkIn();
        await h.workflow.consume();
        expect(h.operations.record!.phase, JournalPhase.empty);
        h.loseReply = true;
        await h.workflow.saveNote('pending');
        final original = record().command!;
        await h.composition.close();
        await h.start();
        await h.workflow.refresh();
        expect(h.workflow.state.recovery, AttendanceRecoveryAction.recoverNote);
        h.loseReply = false;
        await h.workflow.recover();
        expect(record().command!.same(original), true);
        if (next == 'save') {
          await h.workflow.saveNote('next');
          expect(h.noteReceipts.length, 2);
          expect(h.workflow.state.noteSaveConfirmed, true);
        } else {
          await h.workflow.checkOut();
          expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
          expect(record().phase, SessionNotePhase.terminal);
        }
        expect(h.composition.owner!.outstandingAttempts, 0);
      },
    );
  }

  test('Save in flight excludes checkout and repeated Save', () async {
    await start();
    h.submitted = Completer<void>();
    h.responseGate = Completer<void>();
    final saving = h.workflow.saveNote('one');
    await h.submitted!.future;
    await h.workflow.checkOut();
    await h.workflow.saveNote('two');
    expect(h.location.calls, 0);
    expect(h.requests.where((r) => r.method == 'POST').length, 1);
    h.responseGate!.complete();
    await saving;
    expect(h.note, 'one');
  });

  test(
    'checkout lost reply restart recovers matching lease then consumes',
    () async {
      await start();
      await h.workflow.saveNote('saved');
      h.loseReply = true;
      await h.workflow.checkOut();
      expect(record().phase, SessionNotePhase.checkout);
      final frozen = h.operations.record!.command!;
      h.workflow.dispose();
      h.workflow = h.composition.createWorkflow(h.auth.controller.state.user!);
      await h.workflow.refresh();
      expect(
        h.workflow.state.recovery,
        AttendanceRecoveryAction.recoverCheckout,
      );
      h.loseReply = false;
      await h.workflow.recover();
      expect(h.workflow.canConsume, true);
      expect(record().phase, SessionNotePhase.terminal);
      expect(h.operations.record!.command!.key, frozen.key);
      await h.workflow.consume();
      expect(h.workflow.canCheckIn, true);
    },
  );

  test(
    'logout during Save persists late proof without publishing success',
    () async {
      await start();
      h.submitted = Completer<void>();
      h.responseGate = Completer<void>();
      final saving = h.workflow.saveNote('one');
      await h.submitted!.future;
      await h.auth.controller.signOut();
      h.responseGate!.complete();
      await saving;
      expect(record().phase, SessionNotePhase.terminal);
      expect(
        h.workflow.state.status,
        EmployeeAttendanceStatus.authorizationUnavailable,
      );
      expect(h.workflow.state.noteSaveConfirmed, false);
      expect(h.composition.owner!.outstandingAttempts, 0);
    },
  );

  test('checkout reservation without attendance proof stays preserved and offers checkout review', () async {
    await start();
    final before = SessionNoteRecord.absent(journalBinding());
    final lease = before.reserveCheckout(
      SessionNoteCheckout(
        sessionId: journalSessionId,
        key: 'fictional-orphan-checkout',
        generation: 1,
        commandSha256: 'a' * 64,
      ),
    );
    await h.notes.compareAndSwap(before, lease);
    await h.workflow.refresh();
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(
        h.workflow.state.recovery,
        AttendanceRecoveryAction.recoverCheckout,
      );
      expect(h.workflow.canSaveNote, false);
      expect(h.workflow.canConsume, false);
      await h.workflow.recover();
      expect(record().bytes, lease.bytes);
    }
    expect(h.workflow.state.recovery, AttendanceRecoveryAction.recoverCheckout);
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('checkout reservation without attendance proof stays preserved and offers checkout review', () async {
    await start();
    final before = SessionNoteRecord.absent(journalBinding());
    final lease = before.reserveCheckout(
      SessionNoteCheckout(
        sessionId: journalSessionId,
        key: 'fictional-orphan-checkout',
        generation: 1,
        commandSha256: 'a' * 64,
      ),
    );
    await h.notes.compareAndSwap(before, lease);
    await h.workflow.refresh();
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(
        h.workflow.state.recovery,
        AttendanceRecoveryAction.recoverCheckout,
      );
      expect(h.workflow.canSaveNote, false);
      expect(h.workflow.canConsume, false);
      await h.workflow.recover();
      expect(record().bytes, lease.bytes);
    }
    expect(h.workflow.state.recovery, AttendanceRecoveryAction.recoverCheckout);
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('gate 1 wrong epoch or unapproved cutover denies before POST', () async {
    await start();
    for (final issue in ['gate', 'epoch', 'approval']) {
      h.capabilityGate = issue == 'gate' ? 1 : 2;
      h.capabilityEpoch = issue == 'epoch' ? journalOtherId : null;
      h.approval.approved = issue != 'approval';
      await h.workflow.refresh();
      await h.workflow.saveNote('blocked');
      expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
    }
    expect(h.location.calls, 0);
  });

  testWidgets(
    'French note editor separates draft and saved value, saves and clears',
    (tester) async {
      await tester.runAsync(start);
      await tester.pumpWidget(
        MaterialApp(home: EmployeeAttendanceScreen(workflow: h.workflow)),
      );
      await tester.runAsync(() => h.workflow.settled);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('active-session-note')),
        '  draft  ',
      );
      await tester.pump();
      expect(find.text('Brouillon non enregistré.'), findsOneWidget);
      expect(h.note, null);
      await tester.tap(find.text('Enregistrer la note'));
      await tester.runAsync(() => h.workflow.settled);
      await tester.pumpAndSettle();
      expect(h.note, '  draft  ');
      expect(find.text('Note enregistrée :   draft  '), findsOneWidget);
      await tester.tap(find.text('Effacer la note enregistrée'));
      await tester.runAsync(() => h.workflow.settled);
      await tester.pumpAndSettle();
      expect(h.note, null);
      expect(find.text('Aucune note enregistrée.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
