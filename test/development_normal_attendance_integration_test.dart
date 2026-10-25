import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/integration/development_attendance_authority.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'normal_attendance_integration_test.dart' as fixture;
import 'support/development_enrollment_fixture.dart';
import 'support/journal_fixtures.dart';
import 'support/attendance_auth_backend.dart';
import 'support/session_note_fixture.dart';

void main() {
  late fixture.Harness h;
  late FictionalDevelopmentEnrollment enrollment;
  setUp(() {
    h = fixture.Harness();
    enrollment = FictionalDevelopmentEnrollment();
  });
  tearDown(() => h.close());
  Future<void> start({
    bool approved = true,
    bool namespace = true,
    String? key,
  }) async {
    enrollment.approved = approved;
    await h.start(
      development: true,
      publicKey: key ?? fictionalOperatorPublicKey,
      enrollment: enrollment,
      namespace: namespace,
    );
  }

  void noAction() {
    expect(h.location.calls, 0);
    expect(h.operations.disk.writes, 0);
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(h.composition.owner?.outstandingAttempts ?? 0, 0);
  }

  for (final key in ['', 'invalid', 'A' * 600]) {
    test(
      'missing/malformed independent anchor denies (${key.length})',
      () async {
        await start(key: key);
        await h.workflow.refresh();
        await h.workflow.checkIn();
        expect(h.workflow.canCheckIn, false);
        expect(enrollment.calls, 0);
        noAction();
      },
    );
  }
  test(
    'missing independent epoch does not touch enrollment/GPS/HTTP',
    () async {
      await start(namespace: false);
      await h.workflow.refresh();
      await h.workflow.checkIn();
      expect(enrollment.calls, 0);
      expect(h.requests, isEmpty);
      noAction();
    },
  );
  test(
    'configured verifier cannot self-enroll or authorize without approval',
    () async {
      await start(approved: false);
      await h.workflow.refresh();
      await h.workflow.checkIn();
      expect(
        h.composition.guard.cutover,
        isA<DevelopmentAttendanceAuthority>(),
      );
      expect(h.workflow.canCheckIn, false);
      expect(h.requests, isEmpty);
      noAction();
    },
  );
  for (final reason in ['gate1', 'wrongEpoch', 'unavailable']) {
    test(
      '$reason denies before any enriched read, GPS, journal or POST',
      () async {
        await start();
        if (reason == 'gate1') h.capabilityGate = 1;
        if (reason == 'wrongEpoch') h.capabilityEpoch = journalOtherId;
        if (reason == 'unavailable') h.capabilityStatus = 503;
        await h.workflow.refresh();
        await h.workflow.checkIn();
        expect(h.workflow.canCheckIn, false);
        expect(
          h.requests.every(
            (r) => r.url.path.endsWith('/attendance_capability'),
          ),
          true,
        );
        noAction();
      },
    );
  }
  for (final intent in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace('  Réparation terminée.  '),
  ]) {
    test(
      'real development authority bootstraps and settles ${intent.action.name} checkout',
      () async {
        await start();
        h.operations.inject(
          JournalRecord.fromJson({
            ...JournalRecord.absent(journalBinding()).toJson(),
            'revision': 1,
          }),
        );
        await h.workflow.refresh();
        expect(h.workflow.canCheckIn, false);
        expect(
          h.workflow.state.recovery,
          AttendanceRecoveryAction.recoverEmpty,
        );
        await h.workflow.recover();
        expect(h.workflow.canCheckIn, true);
        final checks = enrollment.calls;
        await h.workflow.checkIn(siteDescription: '  Chantier à Montréal  ');
        expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        expect(enrollment.calls, greaterThanOrEqualTo(checks + 6));
        final entry = h.operations.record!;
        expect(
          h.requests.firstWhere((r) => r.method == 'POST').body,
          entry.command!.parametersJson,
        );
        expect(entry.confirmation, isNotNull);
        await h.workflow.consume();
        expect(h.workflow.canCheckOut, true);
        await h.workflow.checkOut(note: intent);
        expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        final command = h.operations.record!.command!;
        expect(command.parameters['p_note_action'], intent.action.name);
        expect(command.parameters['p_employee_note'], intent.text);
        expect(
          h.requests.lastWhere((r) => r.method == 'POST').body,
          command.parametersJson,
        );
        expect(h.location.calls, 2);
        expect(h.composition.owner!.outstandingAttempts, 0);
      },
    );
  }
  test(
    'revoked durable approval before tap prevents GPS or journal creation',
    () async {
      await start();
      await h.workflow.refresh();
      expect(h.workflow.canCheckIn, true);
      enrollment.approved = false;
      await h.workflow.checkIn();
      noAction();
    },
  );
  test(
    'revocation across capability await is caught by final native verification',
    () async {
      await start();
      enrollment.onVerify = (count) async {
        if (count == 2) enrollment.approved = false;
      };
      await h.workflow.refresh();
      await h.workflow.checkIn();
      noAction();
    },
  );
  test('critical pre-POST revocation retains frozen uncertain intent, sends nothing', () async {
    await start();
    await h.workflow.refresh();
    h.operations.storage.afterCas = (record) async {
      if (record.phase == JournalPhase.mayHaveSent) enrollment.approved = false;
    };
    await h.workflow.checkIn();
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(h.operations.record!.command, isNotNull);
    expect(h.operations.record!.phase, JournalPhase.mayHaveSent);
    expect(h.operations.record!.writeMayHaveStarted, true);
    expect(h.composition.owner!.outstandingAttempts, 0);
  });
  for (final source in ['legacy', 'sidecar', 'unreadable']) {
    test('$source evidence blocks before approval or dispatch', () async {
      await start();
      if (source == 'legacy') {
        h.source = LegacySourceSnapshot.file(
          basename: 'fictional.json',
          bytes: [1],
        );
      }
      if (source == 'sidecar') {
        h.source = LegacySourceSnapshot.absent(
          artifacts: {LegacySourceArtifact.temporary},
        );
      }
      if (source == 'unreadable') h.inspectionFails = true;
      await h.workflow.refresh();
      await h.workflow.checkIn();
      expect(enrollment.calls, 0);
      noAction();
    });
  }
  test(
    'pending original command is preserved without fresh GPS/key/POST',
    () async {
      await start();
      final record = JournalRecord.absent(journalBinding())
          .prepare(journalCommand())
          .markMayHaveSent()
          .markUncertain();
      h.operations.inject(record);
      final before = JournalCodec.encode(record);
      await h.workflow.refresh();
      await h.workflow.checkIn();
      expect(JournalCodec.encode(h.operations.record!), before);
      noAction();
      expect(h.workflow.canRecover, true);
    },
  );
  test(
    'lost response recovers exact original key/body via replay only',
    () async {
      await start();
      await h.workflow.refresh();
      h.loseReply = true;
      await h.workflow.checkIn(siteDescription: 'Intention conservée');
      final original = h.operations.record!.command!;
      h.loseReply = false;
      await h.workflow.recover();
      expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
      final posts = h.requests.where((r) => r.method == 'POST').toList();
      expect(posts.length, 2);
      expect(
        jsonDecode(posts.last.body),
        original.rpcParameters(replayOnly: true),
      );
      expect(
        h.operations.record!.command!.parametersJson,
        original.parametersJson,
      );
    },
  );
  for (final change in [
    'logout',
    'relogin',
    'account',
    'authorization',
    'epoch',
  ]) {
    test(
      '$change suppresses stale approval and never retargets command',
      () async {
        await start();
        await h.workflow.refresh();
        if (change == 'logout') await h.auth.controller.signOut();
        if (change == 'relogin') await h.auth.login();
        if (change == 'account') {
          h.auth.account = journalOtherId;
          await h.auth.login();
        }
        if (change == 'authorization') {
          h.auth.disabled = true;
          await h.auth.controller.revalidateOnResume();
        }
        if (change == 'epoch') h.capabilityEpoch = journalOtherId;
        await turn();
        await h.workflow.checkIn();
        noAction();
      },
    );
  }
  test('logout after submission persists original receipt without stale canonical refresh', () async {
    await start();
    await h.workflow.refresh();
    h.responseGate = Completer<void>();
    h.submitted = Completer<void>();
    final action = h.workflow.checkIn();
    await h.submitted!.future;
    final original = h.operations.record!.command!;
    await h.auth.controller.signOut();
    h.responseGate!.complete();
    await action;
    expect(h.operations.record!.phase, JournalPhase.confirmed);
    expect(
      h.operations.record!.command!.parametersJson,
      original.parametersJson,
    );
    expect(
      h.requests.where((r) => r.url.path.endsWith('/work_sessions')),
      isEmpty,
    );
    expect(h.composition.owner!.outstandingAttempts, 0);
  });
  for (final terminal in [false, true]) {
    test(
      'retained note terminal=$terminal blocks real authority without changing evidence',
      () async {
        await start();
        h.active = true;
        final context = h.composition.owner!.issueContext();
        final command = SessionNoteCommand.capture(
          identity: context.identity,
          sessionId: journalSessionId,
          operationKey: 'fictional-retained-note',
          note: const CheckoutNoteIntent.replace('Texte conservé'),
        );
        var record = SessionNoteRecord.absent(journalBinding())
            .prepare(command);
        if (terminal) {
          record = record.confirm(
            SessionNoteReceipt.parse(
              jsonEncode(noteReceiptJson(command)),
              command,
            ),
          );
        }
        h.notes.disk.records[journalBinding().storageIdentity] = record.bytes;
        await context.release();
        await h.workflow.refresh();
        await h.workflow.checkOut();
        expect(enrollment.calls, 0);
        expect(h.requests, isEmpty);
        noAction();
        expect(
          h.notes.disk.records[journalBinding().storageIdentity],
          record.bytes,
        );
      },
    );
  }
  test('epoch rotation preserves original uncertain command and prevents even replay POST', () async {
    await start();
    await h.workflow.refresh();
    h.loseReply = true;
    await h.workflow.checkIn();
    final retained = JournalCodec.encode(h.operations.record!);
    final sent = h.requests.where((r) => r.method == 'POST').length;
    h.capabilityEpoch = journalOtherId;
    h.loseReply = false;
    await h.workflow.recover();
    expect(h.requests.where((r) => r.method == 'POST').length, sent);
    expect(JournalCodec.encode(h.operations.record!), retained);
    expect(h.location.calls, 1);
    expect(h.composition.owner!.outstandingAttempts, 0);
  });
  test(
    'logout during enrollment acquisition cannot enable a stale screen',
    () async {
      await start();
      final entered = Completer<void>();
      final release = Completer<void>();
      enrollment.onVerify = (count) async {
        if (count == 1) {
          entered.complete();
          await release.future;
        }
      };
      final loading = h.workflow.refresh();
      await entered.future;
      await h.auth.controller.signOut();
      release.complete();
      await loading;
      await h.workflow.checkIn();
      expect(h.workflow.canCheckIn, false);
      noAction();
    },
  );
  test('cold composition re-verifies enrollment and restores original uncertain operation', () async {
    await start();
    await h.workflow.refresh();
    h.loseReply = true;
    await h.workflow.checkIn();
    final retained = h.operations.record!;
    final calls = enrollment.calls;
    await h.close();
    h = fixture.Harness();
    h.operations.inject(retained);
    h.active = true;
    await start();
    await h.workflow.refresh();
    expect(enrollment.calls, greaterThan(calls));
    expect(h.workflow.canCheckIn, false);
    expect(h.location.calls, 0);
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
    await h.workflow.recover();
    expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    expect(
      jsonDecode(h.requests.singleWhere((r) => r.method == 'POST').body),
      retained.command!.rpcParameters(replayOnly: true),
    );
  });
}
