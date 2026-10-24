// Fictional auth, HTTP, GPS and RAM storage only. No hosted requests.
import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/app.dart';
import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/integration/attendance_integration_guard.dart';
import 'package:chantipoint/src/attendance/integration/normal_attendance_composition.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:chantipoint/src/config/supabase_environment_config.dart';
import 'package:chantipoint/src/ui/employee_attendance_screen.dart';
import 'package:chantipoint/src/ui/factory_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/active_session_read_fixtures.dart';
import 'support/attendance_auth_backend.dart';
import 'support/fake_attendance_operation_ports.dart';
import 'support/fake_auth_repository.dart';
import 'support/fake_foreground_location.dart';
import 'support/journal_fixtures.dart';
import 'support/session_history_fixture.dart';
import 'support/session_note_fixture.dart';

class Approval implements AttendanceCutoverAuthority {
  bool approved = true;
  bool broken = false;
  @override
  bool isApproved(AttendanceOperationIdentity identity) {
    if (broken) throw StateError('private fixture');
    return approved;
  }
}

class Verifier implements JournalVerifier {
  @override
  Future<JournalIssue?> verify(JournalBinding binding, List<int> bytes) async =>
      null;
}

class Harness {
  final auth = AttendanceAuthBackend();
  final operations = FictionalAttendanceOperations();
  final notes = NoteMemoryStorage(NoteMemoryDisk());
  final location = FakeLocationAcquisition();
  final approval = Approval();
  LegacySourceSnapshot source = LegacySourceSnapshot.absent();
  bool inspectionFails = false;
  int inspections = 0;
  bool active = false, closed = false, loseReply = false;
  int readStatus = 200;
  String? description, note;
  final requests = <http.Request>[];
  Completer<void>? responseGate, submitted;
  bool clientClosed = false;
  late final client = _Client((request) async {
    requests.add(request);
    if (request.method == 'POST') {
      final command = operations.record!.command!;
      final p = jsonDecode(request.body) as Map<String, dynamic>;
      if (command.operation == AttendanceCommandKind.checkIn) {
        active = true;
        description = p['p_site_description'] as String?;
      } else {
        active = false;
        closed = true;
        if (p['p_note_action'] == 'replace') {
          note = p['p_employee_note'] as String?;
        }
        if (p['p_note_action'] == 'clear') note = null;
      }
      if (!(submitted?.isCompleted ?? true)) submitted!.complete();
      await responseGate?.future;
      if (loseReply) throw http.ClientException('private fixture');
      return http.Response(
        jsonEncode(journalReceipt(command, replay: p['p_replay_only'] == true)),
        200,
      );
    }
    if (readStatus != 200) return http.Response('private fixture', readStatus);
    final row = activeSessionRow()
      ..['location_context'] = 'factory'
      ..['review_status'] = 'normal'
      ..['started_at'] = '2026-10-15T14:00:00+00:00'
      ..['site_description'] = description
      ..['employee_note'] = note
      ..['lifecycle_status'] = closed ? 'closed_manual' : 'active'
      ..['ended_at'] = closed ? '2026-10-15T22:00:00+00:00' : null;
    if (projection == AttendanceSessionProjection.legacy) {
      row.remove('employee_note');
      row.remove('review_status');
    }
    return http.Response(
      jsonEncode(
        request.url.path.endsWith('/user_profiles')
            ? activeSelection(sessions: active ? [row] : [])
            : [row],
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }, () => clientClosed = true);
  late NormalAttendanceComposition composition;
  late EmployeeAttendanceWorkflow workflow;
  AttendanceSessionProjection projection = AttendanceSessionProjection.v2;
  Future<void> start({
    bool namespace = true,
    bool approved = true,
    AttendanceSessionProjection projection = AttendanceSessionProjection.v2,
  }) async {
    this.projection = projection;
    approval.approved = approved;
    composition = NormalAttendanceComposition(
      auth: auth.controller,
      repository: auth.repository,
      config: SupabaseEnvironmentConfig(
        missingValues: const [],
        keySource: 'SUPABASE_PUBLISHABLE_KEY',
        url: 'https://fixture.invalid',
        publishableKey: 'fictional-publishable-key',
        attendanceEnvironmentId: namespace
            ? journalBinding().environmentId
            : '',
      ),
      client: client,
      storage: operations.storage,
      verifier: Verifier(),
      notes: notes,
      inspectLegacy: (_) async {
        inspections++;
        if (inspectionFails) throw StateError('private fixture');
        return source;
      },
      locationFactory: () => location,
      cutover: approval,
      projection: projection,
    );
    await auth.login();
    workflow = composition.createWorkflow(auth.controller.state.user!);
    if (namespace) {
      expect(composition.guard.configurationMessage, null);
      final context = composition.owner!.issueContext();
      await context.release();
    }
  }

  Future<void> close() async {
    await composition.close();
    await auth.close();
  }
}

class _Client extends MockClient {
  _Client(super.fn, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.close());

  test('missing trusted deployment never guesses binding or touches storage/GPS/HTTP', () async {
    await h.start(namespace: false);
    await h.workflow.refresh();
    await h.workflow.checkIn(siteDescription: 'Fictionnel');
    expect(h.workflow.state.status, EmployeeAttendanceStatus.blocked);
    expect(h.inspections, 0);
    expect(h.operations.storage.reads, 0);
    expect(h.requests, isEmpty);
    expect(h.location.calls, 0);
    expect(h.operations.disk.writes, 0);
  });

  for (final broken in [false, true]) {
    test(
      'unapproved or failed capability never enables actions: broken=$broken',
      () async {
        await h.start(approved: false);
        h.approval.broken = broken;
        await h.workflow.refresh();
        expect(h.workflow.canCheckIn, false);
        await h.workflow.checkIn();
        expect(h.location.calls, 0);
        expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
        expect(h.operations.disk.writes, 0);
      },
    );
  }

  test('legacy projection reads canonical state without inventing unavailable note/review', () async {
    await h.start(projection: AttendanceSessionProjection.legacy);
    h.active = true;
    await h.workflow.refresh();
    expect(h.workflow.state.session!.id, journalSessionId);
    expect(h.workflow.state.session!.employeeNote, null);
    expect(h.workflow.noteDataAvailable, false);
    expect(h.workflow.canCheckOut, false);
    expect(
      h.requests.single.url.queryParameters['select'],
      isNot(contains('employee_note')),
    );
    expect(
      h.requests.single.url.queryParameters['select'],
      isNot(contains('review_status')),
    );
  });

  for (final status in [403, 400, 503]) {
    test(
      'schema/auth/backend error $status is not an empty active selection',
      () async {
        await h.start();
        h.readStatus = status;
        await h.workflow.refresh();
        expect(
          h.workflow.state.status,
          EmployeeAttendanceStatus.refreshUnavailable,
        );
        expect(h.workflow.canCheckIn, false);
      },
    );
  }

  for (final artifact in ['source', 'temporary', 'unreadable', 'exception']) {
    test(
      'preserves legacy $artifact and blocks all actions without guessing provenance',
      () async {
        await h.start();
        h.source = switch (artifact) {
          'source' => LegacySourceSnapshot.file(
            basename: 'attendance_fixture.json',
            bytes: legacySource(),
          ),
          'temporary' => LegacySourceSnapshot.absent(
            artifacts: {LegacySourceArtifact.temporary},
          ),
          'unreadable' => LegacySourceSnapshot.unreadable(),
          _ => LegacySourceSnapshot.absent(),
        };
        h.inspectionFails = artifact == 'exception';
        final digest = h.source.sourceSha256;
        await h.workflow.refresh();
        await h.workflow.checkIn();
        expect(h.workflow.state.status, EmployeeAttendanceStatus.blocked);
        expect(h.source.sourceSha256, digest);
        expect(h.requests, isEmpty);
        expect(h.location.calls, 0);
        expect(h.operations.disk.writes, 0);
        expect(h.composition.owner!.outstandingAttempts, 0);
      },
    );
  }

  for (final phase in [
    JournalPhase.prepared,
    JournalPhase.uncertain,
    JournalPhase.confirmed,
    JournalPhase.blocked,
  ]) {
    test(
      'unapproved v2 $phase remains byte-exact and cannot replay or consume',
      () async {
        await h.start(approved: false);
        h.operations.inject(recordAt(phase));
        final original = h.operations.disk.snapshot(journalBinding());
        await h.workflow.refresh();
        await h.workflow.recover();
        await h.workflow.consume();
        expect(h.operations.disk.snapshot(journalBinding()), original);
        expect(h.workflow.canCheckIn, false);
        expect(h.workflow.canRecover, false);
        expect(h.workflow.canConsume, false);
        expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
      },
    );
  }

  test(
    'retained legacy protocol in encrypted journal is not converted or sent',
    () async {
      await h.start();
      h.operations.inject(
        recordAt(
          JournalPhase.uncertain,
          command: journalCommand(protocol: JournalProtocol.legacyV1),
        ),
      );
      final before = h.operations.disk.snapshot(journalBinding());
      await h.workflow.refresh();
      await h.workflow.recover();
      expect(h.workflow.state.status, EmployeeAttendanceStatus.blocked);
      expect(h.operations.disk.snapshot(journalBinding()), before);
      expect(h.requests, isEmpty);
    },
  );

  test(
    'unreadable note storage fails closed without touching attendance',
    () async {
      await h.start();
      h.notes.disk.marked.add(journalBinding().storageIdentity);
      await h.workflow.refresh();
      expect(h.workflow.state.status, EmployeeAttendanceStatus.blocked);
      expect(h.requests, isEmpty);
      expect(h.operations.disk.writes, 0);
    },
  );

  for (final intent in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace('  Réparation terminée.  '),
  ]) {
    test(
      'approved fictional end-to-end preserves description and ${intent.action} final intent',
      () async {
        await h.start();
        await h.workflow.refresh();
        expect(h.workflow.canCheckIn, true);
        await h.workflow.checkIn(siteDescription: '  À Montréal  ');
        expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        final first = h.operations.record!;
        expect(
          h.requests.firstWhere((r) => r.method == 'POST').body,
          first.command!.parametersJson,
        );
        expect(
          first.confirmation!.dataJson,
          jsonEncode(journalReceipt(first.command!)),
        );
        expect(h.description, '  À Montréal  ');
        expect(h.workflow.canCheckOut, false);
        await h.workflow.consume();
        expect(h.workflow.canCheckOut, true);
        await h.workflow.checkOut(note: intent);
        expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        expect(h.workflow.state.session!.isActive, false);
        final last = h.operations.record!;
        expect(last.command!.rpc, 'check_out_v2');
        expect(last.command!.parameters['p_note_action'], intent.action.name);
        expect(last.command!.parameters['p_employee_note'], intent.text);
        expect(
          h.requests.lastWhere((r) => r.method == 'POST').body,
          last.command!.parametersJson,
        );
        expect(h.location.calls, 2);
        expect(h.composition.owner!.outstandingAttempts, 0);
      },
    );
  }

  test('lost response remains uncertain and explicit recovery sends only frozen replay', () async {
    await h.start();
    await h.workflow.refresh();
    h.loseReply = true;
    await h.workflow.checkIn(siteDescription: 'Description figée');
    expect(h.workflow.state.status, EmployeeAttendanceStatus.pending);
    final before = h.operations.record!.command!;
    h.loseReply = false;
    await h.workflow.recover();
    expect(h.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    final posts = h.requests.where((r) => r.method == 'POST').toList();
    expect(posts.length, 2);
    expect(jsonDecode(posts.last.body), before.rpcParameters(replayOnly: true));
    expect(h.operations.record!.command!.parametersJson, before.parametersJson);
  });

  test(
    'approval withdrawn while GPS awaits prevents journal preparation and POST',
    () async {
      await h.start();
      await h.workflow.refresh();
      h.location.onAcquire = () async {
        h.approval.approved = false;
        return h.location.evidence;
      };
      await h.workflow.checkIn();
      expect(h.workflow.state.status, EmployeeAttendanceStatus.blocked);
      expect(h.operations.disk.writes, 0);
      expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
      expect(h.composition.owner!.outstandingAttempts, 0);
    },
  );

  for (final change in ['logout', 'relogin', 'account', 'revoked']) {
    test(
      'auth $change suppresses stale actions and releases ownership',
      () async {
        await h.start();
        await h.workflow.refresh();
        if (change == 'logout') {
          await h.auth.controller.signOut();
        }
        if (change == 'relogin') {
          await h.auth.login();
        }
        if (change == 'account') {
          h.auth.account = journalOtherId;
          await h.auth.login();
        }
        if (change == 'revoked') {
          h.auth.disabled = true;
          await h.auth.controller.revalidateOnResume();
        }
        await turn();
        await h.workflow.checkIn();
        expect(h.workflow.canCheckIn, false);
        expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
        expect(h.composition.owner!.outstandingAttempts, 0);
      },
    );
  }

  test('app close drains submitted work and persists late receipt without stale refresh', () async {
    await h.start();
    await h.workflow.refresh();
    h.responseGate = Completer<void>();
    h.submitted = Completer<void>();
    final action = h.workflow.checkIn();
    await h.submitted!.future;
    final closing = h.composition.close();
    await turn();
    expect(h.clientClosed, false);
    expect(h.composition.owner!.outstandingAttempts, 1);
    h.responseGate!.complete();
    await action;
    await closing;
    expect(h.operations.record!.phase, JournalPhase.confirmed);
    expect(h.clientClosed, true);
    expect(
      h.requests.where((r) => r.url.path.endsWith('/work_sessions')),
      isEmpty,
    );
    expect(h.composition.owner!.outstandingAttempts, 0);
  });

  testWidgets(
    'normal home composes guarded C5, History and sign-out without legacy writer',
    (tester) async {
      await tester.runAsync(() => h.start(namespace: false));
      final history = FakeHistoryRepository();
      // Widget clock uses the existing UI auth fixture. Real SDK generation,
      // logout and late receipts are exercised above outside FakeAsync.
      final uiRepository = FakeAuthRepository(
        restoredUser: h.auth.controller.state.user!,
      );
      final uiAuth = AuthController(uiRepository);
      await tester.pumpWidget(
        ChantiPointApp(
          authController: uiAuth,
          employeeWorkflowFactory: h.composition.createWorkflow,
          historyRepositoryFactory: (_, _) => history,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeAttendanceScreen), findsOneWidget);
      expect(find.byType(FactoryAttendanceScreen), findsNothing);
      expect(find.textContaining('configuration de déploiement'), findsWidgets);
      expect(h.location.calls, 0);
      expect(h.requests, isEmpty);
      await tester.tap(find.text('Historique'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Vos sessions des six derniers mois, selon l’heure de Montréal.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Se déconnecter'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(uiAuth.state.status, AuthStatus.signedOut);
      expect(find.byType(EmployeeAttendanceScreen), findsNothing);
      expect(find.text('Se connecter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final terminal in [false, true]) {
    test(
      'retained note ${terminal ? "terminal" : "pending"} blocks checkout without consuming evidence',
      () async {
        await h.start();
        h.active = true;
        final context = h.composition.owner!.issueContext();
        final command = SessionNoteCommand.capture(
          identity: context.identity,
          sessionId: journalSessionId,
          operationKey: 'fictional-note-operation',
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
        expect(h.workflow.state.status, EmployeeAttendanceStatus.blocked);
        expect(
          h.notes.disk.records[journalBinding().storageIdentity],
          record.bytes,
        );
        expect(h.requests, isEmpty);
        expect(h.location.calls, 0);
        expect(h.operations.disk.writes, 0);
      },
    );
  }

  test('normal transport refuses standalone note RPC even under fictional attendance approval', () async {
    await h.start();
    final context = h.composition.owner!.issueContext();
    final command = SessionNoteCommand.capture(
      identity: context.identity,
      sessionId: journalSessionId,
      operationKey: 'fictional-disabled-note',
      note: const CheckoutNoteIntent.clear(),
    );
    await expectLater(
      h.composition.transport.saveNote(
        context.identity,
        command,
        replayOnly: false,
      ),
      throwsA(isA<AttendanceIntegrationFailure>()),
    );
    expect(h.requests, isEmpty);
    await context.release();
  });

  test('cutover withdrawal during credential refresh is checked immediately before POST', () async {
    await h.start();
    await h.workflow.refresh();
    h.operations.storage.afterCas = (record) async {
      if (record.phase == JournalPhase.mayHaveSent) {
        h.auth.expire();
        h.auth.refreshResponse = Completer<http.Response>();
      }
    };
    final action = h.workflow.checkIn();
    await h.auth.refreshStarted.future;
    h.approval.approved = false;
    h.auth.refreshResponse!.complete(json(h.auth.session()));
    await action;
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(h.operations.record!.phase, JournalPhase.mayHaveSent);
    expect(h.workflow.canRecover, false);
    expect(h.composition.owner!.outstandingAttempts, 0);
  });

  test('logout during GPS does not prepare or submit a command', () async {
    await h.start();
    await h.workflow.refresh();
    h.location.onAcquire = () async {
      await h.auth.controller.signOut();
      return h.location.evidence;
    };
    await h.workflow.checkIn();
    expect(h.operations.disk.writes, 0);
    expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(h.composition.owner!.outstandingAttempts, 0);
  });

  testWidgets(
    'History navigation keeps the same attendance workflow and final-note draft',
    (tester) async {
      await tester.runAsync(() => h.start());
      h.active = true;
      await tester.pumpWidget(
        ChantiPointApp(
          authController: h.auth.controller,
          employeeWorkflowFactory: h.composition.createWorkflow,
          historyRepositoryFactory: (_, _) => FakeHistoryRepository(),
          onDispose: () {},
        ),
      );
      await tester.pumpAndSettle();
      final screen = tester.widget<EmployeeAttendanceScreen>(
        find.byType(EmployeeAttendanceScreen),
      );
      await tester.ensureVisible(find.text('Remplacer la note à la sortie'));
      await tester.tap(find.text('Remplacer la note à la sortie'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Brouillon conservé');
      await tester.ensureVisible(find.text('Historique'));
      await tester.tap(find.text('Historique'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accueil'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EmployeeAttendanceScreen>(
              find.byType(EmployeeAttendanceScreen),
            )
            .workflow,
        same(screen.workflow),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Brouillon conservé',
      );
      expect(h.requests.where((r) => r.method == 'POST'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'administrator-only account receives no attendance workflow or History',
    (tester) async {
      await tester.runAsync(() => h.start(namespace: false));
      h.auth.administratorOnly = true;
      await tester.runAsync(h.auth.login);
      var created = 0;
      await tester.pumpWidget(
        ChantiPointApp(
          authController: h.auth.controller,
          employeeWorkflowFactory: (user) {
            created++;
            return h.composition.createWorkflow(user);
          },
          historyRepositoryFactory: (_, _) => FakeHistoryRepository(),
          onDispose: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(created, 0);
      expect(find.text('Historique'), findsNothing);
      expect(find.byType(EmployeeAttendanceScreen), findsNothing);
      expect(find.byTooltip('Se déconnecter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'legacy projection UI distinguishes unavailable notes and disables standalone Save',
    (tester) async {
      await tester.runAsync(
        () => h.start(projection: AttendanceSessionProjection.legacy),
      );
      h.active = true;
      await tester.pumpWidget(
        MaterialApp(home: EmployeeAttendanceScreen(workflow: h.workflow)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Note indisponible dans cette version du serveur.'),
        findsOneWidget,
      );
      expect(find.text('Aucune note enregistrée.'), findsNothing);
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Enregistrer la note'),
      );
      expect(button.onPressed, null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
