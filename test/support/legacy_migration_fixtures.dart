import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';
import 'package:crypto/crypto.dart' show sha256;

import 'journal_fixtures.dart';

// Only fictional bindings/attestations; shared by host and isolated runtime tests.
JournalBinding migrationBinding(int slot) => journalBinding(
  environment: 'fictional-migration-$slot',
  profile:
      '00000000-0000-4000-8000-${(100 + slot).toRadixString(16).padLeft(12, '0')}',
);

LegacyBindingApproval migrationApproval(
  JournalBinding binding, {
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
}) {
  final source = legacySource(binding: binding, operation: operation);
  final owner = '${binding.companyId}:${binding.profileId}';
  return LegacyBindingApproval(
    binding: binding,
    approvedSource: source,
    metadata: JournalMigration(
      sourceBasename:
          'attendance_${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}.json',
      sourceSha256: sha256.convert(source).toString(),
      legacyOwner: owner,
      bindingApprovalRef: 'fictional-migration-approval',
    ),
  );
}

JournalRecord migrationRecord(
  JournalBinding binding, {
  bool confirmed = false,
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
}) {
  final approval = migrationApproval(binding, operation: operation);
  final parsed = LegacyJournalImport.prepare(
    approval.approvedSource,
    approval: approval,
  );
  final record = JournalRecord.absent(binding)
      .importLegacy(parsed.command!, parsed.metadata!);
  return confirmed
      ? record.confirm(journalConfirmation(record.command!, replay: true))
      : record;
}
