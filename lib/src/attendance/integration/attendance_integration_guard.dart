import '../attendance_operation_transport.dart';
import '../journal/journal_command.dart';
import '../journal/legacy_journal_migration.dart';
import '../notes/session_note_ports.dart';

/// A future issuer must establish deployment capability/gate, trusted binding,
/// durable ownership and old-writer fencing held THROUGH operation settlement.
/// File absence, matching UUIDs, a build flag or an RPC miss are not approval.
/// No production issuer is supplied by this slice.
abstract interface class AttendanceCutoverAuthority {
  bool isApproved(AttendanceOperationIdentity identity);
}

final class UnapprovedAttendanceCutover implements AttendanceCutoverAuthority {
  const UnapprovedAttendanceCutover();
  @override
  bool isApproved(AttendanceOperationIdentity identity) => false;
}

final class AttendanceIntegrationFailure implements Exception {
  const AttendanceIntegrationFailure(this.message);
  final String message;
  @override
  String toString() => 'AttendanceIntegrationFailure';
}

/// Inspect only. Never import, assign provenance, delete or reset source files.
typedef LegacyAttendanceInspection = Future<LegacySourceSnapshot> Function(
  JournalBinding binding,
);

final class AttendanceIntegrationGuard {
  AttendanceIntegrationGuard({
    required this.configurationMessage,
    required this.cutover,
    required this.inspectLegacy,
    required this.notes,
    required this.enrichedSessions,
    this.requireCapability,
  });
  final String? configurationMessage;
  final AttendanceCutoverAuthority cutover;
  final LegacyAttendanceInspection inspectLegacy;
  final SessionNoteStorage notes;
  final bool enrichedSessions;
  final Future<void> Function(AttendanceOperationIdentity)? requireCapability;
  static const notActivated =
      'Le nouveau pointage n’est pas encore activé. '
      'Les entrées, sorties et reprises sont indisponibles. '
      'Vous pouvez consulter l’historique.';

  bool allows(AttendanceOperationIdentity? identity) {
    try {
      return configurationMessage == null &&
          enrichedSessions &&
          identity != null &&
          cutover.isApproved(identity);
    } catch (_) {
      return false;
    }
  }

  void requireApproval(AttendanceOperationIdentity identity) {
    if (!allows(identity)) {
      throw const AttendanceIntegrationFailure(notActivated);
    }
  }

  Future<void> beforeRead(AttendanceOperationIdentity identity) async {
    if (configurationMessage != null) {
      throw AttendanceIntegrationFailure(configurationMessage!);
    }
    try {
      final source = await inspectLegacy(identity.binding);
      if (source.issue != null ||
          source.bytes != null ||
          source.artifacts.isNotEmpty) {
        throw const AttendanceIntegrationFailure(
          'Un ancien pointage ou fichier à vérifier est conservé sur cet appareil. '
          'Aucun nouveau pointage ne sera envoyé. Contactez votre administrateur.',
        );
      }
      // Note Save is NOT composed. Any retained note slot, even terminal, needs
      // the reviewed shared note/checkout recovery boundary, not a guessed gate.
      if (await notes.read(identity.binding) != null) {
        throw const AttendanceIntegrationFailure(
          'Une opération de note conservée doit être vérifiée avant le pointage. '
          'Les données restent conservées sur cet appareil.',
        );
      }
    } on AttendanceIntegrationFailure {
      rethrow;
    } catch (_) {
      throw const AttendanceIntegrationFailure(
        'Impossible de vérifier les opérations conservées sur cet appareil. '
        'Aucun pointage ne sera envoyé. Réessayez ou contactez votre administrateur.',
      );
    }
  }

  Future<void> beforeAction(AttendanceOperationIdentity identity) async {
    requireApproval(identity);
    await beforeRead(identity);
    await requireCapability?.call(identity);
    requireApproval(identity);
  }
}
