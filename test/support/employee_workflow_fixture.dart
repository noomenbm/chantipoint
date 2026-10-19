// Fictional host fixture only; no auth SDK, HTTP, durable storage or device GPS.
import 'package:chantipoint/src/attendance/attendance_action_capture.dart';
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:flutter/foundation.dart';

import 'fake_attendance_operation_ports.dart';
import 'fake_foreground_location.dart';
import 'journal_fixtures.dart';

class WorkflowClock implements AttendanceActionClock {
  DateTime value = DateTime.utc(2026, 10, 16, 3, 45);
  @override
  DateTime now() => value;
}

class WorkflowKeys implements AttendanceActionKeys {
  int calls = 0;
  @override
  String next() => 'fictional-workflow-key-${++calls}';
}

class WorkflowChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class WorkflowActiveSessions extends ChangeNotifier
    implements AttendanceActiveSessionReader {
  @override
  int revision = 0;
  WorkSession? result;
  String? currentId;
  final calls = <AttendanceOperationIdentity>[];
  Future<WorkSession?> Function()? onRead;
  @override
  Future<WorkSession?> readActiveSession(
    AttendanceOperationIdentity identity,
  ) async {
    calls.add(identity);
    return onRead == null ? result : await onRead!();
  }

  @override
  bool isSessionCurrent(
    AttendanceOperationIdentity identity,
    String sessionId,
  ) => sessionId == currentId;

  void changed() {
    revision++;
    notifyListeners();
  }
}

class EmployeeWorkflowFixture {
  EmployeeWorkflowFixture({this.verifier});
  final JournalVerifier? verifier;
  final operations = FictionalAttendanceOperations();
  final location = FakeLocationAcquisition();
  final clock = WorkflowClock();
  final keys = WorkflowKeys();
  final changes = WorkflowChanges();
  final active = WorkflowActiveSessions();
  final contexts = <FictionalAttendanceContext>[];
  bool authorized = true;
  void Function()? beforeIssue;
  late final capture = AttendanceActionCapture(
    location: location,
    clock: clock,
    keys: keys,
  );
  late final workflow = EmployeeAttendanceWorkflow(
    issueContext: () {
      beforeIssue?.call();
      if (!authorized) throw StateError('Fictional authorization unavailable');
      final context = operations.issuer.context();
      contexts.add(context);
      return context;
    },
    authorizationChanges: changes,
    activeSessions: active,
    capture: capture,
    coordinator: verifier == null
        ? operations.coordinator
        : AttendanceOperationCoordinator(
            storage: operations.storage,
            transport: operations.transport,
            canonical: operations.canonical,
            verifier: verifier,
          ),
  );
  void invalidate({bool notify = true}) {
    operations.issuer.relogin();
    if (notify) changes.changed();
  }

  void setActive(WorkSession? session) {
    active.result = session;
    active.currentId = session?.id;
    active.changed();
  }
}

WorkSession workflowSession({
  String context = 'factory',
  String? review = 'normal',
  String? note = 'Note canonique fictive',
  String? description = 'Lieu fictif',
  bool closed = false,
  String id = journalSessionId,
}) => WorkSession(
  id: id,
  locationContext: context,
  lifecycleStatus: closed ? 'closed_manual' : 'active',
  startedAt: DateTime.utc(2026, 10, 16, 3, 45),
  endedAt: closed ? DateTime.utc(2026, 10, 16, 12) : null,
  employeeNote: note,
  siteDescription: description,
  reviewStatus: review,
);
