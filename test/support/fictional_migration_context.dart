// Fictional harness assertions only. Does NOT fence the live legacy writer or
// establish historical provenance/durable global assignment in a real app.
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:chantipoint/src/attendance/journal/legacy_migration_coordinator.dart';

class FictionalMigrationContexts implements LegacyMigrationContexts {
  FictionalMigrationContexts(this.approvalFor);
  final LegacyBindingApproval? Function(JournalBinding) approvalFor;
  final leases = <FictionalMigrationContext>[];
  final assignments = <String, JournalBinding>{};
  bool available = true;
  bool fenced = true;
  bool exclusive = true;
  LegacyApprovalTrust trust = LegacyApprovalTrust.established;

  @override
  Future<LegacyMigrationContext?> acquire(
    JournalBinding binding,
    String sourceBasename,
  ) async {
    if (!available || !fenced || !exclusive) return null;
    final assigned = assignments[sourceBasename];
    if (assigned != null && !assigned.matches(binding)) {
      throw const JournalException(JournalIssue.identityMismatch);
    }
    assignments[sourceBasename] = binding;
    final lease = FictionalMigrationContext(
      binding,
      sourceBasename,
      approvalFor(binding),
      trust,
    );
    leases.add(lease);
    return lease;
  }
}

class FictionalMigrationContext implements LegacyMigrationContext {
  FictionalMigrationContext(
    this.binding,
    this.sourceBasename,
    this.approval,
    this.approvalTrust,
  );
  @override
  final JournalBinding binding;
  @override
  final String sourceBasename;
  @override
  final LegacyBindingApproval? approval;
  @override
  final LegacyApprovalTrust approvalTrust;
  bool valid = true;
  bool released = false;
  @override
  void checkValid() {
    if (!valid || released) throw const LegacyMigrationContextInvalidated();
  }

  @override
  Future<void> release() async {
    released = true;
  }
}
