import 'dart:convert';

import '../attendance_models.dart';
import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_record.dart';

/// Explicit external attestation, never derived from the active login/config.
/// C2c must establish provenance and verify SHA-256 before creating this object.
class LegacyBindingApproval {
  LegacyBindingApproval({
    required this.binding,
    required this.metadata,
    required List<int> approvedSource,
  }) : approvedSource = List.unmodifiable(approvedSource) {
    if (approvedSource.length > JournalJson.recordLimit ||
        metadata.plaintextCleanupComplete) {
      invalidJournal();
    }
  }
  final JournalBinding binding;
  final JournalMigration metadata;
  final List<int> approvedSource;
}

class LegacyImportResult {
  const LegacyImportResult._({
    this.binding,
    this.command,
    this.metadata,
    this.issue,
  });
  final JournalBinding? binding;
  final JournalCommand? command;
  final JournalMigration? metadata;
  final JournalIssue? issue;
}

abstract final class LegacyJournalImport {
  /// Parsing/preparation only: no filesystem access, hashing, deletion or writes.
  static LegacyImportResult prepare(
    List<int> source, {
    LegacyBindingApproval? approval,
  }) {
    try {
      final json = journalObject(JournalJson.decode(source));
      journalFields(json, {'version', 'kind', 'payload', 'owner'});
      if (json['version'] is! int || json['version'] != 1) {
        throw const JournalException(JournalIssue.unsupportedFormat);
      }
      final owner = journalText(json['owner']);
      final command = JournalCommand.legacy(AttendanceCommand.fromJson(json));
      if (approval == null) {
        return const LegacyImportResult._(issue: JournalIssue.bindingRequired);
      }
      final binding = approval.binding;
      final metadata = approval.metadata;
      if (owner != '${binding.companyId}:${binding.profileId}' ||
          owner != metadata.legacyOwner) {
        throw const JournalException(JournalIssue.identityMismatch);
      }
      final expectedName =
          'attendance_${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}.json';
      if (metadata.sourceBasename != expectedName ||
          source.length != approval.approvedSource.length ||
          Iterable<int>.generate(source.length)
              .any((i) => source[i] != approval.approvedSource[i])) {
        throw const JournalException(JournalIssue.commandConflict);
      }
      return LegacyImportResult._(
        binding: binding,
        command: command,
        metadata: metadata,
      );
    } on JournalException catch (error) {
      return LegacyImportResult._(issue: error.issue);
    } catch (_) {
      return const LegacyImportResult._(issue: JournalIssue.corrupt);
    }
  }
}
