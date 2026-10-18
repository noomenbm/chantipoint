import 'package:crypto/crypto.dart' show sha256;

import 'command_journal.dart';
import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_record.dart';
import 'legacy_journal_import.dart';

enum LegacySourceArtifact { temporary, unexpected }

/// Supplied observations only: absence is not a durable-cleanup attestation.
/// No paths are opened. Byte inputs are bounded and copied before hashing.
final class LegacySourceSnapshot {
  LegacySourceSnapshot.file({
    required String basename,
    required List<int> bytes,
    Set<LegacySourceArtifact> artifacts = const {},
  }) : this._(
         basename: journalText(basename),
         bytes: _freezeBytes(bytes),
         artifacts: artifacts,
       );

  LegacySourceSnapshot.absent({Set<LegacySourceArtifact> artifacts = const {}})
    : this._(artifacts: artifacts);

  LegacySourceSnapshot.unreadable() : this._(issue: JournalIssue.unreadable);

  LegacySourceSnapshot._({
    this.basename,
    this.bytes,
    Set<LegacySourceArtifact> artifacts = const {},
    this.issue,
  }) : artifacts = Set.unmodifiable(artifacts),
       sourceSha256 = bytes == null ? null : sha256.convert(bytes).toString();

  final String? basename;
  final List<int>? bytes;
  final String? sourceSha256;
  final Set<LegacySourceArtifact> artifacts;
  final JournalIssue? issue;

  static List<int> _freezeBytes(List<int> bytes) {
    if (bytes.length > JournalJson.recordLimit) invalidJournal();
    final frozen = List<int>.unmodifiable(bytes);
    if (frozen.any((byte) => byte < 0 || byte > 255)) invalidJournal();
    return frozen;
  }
}

/// The caller must verify the external attestation's authority and provenance.
/// This enum does not verify an issuer, discover origin or approve a binding.
enum LegacyApprovalTrust { unverified, established }

enum LegacyMigrationStep {
  noAction,
  bindingRequired,
  importLegacy,
  resumeCleanup,
  blocked,
}

/// Outstanding obligations, not operations performed or permissions granted.
enum LegacyMigrationCheck {
  writerFencing,
  globalSourceBinding,
  sourceSnapshotVerification,
  targetCompareAndSwap,
  durableTargetVerification,
  checkedPlaintextCleanup,
  durableSourceAbsenceVerification,
  cleanupCompletionCompareAndSwap,
}

final class LegacyMigrationPlan {
  LegacyMigrationPlan._(
    this.step, {
    this.issue,
    this.existingRecord,
    this.importRecord,
    Set<LegacyMigrationCheck> requiredChecks = const {},
  }) : requiredChecks = Set.unmodifiable(requiredChecks);

  final LegacyMigrationStep step;
  final JournalIssue? issue;

  /// The original supplied record, including its frozen command and receipt.
  final JournalRecord? existingRecord;

  /// An in-memory proposal only. It has not been written or durably verified.
  /// Only importLegacy plans expose a candidate; blocked plans expose neither.
  final JournalRecord? importRecord;
  final Set<LegacyMigrationCheck> requiredChecks;
}

