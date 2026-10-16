import 'attendance_models.dart';

abstract class AttendanceRepository {
  Future<WorkSession?> activeSession();
  Future<WorkSession?> findCommand(AttendanceCommand command);
  Future<WorkSession> submit(AttendanceCommand command);
}

abstract class PendingCommandStore {
  Future<AttendanceCommand?> read(String owner);
  Future<void> save(String owner, AttendanceCommand command);
  Future<void> clear(String owner, String expectedKey);
}
