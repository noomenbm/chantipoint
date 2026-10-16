import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_repository.dart';

final serverStart = DateTime.utc(2026, 10, 15, 14);
WorkSession session({
  String id = 'session-1',
  bool closed = false,
  String context = 'factory',
}) => WorkSession(
  id: id,
  locationContext: context,
  lifecycleStatus: closed ? 'closed_manual' : 'active',
  startedAt: serverStart,
  endedAt: closed ? serverStart.add(const Duration(hours: 8)) : null,
);

class MemoryCommandStore implements PendingCommandStore {
  final commands = <String, AttendanceCommand>{};
  bool failWrites = false;
  @override
  Future<AttendanceCommand?> read(String owner) async => commands[owner];
  @override
  Future<void> save(String owner, AttendanceCommand command) async {
    if (failWrites) {
      throw const AttendanceFailure(AttendanceFailureKind.storage);
    }
    commands[owner] = AttendanceCommand.fromJson(command.toJson());
  }

  @override
  Future<void> clear(String owner, String expectedKey) async {
    if (commands[owner]?.key == expectedKey) commands.remove(owner);
  }
}

class FakeAttendanceRepository implements AttendanceRepository {
  WorkSession? active;
  final accepted = <String, WorkSession>{};
  final submitted = <AttendanceCommand>[];
  int reads = 0;
  AttendanceFailure? readFailure;
  Future<WorkSession> Function(AttendanceCommand)? onSubmit;
  @override
  Future<WorkSession?> activeSession() async {
    reads++;
    if (readFailure != null) throw readFailure!;
    return active;
  }

  @override
  Future<WorkSession?> findCommand(AttendanceCommand command) async {
    if (readFailure != null) throw readFailure!;
    return accepted[command.key];
  }

  @override
  Future<WorkSession> submit(AttendanceCommand command) async {
    submitted.add(command);
    if (onSubmit != null) return onSubmit!(command);
    return accept(command);
  }

  WorkSession accept(AttendanceCommand command) {
    final replay = accepted[command.key];
    if (replay != null) return replay;
    final result = session(
      closed: command.kind == AttendanceCommandKind.checkOut,
    );
    active = result.isActive ? result : null;
    accepted[command.key] = result;
    return result;
  }
}
