import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_action_capture.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:chantipoint/src/attendance/scoped_attendance_active_session_reader.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/active_session_read_fixtures.dart';
import 'support/attendance_auth_backend.dart';
import 'support/employee_workflow_fixture.dart';
import 'support/fake_attendance_operation_ports.dart';
import 'support/fake_foreground_location.dart';
import 'support/journal_fixtures.dart';

void main() {
  late AttendanceAuthBackend b;
  late FictionalAttendanceOperations storageFixture;
  late ScopedAttendanceActiveSessionReader reader;
  late EmployeeAttendanceWorkflow workflow;
  late FakeLocationAcquisition location;
  late MockClient client;
  late Future<http.Response> Function(http.Request) handler;
  late List<http.Request> requests;
  setUp(() async {
    b = AttendanceAuthBackend();
    await b.login();
    storageFixture = FictionalAttendanceOperations();
    location = FakeLocationAcquisition();
    requests = [];
    handler = (_) async => json(activeSelection());
    client = MockClient((request) {
      requests.add(request);
      return handler(request);
    });
    final transport = SupabaseAttendanceOperationTransport(
      authority: b.owner,
      client: client,
    );
    reader = ScopedAttendanceActiveSessionReader(transport: transport);
    workflow = EmployeeAttendanceWorkflow(
      issueContext: b.context,
      authorizationChanges: b.owner,
      activeSessions: reader,
      capture: AttendanceActionCapture(
        location: location,
        clock: WorkflowClock(),
        keys: WorkflowKeys(),
      ),
      coordinator: AttendanceOperationCoordinator(
        storage: storageFixture.storage,
        transport: transport,
        canonical: transport,
      ),
    );
  });
  tearDown(() async {
    workflow.dispose();
    await workflow.settled;
    reader.dispose();
    client.close();
    await b.close();
  });

  test('application owner close clears C5 but waits for the in-flight read context', () async {
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    handler = (_) {
      entered.complete();
      return pending.future;
    };
    final reading = workflow.refresh();
    await entered.future;
    var closed = false;
    final closing = b.owner.close().then((_) => closed = true);
    expect(
      workflow.state.status,
      EmployeeAttendanceStatus.authorizationUnavailable,
    );
    await turn();
    expect(closed, false);
    expect(b.owner.outstandingAttempts, 1);
    pending.complete(json(activeSelection()));
    await reading;
    await closing;
    expect(workflow.state.session, isNull);
    expect(b.owner.outstandingAttempts, 0);
  });

  test('real scoped adapters populate C5 without dispatch or route composition; refresh stays authorized', () async {
    await workflow.refresh();
    expect(workflow.state.status, EmployeeAttendanceStatus.ready);
    expect(workflow.state.session!.employeeNote, 'Note canonique fictive');
    expect(workflow.canCheckOut, true);
    expect(requests.single.method, 'GET');
    expect(reader.revision, 0);
    await b.client.auth.refreshSession();
    await turn();
    expect(workflow.state.status, EmployeeAttendanceStatus.ready);
    expect(workflow.canCheckOut, true);
    expect(requests.length, 1);
    expect(b.profileCalls, 1);
    workflow.dispose();
    expect(
      b.context().isCurrent,
      true,
    ); // Route disposal does not close app owner.
  });
  test('authorized empty SELECT alone enables check-in', () async {
    handler = (_) async => json(activeSelection(sessions: []));
    await workflow.refresh();
    expect(workflow.state.status, EmployeeAttendanceStatus.ready);
    expect(workflow.state.session, isNull);
    expect(workflow.canCheckIn, true);
  });
  for (final reason in [
    'denied',
    'missing-v2',
    'hidden-profile',
    'malformed',
  ]) {
    test(
      '$reason remains failure in C5 rather than enabling check-in',
      () async {
        handler = (_) async => switch (reason) {
          'denied' => http.Response('fictional private error', 403),
          'missing-v2' => http.Response('fictional schema error', 400),
          'hidden-profile' => json([]),
          _ => json([
            {'sessions': []},
          ]),
        };
        await workflow.refresh();
        expect(
          workflow.state.status,
          EmployeeAttendanceStatus.refreshUnavailable,
        );
        expect(workflow.state.session, isNull);
        expect(workflow.canCheckIn, false);
        expect(workflow.canCheckOut, false);
        expect(b.owner.outstandingAttempts, 0);
      },
    );
  }
  for (final transition in [
    'logout',
    'revalidate',
    'relogin',
    'different-account',
  ]) {
    test(
      '$transition during a delayed read clears C5 synchronously, no stale result published',
      () async {
        await workflow.refresh();
        final pending = Completer<http.Response>();
        final entered = Completer<void>();
        handler = (_) {
          entered.complete();
          return pending.future;
        };
        final refreshing = workflow.refresh();
        await entered.future;
        Future<void> auth;
        if (transition == 'logout') {
          auth = b.controller.signOut();
        } else if (transition == 'revalidate') {
          auth = b.controller.revalidateOnResume();
        } else {
          if (transition == 'different-account') b.account = journalOtherId;
          auth = b.login();
        }
        expect(
          workflow.state.status,
          EmployeeAttendanceStatus.authorizationUnavailable,
        );
        expect(workflow.state.session, isNull);
        expect(b.owner.outstandingAttempts, 1);
        await auth;
        pending.complete(json(activeSelection()));
        await refreshing;
        expect(workflow.state.session, isNull);
        expect(workflow.canCheckOut, false);
        expect(b.owner.outstandingAttempts, 0);
      },
    );
  }
  test(
    'logout before dispatch during real credential refresh sends no SELECT',
    () async {
      b.expire();
      b.refreshResponse = Completer<http.Response>();
      final refreshing = workflow.refresh();
      await b.refreshStarted.future;
      final logout = b.controller.signOut();
      expect(
        workflow.state.status,
        EmployeeAttendanceStatus.authorizationUnavailable,
      );
      b.refreshResponse!.complete(json(b.session()));
      await refreshing;
      await logout;
      expect(requests, isEmpty);
      expect(b.owner.outstandingAttempts, 0);
    },
  );
  test('known session change during delayed SELECT invalidates C5 and requires explicit fresh refresh', () async {
    await workflow.refresh();
    final identity = b.context().identity;
    await b.contexts.last.release();
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    handler = (_) {
      entered.complete();
      return pending.future;
    };
    final refreshing = workflow.refresh();
    await entered.future;
    reader.invalidateSession(identity);
    expect(workflow.state.status, EmployeeAttendanceStatus.refreshUnavailable);
    pending.complete(json(activeSelection()));
    await refreshing;
    expect(workflow.state.session, isNull);
    expect(workflow.canCheckOut, false);
    handler = (_) async =>
        json(activeSelection(sessions: [activeSessionRow(id: journalOtherId)]));
    await workflow.refresh();
    expect(workflow.state.session!.id, journalOtherId);
    expect(workflow.canCheckOut, true);
    expect(reader.revision, 1);
  });
  test('original checkout observation blocks journal/POST when a known change occurs during location', () async {
    await workflow.refresh();
    final pending = Completer<LocationEvidence>();
    final entered = Completer<void>();
    location.onAcquire = () {
      entered.complete();
      return pending.future;
    };
    final checkout = workflow.checkOut();
    await entered.future;
    final identity = b.context().identity;
    await b.contexts.last.release();
    reader.invalidateSession(identity);
    pending.complete(
      const LocationEvidence(result: LocationAcquisitionResult.timeout),
    );
    await checkout;
    expect(workflow.canCheckOut, false);
    expect(requests.map((r) => r.method), ['GET']);
    expect(storageFixture.storage.attempts, isEmpty);
    expect(b.owner.outstandingAttempts, 0);
  });
}
