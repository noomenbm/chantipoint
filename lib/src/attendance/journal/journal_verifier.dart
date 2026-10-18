import 'journal_command.dart';
import 'journal_json.dart';

/// Fresh, exact-record file/directory synchronization and authenticated readback.
/// Null means verified, never merely readable. No writes, cleanup or networking.
abstract interface class JournalVerifier {
  Future<JournalIssue?> verify(
    JournalBinding binding,
    List<int> expectedRecord,
  );
}
