import 'dart:typed_data';

import 'command_journal.dart';
import 'journal_command.dart';
import 'journal_json.dart';

/// Pure policy over authenticated native candidates. No ordering/freshness guess.
class JournalRecoveryPlan {
  JournalRecoveryPlan._(
    this.snapshot,
    List<int> record,
    this.needsNormalization,
  ) : record = List<int>.unmodifiable(record);

  final String snapshot;
  final List<int> record;
  final bool needsNormalization;

  factory JournalRecoveryPlan.inspect(
    Object? response,
    JournalBinding binding,
  ) {
    Never malformed() =>
        throw const JournalException(JournalIssue.nativeFailure);
    if (response is! Map ||
        response.length != 3 ||
        response['recovery_version'] is! int ||
        response['recovery_version'] != 1 ||
        response['snapshot'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(response['snapshot'] as String) ||
        response['candidates'] is! List) {
      malformed();
    }
    final candidates = response['candidates'] as List;
    if (candidates.length > 3) malformed();
    final records = <String, List<int>>{};
    for (final candidate in candidates) {
      if (candidate is! Map ||
          candidate.length != 2 ||
          !const {'main', 'new', 'bak'}.contains(candidate['kind']) ||
          candidate['record'] is! Uint8List) {
        malformed();
      }
      final kind = candidate['kind'] as String;
      if (records.containsKey(kind)) malformed();
      final bytes = candidate['record'] as Uint8List;
      if (bytes.length > JournalJson.recordLimit) {
        throw const JournalException(JournalIssue.corrupt);
      }
      final frozen = List<int>.unmodifiable(bytes);
      final validated = JournalCodec.decode(frozen, binding);
      if (validated.issue != null) throw JournalException(validated.issue!);
      records[kind] = frozen;
    }
    final main = records['main'];
    // Three-artifact histories and sidecar-only states remain explicitly blocked.
    if (main == null || records.length > 2) {
      throw const JournalException(JournalIssue.unreadable);
    }
    if (records.values.any((bytes) => !sameRecordBytes(main, bytes))) {
      throw const JournalException(JournalIssue.unreadable);
    }
    return JournalRecoveryPlan._(
      response['snapshot'] as String,
      main,
      records.length == 2,
    );
  }

  static bool sameRecordBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var i = 0; i < first.length; i++) {
      if (first[i] != second[i]) return false;
    }
    return true;
  }
}
