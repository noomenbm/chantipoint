import '../attendance_operation_transport.dart';
import '../attendance_request_authority.dart';
import '../journal/journal_command.dart';
import 'session_note_record.dart';

/// Separate encrypted namespace. CAS/verify span file+directory sync and complete
/// authenticated readback. Failure can follow commit. No plaintext fallback.
abstract interface class SessionNoteStorage {
  Future<SessionNoteRecord?> read(JournalBinding binding);
  Future<void> compareAndSwap(
    SessionNoteRecord previous,
    SessionNoteRecord next,
  );
  Future<void> verify(SessionNoteRecord record);
}

abstract interface class SessionNoteTransport {
  AttendanceRequestAuthority get authority;

  /// Pinned scope, one attempt, bounded stream through settlement. Errors remain
  /// uncertainty. No timeout/retry; late valid receipts still return.
  Future<SessionNoteReceipt> saveNote(
    AttendanceOperationIdentity identity,
    SessionNoteCommand command, {
    required bool replayOnly,
  });
}
