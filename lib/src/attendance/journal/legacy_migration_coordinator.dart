import 'dart:async';

import 'android_legacy_migration.dart';
import 'command_journal.dart';
import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_record.dart';
import 'journal_recovery.dart';
import 'legacy_journal_import.dart';
import 'legacy_journal_migration.dart';

enum LegacyMigrationOutcome {
  noAction,
  bindingRequired,
  prerequisitesRequired,
  invalidated,
  blocked,
  retryable,
  completed,
}

final class LegacyMigrationResult {
  const LegacyMigrationResult(this.outcome, {this.issue, this.record});
  final LegacyMigrationOutcome outcome;
  final JournalIssue? issue;
  final JournalRecord? record;
}

/// External authority owns approval, durable global source assignment and writer
/// fencing. No production implementation is supplied. Acquire AFTER local queuing.
abstract interface class LegacyMigrationContexts {
  Future<LegacyMigrationContext?> acquire(
    JournalBinding binding,
    String sourceBasename,
  );
}

/// Immutable identity/approval for one attempt. checkValid must synchronously
/// establish that this exact source/destination assignment and writer fence are
/// still held, throwing on missing/conflicting/invalidated prerequisites.
///
/// The lease MUST outlive every submitted native operation, even if a caller
/// times out/disposes. release is invoked only after those futures settle. A lost
/// reply that never settles keeps this attempt/fence outstanding; it is not
/// cancellation. Process death requires external durable restart coordination.
abstract interface class LegacyMigrationContext {
  JournalBinding get binding;
  String get sourceBasename;
  LegacyBindingApproval? get approval;
  LegacyApprovalTrust get approvalTrust;
  void checkValid();
  Future<void> release();
}

class LegacyMigrationContextInvalidated implements Exception {
  const LegacyMigrationContextInvalidated();
}

/// Only the Android implementation supplies real IO. scoped must check validity
/// around EACH async boundary, including internal recovery/channel calls. Host
/// implementations are fictional simulations, never approval/fencing providers.
abstract interface class LegacyMigrationBackend {
  Future<void> requireIsolatedExecution();
  LegacyMigrationBackend scoped(void Function() checkValid);
  JournalStorage get storage;
  Future<AndroidLegacySourceInspection> inspect(JournalBinding binding);
  Future<void> cleanup(
    JournalBinding binding,
    List<int> record,
    AndroidLegacySourceInspection source,
  );
  Future<void> verifyCompleted(JournalBinding binding, List<int> record);
}

/// Opt-in isolated migration only: no dispatch, confirmation, compaction, timers
/// or live lifecycle wiring. Queues share SOURCE filenames across instances in
/// this Dart isolate, including different destination environments/auth users.
/// Other isolates/engines/processes require the external exclusive source lease.
class LegacyMigrationCoordinator {
  const LegacyMigrationCoordinator({
    required this.backend,
    required this.contexts,
  });
  final LegacyMigrationBackend backend;
  final LegacyMigrationContexts contexts;
  static final _tails = <String, Future<void>>{};

  Future<LegacyMigrationResult> migrate(JournalBinding binding) async {
    // MUST precede context acquisition, reads (which may normalize), and import.
    try {
      await backend.requireIsolatedExecution();
    } on JournalException catch (error) {
      return _failure(error.issue);
    } catch (_) {
      return _failure(JournalIssue.nativeFailure);
    }
    final name = AndroidLegacyMigration.sourceBasename(binding);
    final previous = _tails[name] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[name] = done.future;
    await previous;
    try {
      return await _attempt(binding, name);
    } finally {
      done.complete();
      if (identical(_tails[name], done.future)) _tails.remove(name);
    }
  }

  Future<LegacyMigrationResult> _attempt(
    JournalBinding binding,
    String name,
  ) async {
    LegacyMigrationContext? context;
    LegacyMigrationResult result;
    try {
      context = await contexts.acquire(binding, name);
      if (context == null) {
        return const LegacyMigrationResult(
          LegacyMigrationOutcome.prerequisitesRequired,
        );
      }
      final lease = context;
      final approval = lease.approval;
      final trust = lease.approvalTrust;
      void check() {
        lease.checkValid();
        if (!lease.binding.matches(binding) || lease.sourceBasename != name) {
          throw const JournalException(JournalIssue.identityMismatch);
        }
        if (!identical(lease.approval, approval) ||
            lease.approvalTrust != trust) {
          throw const LegacyMigrationContextInvalidated();
        }
      }

      check();
      final io = backend.scoped(check);
      final journal = CommandJournal(_ContextStorage(io.storage, check));
      try {
        result = await _execute(binding, approval, trust, io, journal, check);
      } finally {
        // Adapters intentionally map unknown exceptions to safe storage codes.
        // Recheck even on their error path so invalidation remains explicit.
        check();
      }
    } on LegacyMigrationContextInvalidated {
      result = const LegacyMigrationResult(LegacyMigrationOutcome.invalidated);
    } on JournalException catch (error) {
      result = _failure(error.issue);
    } catch (_) {
      result = _failure(JournalIssue.storageFailure);
    }
    // No timeout/finally shortcut releases a fence while submitted work runs.
    try {
      await context?.release();
    } catch (_) {
      return _failure(JournalIssue.storageFailure);
    }
    return result;
  }