/// Pure per-slot planning: no storage, cleanup, dispatch or state mutations.
///
/// [binding] is the explicitly expected complete destination identity, not
/// evidence of historical origin. The caller must independently establish the
/// approval's authority/origin and pass established trust on each evaluation.
/// Current configuration, login/UUID matches and server misses are not proof.
/// This planner cannot enforce global one-source/one-destination uniqueness.
abstract final class LegacyJournalMigration {
  static LegacyMigrationPlan evaluate({
    required JournalBinding binding,
    required LegacySourceSnapshot source,
    required JournalReadResult target,
    LegacyBindingApproval? approval,
    LegacyApprovalTrust approvalTrust = LegacyApprovalTrust.unverified,
  }) {
    try {
      if (source.issue != null) return _blocked(source.issue!);
      if (source.artifacts.isNotEmpty) return _blocked(JournalIssue.unreadable);
      if (target.issue != null) return _blocked(target.issue!);
      final current = target.record;
      if (current != null) {
        // Do not accept an in-memory revision-zero record as stored state.
        // Native sidecar policy stays entirely in C2b.1 storage.
        final checked = JournalCodec.decode(
          JournalCodec.encode(current),
          binding,
        );
        if (checked.issue != null) return _blocked(checked.issue!);
        if (current.phase == JournalPhase.blocked) {
          return _blocked(JournalIssue.illegalTransition);
        }
      }

      final bytes = source.bytes;
      final migration = current?.migration;
      if (bytes == null && migration == null) return _noAction(current);
      if (migration?.plaintextCleanupComplete == true && bytes != null) {
        return _blocked(JournalIssue.commandConflict);
      }
      if (bytes != null) {
        final parsed = LegacyJournalImport.prepare(bytes);
        if (parsed.issue != JournalIssue.bindingRequired) {
          return _blocked(parsed.issue ?? JournalIssue.corrupt);
        }
      }
      // Completed metadata needs no new approval when there is nothing to do.
      // An explicitly supplied conflicting approval must still be rejected.
      if (bytes == null &&
          migration!.plaintextCleanupComplete &&
          approval == null) {
        return _noAction(current);
      }
      if (approval == null ||
          approvalTrust != LegacyApprovalTrust.established) {
        return LegacyMigrationPlan._(
          LegacyMigrationStep.bindingRequired,
          issue: JournalIssue.bindingRequired,
        );
      }
      if (!approval.binding.matches(binding)) {
        return _blocked(JournalIssue.identityMismatch);
      }

      // When the source is absent, reverify the externally approved original
      // bytes. Never manufacture a new approval/source from the target command.
      final snapshot = bytes == null
          ? LegacySourceSnapshot.file(
              basename: approval.metadata.sourceBasename,
              bytes: approval.approvedSource,
            )
          : source;
      if (snapshot.basename != approval.metadata.sourceBasename ||
          snapshot.sourceSha256 != approval.metadata.sourceSha256) {
        return _blocked(JournalIssue.commandConflict);
      }
      final prepared = LegacyJournalImport.prepare(
        snapshot.bytes!,
        approval: approval,
      );
      if (prepared.issue != null) return _blocked(prepared.issue!);
      final command = prepared.command!;
      final metadata = prepared.metadata!;

      if (migration != null) {
        if (!_sameMigration(migration, metadata)) {
          return _blocked(JournalIssue.commandConflict);
        }
        // Completed metadata can accompany an empty tombstone or later command.
        if (migration.plaintextCleanupComplete) return _noAction(current);
        final previous = current!.command!;
        if (!previous.sameRequest(command) ||
            previous.parametersJson != command.parametersJson) {
          return _blocked(JournalIssue.commandConflict);
        }
        return LegacyMigrationPlan._(
          LegacyMigrationStep.resumeCleanup,
          existingRecord: current,
          requiredChecks: _checks(sourcePresent: bytes != null),
        );
      }

      final empty = current ?? JournalRecord.absent(binding);
      if (empty.phase != JournalPhase.empty) {
        return _blocked(JournalIssue.commandConflict);
      }
      return LegacyMigrationPlan._(
        LegacyMigrationStep.importLegacy,
        existingRecord: current,
        importRecord: empty.importLegacy(command, metadata),
        requiredChecks: {
          ..._checks(sourcePresent: true),
          LegacyMigrationCheck.targetCompareAndSwap,
        },
      );
    } on JournalException catch (error) {
      return _blocked(error.issue);
    }
  }

  static bool _sameMigration(JournalMigration a, JournalMigration b) =>
      a.sourceBasename == b.sourceBasename &&
      a.sourceSha256 == b.sourceSha256 &&
      a.legacyOwner == b.legacyOwner &&
      a.bindingApprovalRef == b.bindingApprovalRef;

  static Set<LegacyMigrationCheck> _checks({required bool sourcePresent}) => {
    LegacyMigrationCheck.writerFencing,
    LegacyMigrationCheck.globalSourceBinding,
    if (sourcePresent) LegacyMigrationCheck.sourceSnapshotVerification,
    LegacyMigrationCheck.durableTargetVerification,
    if (sourcePresent) LegacyMigrationCheck.checkedPlaintextCleanup,
    LegacyMigrationCheck.durableSourceAbsenceVerification,
    LegacyMigrationCheck.cleanupCompletionCompareAndSwap,
  };

  static LegacyMigrationPlan _noAction(JournalRecord? current) =>
      LegacyMigrationPlan._(
        LegacyMigrationStep.noAction,
        existingRecord: current,
      );

  static LegacyMigrationPlan _blocked(JournalIssue issue) =>
      LegacyMigrationPlan._(LegacyMigrationStep.blocked, issue: issue);
}
