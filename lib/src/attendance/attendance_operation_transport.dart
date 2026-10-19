import 'attendance_models.dart';
import 'journal/journal_command.dart';

/// Explicit owner/authorization epoch, never inferred from UUID equality or a
/// refreshed token. No token, credential or generation is added to the journal.
final class AttendanceOperationIdentity {
  const AttendanceOperationIdentity(this.binding, this.generation);
  final JournalBinding binding;
  final int generation;
}

/// One attempt's context. isCurrent must assert an authorized employee for the
/// complete captured binding/epoch, not just a matching UUID or present token.
/// Its issuer must invalidate old generations even on same-user relogin.
/// isCurrent remains an observation after release, so returned
/// results can suppress stale publication. release ends this attempt's lifetime;
/// it must not cancel work or be called by a caller-facing timeout/disposal.
/// The core consumes each context object once, across its instances in one
/// isolate. A later explicit attempt requires a newly issued context.
/// No production authentication, ownership or fencing implementation is supplied.
abstract interface class AttendanceOperationContext {
  AttendanceOperationIdentity get identity;
  bool get isCurrent;
  Future<void> release();
}

/// Complete ORIGINAL acknowledgement JSON, not a WorkSession/AttendanceReceipt
/// reconstruction. A miss must come from a validated replay-only not_found reply.
final class AttendanceTransportReply {
  const AttendanceTransportReply.acknowledged(String this.dataJson);
  const AttendanceTransportReply.replayMiss() : dataJson = null;
  final String? dataJson;
}

/// Implementations must bind credentials/request scope to the supplied identity
/// and preserve command.parametersJson. Replay changes only the outgoing
/// operational flag, never the stored command. This future represents submitted
/// local work settling, not a timeout wrapper that leaves hidden work running.
/// An error still does NOT prove the server rolled back/stopped. No automatic
/// retries, key/evidence regeneration, note saves or production adapter here.
abstract interface class AttendanceOperationTransport {
  Future<AttendanceTransportReply> dispatch(
    AttendanceOperationIdentity identity,
    JournalCommand command, {
    required bool replayOnly,
  });
}

/// Correctly owner/environment-scoped server read of the acknowledged session,
/// including a closed session. Null/unavailable is not attendance-failure proof.
abstract interface class AttendanceCanonicalReader {
  Future<WorkSession?> readSession(
    AttendanceOperationIdentity identity,
    String sessionId,
  );
}

/// Injected owner/environment/generation-scoped active SELECT. Null is an
/// authorized empty selection, never inferred from a receipt or replay miss.
/// No production adapter is supplied by this port.
abstract interface class AttendanceActiveSessionQuery {
  Future<WorkSession?> readActiveSession(AttendanceOperationIdentity identity);
}
