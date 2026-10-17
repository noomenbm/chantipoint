import 'dart:convert';

import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_record.dart';

class JournalReadResult {
  const JournalReadResult.absent() : record = null, issue = null;
  const JournalReadResult.stored(JournalRecord this.record) : issue = null;
  const JournalReadResult.blocked(JournalIssue this.issue) : record = null;
  final JournalRecord? record;
  final JournalIssue? issue;
  bool get isAbsent => record == null && issue == null;
  bool get isBlocked => issue != null || record?.phase == JournalPhase.blocked;
}

abstract final class JournalCodec {
  static List<int> encode(JournalRecord record) {
    final validated = JournalRecord.fromJson(record.toJson());
    return List.unmodifiable(
      utf8.encode(JournalJson.encode(validated.toJson())),
    );
  }

  /// Every existing invalid record is blocked; only storage may report absence.
  static JournalReadResult decode(List<int> bytes, JournalBinding expected) {
    try {
      final record = JournalRecord.fromJson(
        journalObject(JournalJson.decode(bytes)),
      );
      return record.binding.matches(expected)
          ? JournalReadResult.stored(record)
          : const JournalReadResult.blocked(JournalIssue.identityMismatch);
    } on JournalException catch (error) {
      return JournalReadResult.blocked(error.issue);
    } catch (_) {
      return const JournalReadResult.blocked(JournalIssue.corrupt);
    }
  }
}

class JournalStorageRead {
  const JournalStorageRead.absent() : bytes = null, issue = null;
  JournalStorageRead.bytes(List<int> bytes)
    : bytes = List.unmodifiable(bytes),
      issue = null;
  const JournalStorageRead.failure(JournalIssue this.issue) : bytes = null;
  final List<int>? bytes;
  final JournalIssue? issue;
}

/// Future encrypted backend. A successful CAS means the replacement has been
/// committed, independently read back and verified under a shared lock.
/// A failure may occur AFTER commit: callers must reread, never assume rollback.
abstract interface class JournalStorage {
  Future<JournalStorageRead> read(JournalBinding binding);
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  });
}

/// Storage/state primitives only. No network dispatch, timers or live wiring.
class CommandJournal {
  const CommandJournal(this.storage);
  final JournalStorage storage;

  Future<JournalReadResult> read(JournalBinding binding) async {
    try {
      final stored = await storage.read(binding);
      if (stored.issue != null) return JournalReadResult.blocked(stored.issue!);
      if (stored.bytes == null) return const JournalReadResult.absent();
      return JournalCodec.decode(stored.bytes!, binding);
    } catch (_) {
      return const JournalReadResult.blocked(JournalIssue.storageFailure);
    }
  }

  Future<JournalReadResult> _change(
    JournalBinding binding,
    int expectedRevision,
    String? expectedKey,
    JournalRecord Function(JournalRecord) change,
  ) async {
    try {
      final current = await read(binding);
      if (current.issue != null) return current;
      final record = current.record ?? JournalRecord.absent(binding);
      if (record.revision != expectedRevision ||
          record.command?.key != expectedKey) {
        return const JournalReadResult.blocked(JournalIssue.revisionConflict);
      }
      final replacement = change(record);
      if (identical(replacement, record)) return current;
      final issue = await storage.compareAndSwap(
        binding: binding,
        expectedRevision: expectedRevision,
        expectedKey: expectedKey,
        replacement: JournalCodec.encode(replacement),
      );
      return issue == null
          ? JournalReadResult.stored(replacement)
          : JournalReadResult.blocked(issue);
    } on JournalException catch (error) {
      return JournalReadResult.blocked(error.issue);
    } catch (_) {
      return const JournalReadResult.blocked(JournalIssue.storageFailure);
    }
  }

  Future<JournalReadResult> prepare(
    JournalBinding binding,
    JournalCommand command, {
    required int expectedRevision,
    required String? expectedKey,
  }) => _change(binding, expectedRevision, expectedKey, (record) {
    if (record.command != null) {
      if (!record.command!.sameRequest(command)) {
        throw const JournalException(JournalIssue.commandConflict);
      }
      // An identical duplicate retains the FIRST frozen JSON, state and receipt.
      return record;
    }
    return record.prepare(command);
  });

  Future<JournalReadResult> markMayHaveSent(
    JournalBinding binding, {
    required int expectedRevision,
    required String expectedKey,
  }) => _change(
    binding,
    expectedRevision,
    expectedKey,
    (r) => r.markMayHaveSent(),
  );
  Future<JournalReadResult> markUncertain(
    JournalBinding binding, {
    required int expectedRevision,
    required String expectedKey,
  }) =>
      _change(binding, expectedRevision, expectedKey, (r) => r.markUncertain());
  Future<JournalReadResult> confirm(
    JournalBinding binding,
    JournalConfirmation confirmation, {
    required int expectedRevision,
    required String expectedKey,
  }) => _change(
    binding,
    expectedRevision,
    expectedKey,
    (r) => r.confirm(confirmation),
  );
  Future<JournalReadResult> block(
    JournalBinding binding,
    JournalBlockReason reason, {
    required int expectedRevision,
    required String expectedKey,
  }) => _change(
    binding,
    expectedRevision,
    expectedKey,
    (r) => r.blockRecovery(reason),
  );
  Future<JournalReadResult> compactConfirmed(
    JournalBinding binding, {
    required int expectedRevision,
    required String expectedKey,
    required bool canonicalStateVerified,
    required bool confirmationConsumed,
  }) => _change(
    binding,
    expectedRevision,
    expectedKey,
    (r) => r.compactConfirmed(
      canonicalStateVerified: canonicalStateVerified,
      confirmationConsumed: confirmationConsumed,
    ),
  );

  Future<JournalReadResult> importLegacy(
    JournalBinding binding,
    JournalCommand command,
    JournalMigration metadata, {
    required int expectedRevision,
    required String? expectedKey,
  }) => _change(
    binding,
    expectedRevision,
    expectedKey,
    (r) => r.importLegacy(command, metadata),
  );
  Future<JournalReadResult> markLegacyCleanupComplete(
    JournalBinding binding,
    String sourceSha256, {
    required int expectedRevision,
    required String expectedKey,
  }) => _change(
    binding,
    expectedRevision,
    expectedKey,
    (r) => r.markLegacyCleanupComplete(sourceSha256),
  );
}
