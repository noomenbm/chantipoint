import 'attendance_models.dart';
import 'attendance_receipt.dart';
import 'attendance_v2_requests.dart';

abstract class AttendanceRepository {
  Future<WorkSession?> activeSession();
  Future<WorkSession?> findCommand(AttendanceCommand command);
  Future<WorkSession> submit(AttendanceCommand command);
}

/// Isolated contract support. The live controller continues to use only
/// AttendanceRepository until secure v2 journaling and cutover are approved.
abstract class AttendanceV2Repository {
  Future<WorkSession?> activeSessionV2();
  Future<AttendanceReceipt> checkInV2(
    CheckInV2Request request, {
    bool replayOnly = false,
  });
  Future<AttendanceReceipt> checkOutV2(
    CheckOutV2Request request, {
    bool replayOnly = false,
  });
  Future<EmployeeNoteUpdateResult> updateEmployeeNote({
    required String workSessionId,
    required String? employeeNote,
  });
}

abstract class PendingCommandStore {
  Future<AttendanceCommand?> read(String owner);
  Future<void> save(String owner, AttendanceCommand command);
  Future<void> clear(String owner, String expectedKey);
}