  Future<LegacyMigrationResult> _execute(
    JournalBinding binding,
    LegacyBindingApproval? approval,
    LegacyApprovalTrust trust,
    LegacyMigrationBackend io,
    CommandJournal journal,
    void Function() check,
  ) async {
    check();
    final source = await io.inspect(binding);
    check();
    if (!source.binding.matches(binding)) {
      return _failure(JournalIssue.identityMismatch);
    }
    final target = await journal.read(binding);
    check();
    final plan = LegacyJournalMigration.evaluate(
      binding: binding,
      source: source.source,
      target: target,
      approval: approval,
      approvalTrust: trust,
    );
    switch (plan.step) {
      case LegacyMigrationStep.noAction:
        // A readable completed record after a prior failed CAS is insufficient.
        // Reestablish durability, without changing state or claiming attendance.
        final record = plan.existingRecord;
        if (record?.migration?.plaintextCleanupComplete == true) {
          await io.verifyCompleted(binding, JournalCodec.encode(record!));
          check();
          final after = await io.inspect(binding);
          check();
          if (!_absent(after, binding)) {
            return _failure(JournalIssue.commandConflict);
          }
        }
        return LegacyMigrationResult(
          LegacyMigrationOutcome.noAction,
          record: record,
        );
      case LegacyMigrationStep.bindingRequired:
        return const LegacyMigrationResult(
          LegacyMigrationOutcome.bindingRequired,
          issue: JournalIssue.bindingRequired,
        );
      case LegacyMigrationStep.blocked:
        return _failure(plan.issue!);
      case LegacyMigrationStep.importLegacy:
      case LegacyMigrationStep.resumeCleanup:
        break;
    }

    final JournalRecord pending;
    if (plan.step == LegacyMigrationStep.importLegacy) {
      final expected = plan.importRecord!;
      check();
      final imported = await journal.importLegacy(
        binding,
        expected.command!,
        expected.migration!,
        expectedRevision: plan.existingRecord?.revision ?? 0,
        expectedKey: plan.existingRecord?.command?.key,
      );
      check();
      if (imported.issue != null) {
        final observed = await journal.read(binding);
        check();
        if (observed.issue != null) return _failure(observed.issue!);
        if (!_same(observed.record, expected)) {
          return _same(observed.record, plan.existingRecord)
              ? _failure(imported.issue!)
              : _failure(JournalIssue.revisionConflict);
        }
        // Exact readable import may have committed despite a failed reply/sync.
        // Cleanup below MUST perform its own fresh durability barrier.
      } else if (!_same(imported.record, expected)) {
        return _failure(JournalIssue.revisionConflict);
      }
      pending = expected;
    } else {
      pending = plan.existingRecord!;
    }

    check();
    await io.cleanup(binding, JournalCodec.encode(pending), source);
    check();
    final complete = pending.markLegacyCleanupComplete(
      pending.migration!.sourceSha256,
    );
    final written = await journal.markLegacyCleanupComplete(
      binding,
      pending.migration!.sourceSha256,
      expectedRevision: pending.revision,
      expectedKey: pending.command!.key,
    );
    check();
    // Bounded readback, never a retry loop or highest-revision selection.
    final observed = await journal.read(binding);
    check();
    if (observed.issue != null) return _failure(observed.issue!);
    if (!_same(observed.record, complete)) {
      return _same(observed.record, pending) && written.issue != null
          ? _failure(written.issue!)
          : _failure(JournalIssue.revisionConflict);
    }
    // Also handles a failed completion CAS whose bytes are readable but whose
    // synchronization was unconfirmed. Readability alone never means completion.
    await io.verifyCompleted(binding, JournalCodec.encode(complete));
    check();
    final after = await io.inspect(binding);
    check();
    if (!_absent(after, binding)) {
      return _failure(JournalIssue.commandConflict);
    }
    return LegacyMigrationResult(
      LegacyMigrationOutcome.completed,
      record: complete,
    );
  }

  static bool _absent(
    AndroidLegacySourceInspection source,
    JournalBinding binding,
  ) =>
      source.binding.matches(binding) &&
      source.source.bytes == null &&
      source.source.artifacts.isEmpty &&
      source.source.issue == null;

  static bool _same(JournalRecord? a, JournalRecord? b) =>
      a == null || b == null
      ? a == null && b == null
      : JournalRecoveryPlan.sameRecordBytes(
          JournalCodec.encode(a),
          JournalCodec.encode(b),
        );

  static LegacyMigrationResult _failure(JournalIssue issue) =>
      LegacyMigrationResult(
        const {
              JournalIssue.storageFailure,
              JournalIssue.synchronizationFailure,
              JournalIssue.nativeFailure,
            }.contains(issue)
            ? LegacyMigrationOutcome.retryable
            : LegacyMigrationOutcome.blocked,
        issue: issue,
      );
}

/// Checks between CommandJournal's internal read and CAS, not just around its
/// public method. The scoped native backend additionally guards recovery calls.
final class _ContextStorage implements JournalStorage {
  const _ContextStorage(this.delegate, this.check);
  final JournalStorage delegate;
  final void Function() check;
  @override
  Future<JournalStorageRead> read(JournalBinding binding) async {
    check();
    final result = await delegate.read(binding);
    check();
    return result;
  }

  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    check();
    final result = await delegate.compareAndSwap(
      binding: binding,
      expectedRevision: expectedRevision,
      expectedKey: expectedKey,
      replacement: replacement,
    );
    check();
    return result;
  }
}
