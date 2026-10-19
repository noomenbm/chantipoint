import 'dart:async';

import 'attendance_models.dart';
import 'attendance_operation_transport.dart';
import 'journal/command_journal.dart';
import 'journal/journal_command.dart';
import 'journal/journal_json.dart';
import 'journal/journal_record.dart';
import 'journal/journal_recovery.dart';
import 'journal/journal_verifier.dart';

enum AttendanceOperationOutcome {
  confirmed,
  confirmedNeedsRefresh,
  consumed,
  emptyVerified,
  ready,
  invalidated,
  gated,
  unresolved,
}

enum AttendanceOperationProblem {
  legacyCommand,
  migrationPending,
  blockedRecord,
  pendingCommand,
  commandConflict,
  journalUnavailable,
  persistenceUncertain,
  recoveryRequired,
  transportUncertain,
  replayMiss,
  malformedAcknowledgement,
  canonicalUnavailable,
  contextUnavailable,
  consumptionUncertain,
  emptyRecoveryRequired,
}

final class AttendanceOperationSnapshot {
  const AttendanceOperationSnapshot(this.record, this.canonicalSession);
  final JournalRecord record;
  final WorkSession? canonicalSession;
}

/// No UI publication occurs here. Consumers must check isCurrent/snapshot at the
/// point of use, not cache a snapshot across identity changes. Unresolved results
/// never assert durable success, even when matching bytes happen to be readable.
final class AttendanceOperationResult {
  const AttendanceOperationResult._(
    this._outcome,
    this._owner, {
    this.problem,
    this.journalIssue,
    this._snapshot,
  });
  final AttendanceOperationOutcome _outcome;
  final _Owner? _owner;
  final AttendanceOperationProblem? problem;
  final JournalIssue? journalIssue;
  final AttendanceOperationSnapshot? _snapshot;
  bool get isCurrent => _owner?.isCurrent ?? false;
  AttendanceOperationSnapshot? get snapshot => isCurrent ? _snapshot : null;
  AttendanceOperationOutcome get outcome =>
      !isCurrent &&
          const {
            AttendanceOperationOutcome.confirmed,
            AttendanceOperationOutcome.confirmedNeedsRefresh,
            AttendanceOperationOutcome.consumed,
            AttendanceOperationOutcome.emptyVerified,
            AttendanceOperationOutcome.ready,
          }.contains(_outcome)
      ? AttendanceOperationOutcome.invalidated
      : _outcome;
}

/// Isolated C3.1 core. Dependencies have no defaults or production composition.
/// The static full-binding queue covers all instances in THIS Dart isolate only.
/// No cross-isolate/process/restart ownership, migration, timers or
/// live lifecycle wiring. A caller timeout/disposal never cancels this future.
class AttendanceOperationCoordinator {
  AttendanceOperationCoordinator({
    required this.storage,
    required this.transport,
    required this.canonical,
    this.verifier,
  });
  final JournalStorage storage;
  final AttendanceOperationTransport transport;
  final AttendanceCanonicalReader canonical;
  final JournalVerifier? verifier;
  static final _tails = <String, Future<void>>{};
  // Consumption is separate from auth currency, which remains observable by
  // results. Weak keys avoid retaining completed contexts indefinitely.
  static final _usedContexts = Expando<bool>('attendance-attempt');

  // Volatile, per-instance evidence from successful confirmation CAS OR explicit
  // exact-record native recovery. Always compare the COMPLETE reread record.
  // Never restart proof by itself: failed transitions/mismatching refresh reads
  // invalidate it. Reads alone never populate it; canonical failures retain it.
  final _confirmed = <String, List<int>>{};
  final _emptyProof = <String, List<int>>{};
  // Keep the complete original receipt through uncertain compaction. Volatile;
  // after restart, exact tombstone verification proves STATE, not this attempt.
  final _consuming = <String, JournalRecord>{};
  final _seenSlots = <String>{};

  Future<AttendanceOperationResult> submit(
    AttendanceOperationContext context,
    JournalCommand command,
  ) => _run(context, (owner) async {
    if (command.protocol != JournalProtocol.attendanceV2) {
      return _gated(owner, AttendanceOperationProblem.legacyCommand);
    }
    final read = await _read(owner);
    final gate = _gate(owner, read);
    if (gate != null) return gate;
    final current = read.record;
    if (current?.command != null) {
      if (!_sameCommand(current!.command!, command)) {
        return _unresolved(owner, AttendanceOperationProblem.commandConflict);
      }
      return current.phase == JournalPhase.confirmed
          ? _refresh(owner, current)
          : _unresolved(owner, AttendanceOperationProblem.pendingCommand);
    }
    final before = current ?? JournalRecord.absent(owner.identity.binding);
    final emptyGate = _emptyGate(owner, current);
    if (emptyGate != null) return emptyGate;
    _emptyProof.remove(owner.key);
    final prepared = before.prepare(command);
    var issue = await _transition(
      owner,
      current,
      prepared,
      (journal) => journal.prepare(
        owner.identity.binding,
        command,
        expectedRevision: before.revision,
        expectedKey: null,
      ),
      owner.check,
    );
    if (issue != null) return _persistenceFailure(owner, issue);
    final sending = prepared.markMayHaveSent();
    issue = await _transition(
      owner,
      prepared,
      sending,
      (journal) => journal.markMayHaveSent(
        owner.identity.binding,
        expectedRevision: prepared.revision,
        expectedKey: command.key,
      ),
      owner.check,
    );
    if (issue != null) return _persistenceFailure(owner, issue);
    return _dispatch(owner, sending, replayOnly: false);
  });

  /// Query only. A miss never authorizes a new key or a mutating retry. Restored
  /// prepared/confirmed records without verification remain recovery-required.
  Future<AttendanceOperationResult> replay(
    AttendanceOperationContext context,
  ) => _run(context, (owner) async {
    final read = await _read(owner);
    final gate = _gate(owner, read);
    if (gate != null) return gate;
    final record = read.record;
    if (record?.phase == JournalPhase.confirmed) {
      return _refresh(owner, record!);
    }
    if (record == null ||
        !const {
          JournalPhase.mayHaveSent,
          JournalPhase.uncertain,
        }.contains(record.phase)) {
      return _unresolved(owner, AttendanceOperationProblem.recoveryRequired);
    }
    return _dispatch(owner, record, replayOnly: true);
  });

  /// Refresh only; never dispatches. Per-instance CAS evidence must still match.
  Future<AttendanceOperationResult> refresh(
    AttendanceOperationContext context,
  ) => _run(context, (owner) async {
    final read = await _read(owner);
    final gate = _gate(owner, read);
    if (gate != null) return gate;
    if (read.record?.phase != JournalPhase.confirmed) {
      return _unresolved(owner, AttendanceOperationProblem.recoveryRequired);
    }
    return _refresh(owner, read.record!);
  });

  /// Explicit restart/uncertain-confirmation-write recovery. Never dispatches.
  /// A readable receipt alone is not durability evidence. All bytes are frozen
  /// and rechecked across the barrier; only then may canonical refresh proceed.
  Future<AttendanceOperationResult> recoverConfirmed(
    AttendanceOperationContext context,
  ) => _run(context, (owner) async {
    owner.check();
    final stored = await _readRecoveryBytes(owner);
    owner.check();
    final read = stored.issue != null
        ? JournalReadResult.blocked(stored.issue!)
        : stored.bytes == null
        ? const JournalReadResult.absent()
        : JournalCodec.decode(stored.bytes!, owner.identity.binding);
    final gate = _gate(owner, read);
    if (gate != null) return gate;
    final record = read.record;
    if (record?.phase != JournalPhase.confirmed || verifier == null) {
      return _unresolved(owner, AttendanceOperationProblem.recoveryRequired);
    }
    _confirmed.remove(owner.key);
    final expected = List<int>.unmodifiable(stored.bytes!);
    JournalIssue? issue;
    try {
      owner.check();
      issue = await verifier!.verify(owner.identity.binding, expected);
    } catch (_) {
      issue = JournalIssue.nativeFailure;
    }
    owner.check();
    if (issue != null) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.persistenceUncertain,
        journalIssue: issue,
      );
    }
    final after = await _readRecoveryBytes(owner);
    owner.check();
    if (after.issue != null ||
        after.bytes == null ||
        !_bytesEqual(expected, after.bytes!)) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.journalUnavailable,
        journalIssue: after.issue ?? JournalIssue.revisionConflict,
      );
    }
    // Verification grants refresh only, with the same per-instance full-record
    // proof discipline as successful CAS. Canonical failure retains the receipt.
    _confirmed[owner.key] = JournalCodec.encode(record!);
    return _refresh(owner, record);
  });

  Future<JournalStorageRead> _readRecoveryBytes(_Owner owner) async {
    owner.check();
    try {
      return await storage.read(owner.identity.binding);
    } finally {
      owner.check();
    }
  }

  /// Explicit receipt consumption. Only this core can establish the primitive's
  /// attestations: exact durable confirmation AND a fresh canonical read of its
  /// acknowledged session. No arbitrary session/boolean enters this API.
  Future<AttendanceOperationResult> consumeConfirmed(
    AttendanceOperationContext context,
  ) {
    List<int>? requested;
    try {
      final proof = _confirmed[context.identity.binding.storageIdentity];
      if (proof != null) requested = List<int>.unmodifiable(proof);
    } catch (_) {
      // _run still owns malformed-context cleanup.
    }
    // Freeze core-issued consumption authority BEFORE joining the queue. An
    // overlapping request must never consume a newer command queued ahead of it.
    return _run(context, (owner) async {
      final read = await _read(owner);
      final gate = _gate(owner, read);
      if (gate != null) return gate;
      final record = read.record;
      if (record?.phase == JournalPhase.empty || record == null) {
        return _unresolved(
          owner,
          AttendanceOperationProblem.emptyRecoveryRequired,
        );
      }
      if (record.phase != JournalPhase.confirmed) {
        return _unresolved(owner, AttendanceOperationProblem.pendingCommand);
      }
      if (requested == null) {
        return _unresolved(owner, AttendanceOperationProblem.recoveryRequired);
      }
      if (!_bytesEqual(requested, JournalCodec.encode(record))) {
        return _unresolved(owner, AttendanceOperationProblem.commandConflict);
      }
      final previous = _consuming[owner.key];
      if (previous != null && !_sameRecord(previous, record)) {
        return _unresolved(owner, AttendanceOperationProblem.commandConflict);
      }
      final refreshed = await _refresh(owner, record);
      if (refreshed.outcome != AttendanceOperationOutcome.confirmed) {
        return refreshed;
      }
      owner.check();
      final next = record.compactConfirmed(
        canonicalStateVerified: true,
        confirmationConsumed: true,
      );
      _consuming[owner.key] = record;
      _emptyProof.remove(owner.key);
      final JournalIssue? issue;
      try {
        issue = await _transition(
          owner,
          record,
          next,
          (journal) => journal.compactConfirmed(
            owner.identity.binding,
            expectedRevision: record.revision,
            expectedKey: record.command!.key,
            canonicalStateVerified: true,
            confirmationConsumed: true,
          ),
          owner.check,
        );
      } finally {
        _confirmed.remove(owner.key);
      }
      if (issue != null) {
        return _unresolved(
          owner,
          AttendanceOperationProblem.consumptionUncertain,
          journalIssue: issue,
        );
      }
      // CAS includes native durability/readback, followed by an independent full
      // reread before this attempt is allowed to publish consumption completion.
      final after = await _read(owner);
      if (after.issue != null || !_sameRecord(after.record, next)) {
        return _unresolved(
          owner,
          AttendanceOperationProblem.consumptionUncertain,
          journalIssue: after.issue ?? JournalIssue.revisionConflict,
        );
      }
      _emptyProof[owner.key] = JournalCodec.encode(next);
      _consuming.remove(owner.key);
      return AttendanceOperationResult._(
        AttendanceOperationOutcome.consumed,
        owner,
        snapshot: AttendanceOperationSnapshot(next, null),
      );
    });
  }

  /// Explicit recovery of CURRENT empty state, not retrospective proof that an
  /// earlier failed cleanup succeeded. Never writes or consumes another record.
  Future<AttendanceOperationResult> recoverEmpty(
    AttendanceOperationContext context,
  ) => _run(context, (owner) async {
    final stored = await _readRecoveryBytes(owner);
    final read = stored.issue != null
        ? JournalReadResult.blocked(stored.issue!)
        : stored.bytes == null
        ? const JournalReadResult.absent()
        : JournalCodec.decode(stored.bytes!, owner.identity.binding);
    final gate = _gate(owner, read);
    if (gate != null) return gate;
    final record = read.record;
    if (record?.phase != JournalPhase.empty || verifier == null) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.emptyRecoveryRequired,
      );
    }
    _emptyProof.remove(owner.key);
    final original = _consuming[owner.key];
    if (original != null &&
        !_sameRecord(
          record,
          original.compactConfirmed(
            canonicalStateVerified: true,
            confirmationConsumed: true,
          ),
        )) {
      return _unresolved(owner, AttendanceOperationProblem.commandConflict);
    }
    final expected = List<int>.unmodifiable(stored.bytes!);
    JournalIssue? issue;
    try {
      owner.check();
      issue = await verifier!.verify(owner.identity.binding, expected);
    } catch (_) {
      issue = JournalIssue.nativeFailure;
    }
    owner.check();
    if (issue != null) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.consumptionUncertain,
        journalIssue: issue,
      );
    }
    final after = await _readRecoveryBytes(owner);
    if (after.issue != null ||
        after.bytes == null ||
        !_bytesEqual(expected, after.bytes!)) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.consumptionUncertain,
        journalIssue: after.issue ?? JournalIssue.revisionConflict,
      );
    }
    _emptyProof[owner.key] = JournalCodec.encode(record!);
    _consuming.remove(owner.key);
    _confirmed.remove(owner.key);
    return AttendanceOperationResult._(
      AttendanceOperationOutcome.emptyVerified,
      owner,
      snapshot: AttendanceOperationSnapshot(record, null),
    );
  });

  /// Selection and journal gating share the binding queue and context lifetime.
  /// A consumed receipt never supplies the active/no-active answer.
  Future<AttendanceOperationResult> readActive(
    AttendanceOperationContext context,
    AttendanceActiveSessionQuery query,
  ) => _run(context, (owner) async {
    final read = await _read(owner);
    final gate = _gate(owner, read);
    if (gate != null) return gate;
    if (read.record?.command != null) {
      return _unresolved(owner, AttendanceOperationProblem.pendingCommand);
    }
    final emptyGate = _emptyGate(owner, read.record);
    if (emptyGate != null) return emptyGate;
    WorkSession? active;
    try {
      owner.check();
      active = await query.readActiveSession(owner.identity);
    } catch (_) {
      owner.check();
      return _unresolved(
        owner,
        AttendanceOperationProblem.canonicalUnavailable,
      );
    }
    owner.check();
    if (active != null && !active.isActive) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.canonicalUnavailable,
      );
    }
    final after = await _read(owner);
    if (after.issue != null || !_sameRecord(after.record, read.record)) {
      _emptyProof.remove(owner.key);
      return _unresolved(
        owner,
        AttendanceOperationProblem.journalUnavailable,
        journalIssue: after.issue ?? JournalIssue.revisionConflict,
      );
    }
    return AttendanceOperationResult._(
      AttendanceOperationOutcome.ready,
      owner,
      snapshot: AttendanceOperationSnapshot(
        read.record ?? JournalRecord.absent(owner.identity.binding),
        active,
      ),
    );
  });

  AttendanceOperationResult? _emptyGate(_Owner owner, JournalRecord? record) {
    if (record == null && !_seenSlots.contains(owner.key)) return null;
    final proof = _emptyProof[owner.key];
    if (record != null &&
        proof != null &&
        _bytesEqual(proof, JournalCodec.encode(record))) {
      return null;
    }
    return _unresolved(owner, AttendanceOperationProblem.emptyRecoveryRequired);
  }

  Future<AttendanceOperationResult> _dispatch(
    _Owner owner,
    JournalRecord submitted, {
    required bool replayOnly,
  }) async {
    owner.check();
    // Private receipt-only authority is established HERE, while current, for
    // this exact submitted record. No later operation/identity can obtain it.
    final AttendanceTransportReply reply;
    try {
      reply = await transport.dispatch(
        owner.identity,
        submitted.command!,
        replayOnly: replayOnly,
      );
    } catch (_) {
      return _unresolved(owner, AttendanceOperationProblem.transportUncertain);
    }
    if (reply.dataJson == null) {
      return _unresolved(
        owner,
        replayOnly
            ? AttendanceOperationProblem.replayMiss
            : AttendanceOperationProblem.malformedAcknowledgement,
      );
    }
    final JournalConfirmation receipt;
    try {
      receipt = JournalConfirmation(
        source: JournalConfirmationSource.rpcV2,
        dataJson: reply.dataJson!,
        command: submitted.command!,
      );
      if (replayOnly && receipt.data['status'] != 'idempotent_replay') {
        return _unresolved(
          owner,
          AttendanceOperationProblem.malformedAcknowledgement,
        );
      }
    } catch (_) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.malformedAcknowledgement,
      );
    }
    final confirmed = submitted.confirm(receipt);
    // The ONLY post-invalidation mutation allowed: a single exact confirmation
    // CAS for an already-submitted command. _TransitionStorage checks full prior
    // record, replacement, binding, revision and key across internal read/CAS.
    final issue = await _transition(
      owner,
      submitted,
      confirmed,
      (journal) => journal.confirm(
        owner.identity.binding,
        receipt,
        expectedRevision: submitted.revision,
        expectedKey: submitted.command!.key,
      ),
      () {},
    );
    if (issue != null) return _persistenceFailure(owner, issue);
    _confirmed[owner.key] = JournalCodec.encode(confirmed);
    if (!owner.isCurrent) return _invalidated(owner);
    return _refresh(owner, confirmed);
  }

  Future<AttendanceOperationResult> _refresh(
    _Owner owner,
    JournalRecord record,
  ) async {
    owner.check();
    final proof = _confirmed[owner.key];
    if (proof == null || !_bytesEqual(proof, JournalCodec.encode(record))) {
      _confirmed.remove(owner.key);
      return _unresolved(owner, AttendanceOperationProblem.recoveryRequired);
    }
    // Recheck the actual complete record before initiating a canonical read,
    // including when refresh follows an earlier successful confirmation CAS.
    final read = await _read(owner);
    if (read.issue != null || !_sameRecord(read.record, record)) {
      _confirmed.remove(owner.key);
      return _unresolved(
        owner,
        AttendanceOperationProblem.journalUnavailable,
        journalIssue: read.issue ?? JournalIssue.revisionConflict,
      );
    }
    final id = record.confirmation!.data['session_id'] as String;
    WorkSession? session;
    try {
      owner.check();
      session = await canonical.readSession(owner.identity, id);
    } catch (_) {
      owner.check();
    }
    owner.check();
    final available = session != null && session.id == id;
    return AttendanceOperationResult._(
      available
          ? AttendanceOperationOutcome.confirmed
          : AttendanceOperationOutcome.confirmedNeedsRefresh,
      owner,
      problem: available
          ? null
          : AttendanceOperationProblem.canonicalUnavailable,
      snapshot: AttendanceOperationSnapshot(record, available ? session : null),
    );
  }

  Future<JournalReadResult> _read(_Owner owner) async {
    owner.check();
    final result = await CommandJournal(storage).read(owner.identity.binding);
    owner.check();
    return result;
  }

  AttendanceOperationResult? _gate(_Owner owner, JournalReadResult read) {
    if (read.issue != null) {
      return _unresolved(
        owner,
        AttendanceOperationProblem.journalUnavailable,
        journalIssue: read.issue,
      );
    }
    final record = read.record;
    if (record != null) _seenSlots.add(owner.key);
    if (record?.migration?.plaintextCleanupComplete == false) {
      return _gated(owner, AttendanceOperationProblem.migrationPending);
    }
    if (record?.command?.protocol == JournalProtocol.legacyV1) {
      return _gated(owner, AttendanceOperationProblem.legacyCommand);
    }
    if (record?.phase == JournalPhase.blocked) {
      return _gated(owner, AttendanceOperationProblem.blockedRecord);
    }
    return null;
  }

  Future<JournalIssue?> _transition(
    _Owner owner,
    JournalRecord? before,
    JournalRecord next,
    Future<JournalReadResult> Function(CommandJournal) change,
    void Function() check,
  ) async {
    final guarded = _TransitionStorage(storage, before, next, check);
    final result = await change(CommandJournal(guarded));
    check();
    if (result.issue != null ||
        !guarded.casSucceeded ||
        !_sameRecord(result.record, next)) {
      _confirmed.remove(owner.key);
      return result.issue ?? JournalIssue.storageFailure;
    }
    return null;
  }

  Future<AttendanceOperationResult> _run(
    AttendanceOperationContext context,
    Future<AttendanceOperationResult> Function(_Owner) work,
  ) async {
    if (_usedContexts[context] == true) {
      // The original attempt alone owns release, even while still in flight.
      return const AttendanceOperationResult._(
        AttendanceOperationOutcome.unresolved,
        null,
        problem: AttendanceOperationProblem.contextUnavailable,
      );
    }
    _usedContexts[context] = true;
    final _Owner owner;
    try {
      owner = _Owner(context);
    } catch (_) {
      try {
        await context.release();
      } catch (_) {
        /* No submitted work. */
      }
      return const AttendanceOperationResult._(
        AttendanceOperationOutcome.unresolved,
        null,
        problem: AttendanceOperationProblem.contextUnavailable,
      );
    }
    final prior = _tails[owner.key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[owner.key] = done.future;
    await prior;
    try {
      AttendanceOperationResult result;
      try {
        owner.check();
        result = await work(owner);
      } on _InvalidContext {
        result = _invalidated(owner);
      } catch (_) {
        result = _unresolved(
          owner,
          AttendanceOperationProblem.journalUnavailable,
        );
      }
      // Await ALL submitted work, including receipt-only finalization and release.
      // There is no timeout or disposal shortcut that cancels it/frees the queue.
      try {
        await context.release();
      } catch (_) {
        return _unresolved(
          owner,
          AttendanceOperationProblem.contextUnavailable,
        );
      }
      return result;
    } finally {
      done.complete();
      if (identical(_tails[owner.key], done.future)) _tails.remove(owner.key);
    }
  }

  AttendanceOperationResult _persistenceFailure(
    _Owner owner,
    JournalIssue issue,
  ) => _unresolved(
    owner,
    AttendanceOperationProblem.persistenceUncertain,
    journalIssue: issue,
  );
  static AttendanceOperationResult _unresolved(
    _Owner owner,
    AttendanceOperationProblem problem, {
    JournalIssue? journalIssue,
  }) => AttendanceOperationResult._(
    AttendanceOperationOutcome.unresolved,
    owner,
    problem: problem,
    journalIssue: journalIssue,
  );
  static AttendanceOperationResult _gated(
    _Owner owner,
    AttendanceOperationProblem problem,
  ) => AttendanceOperationResult._(
    AttendanceOperationOutcome.gated,
    owner,
    problem: problem,
  );
  static AttendanceOperationResult _invalidated(_Owner owner) =>
      AttendanceOperationResult._(
        AttendanceOperationOutcome.invalidated,
        owner,
      );
}

class _InvalidContext implements Exception {}

final class _Owner {
  _Owner(this.context) : identity = context.identity;
  final AttendanceOperationContext context;
  final AttendanceOperationIdentity identity;
  String get key => identity.binding.storageIdentity;
  bool get isCurrent {
    try {
      return context.isCurrent &&
          context.identity.generation == identity.generation &&
          context.identity.binding.matches(identity.binding);
    } catch (_) {
      return false;
    }
  }

  void check() {
    if (!isCurrent) throw _InvalidContext();
  }
}

bool _bytesEqual(List<int> a, List<int> b) =>
    JournalRecoveryPlan.sameRecordBytes(a, b);
bool _sameRecord(JournalRecord? a, JournalRecord? b) => a == null || b == null
    ? a == null && b == null
    : _bytesEqual(JournalCodec.encode(a), JournalCodec.encode(b));
bool _sameCommand(JournalCommand a, JournalCommand b) =>
    a.protocol == b.protocol &&
    a.operation == b.operation &&
    a.key == b.key &&
    a.parametersJson == b.parametersJson;

/// Exact, single-transition capability, also covering CommandJournal's internal
/// asynchronous read/CAS gap. Receipt finalization uses this without an auth
/// check, but can write ONLY its previously submitted record's exact receipt.
final class _TransitionStorage implements JournalStorage {
  _TransitionStorage(this.delegate, this.before, this.next, this.check);
  final JournalStorage delegate;
  final JournalRecord? before;
  final JournalRecord next;
  final void Function() check;
  bool casSucceeded = false;
  @override
  Future<JournalStorageRead> read(JournalBinding binding) async {
    check();
    if (!binding.matches(next.binding)) {
      return const JournalStorageRead.failure(JournalIssue.identityMismatch);
    }
    final read = await delegate.read(binding);
    check();
    if (read.issue != null) return read;
    final actual = read.bytes == null
        ? const JournalReadResult.absent()
        : JournalCodec.decode(read.bytes!, binding);
    if (actual.issue != null) return JournalStorageRead.failure(actual.issue!);
    return _sameRecord(actual.record, before)
        ? read
        : const JournalStorageRead.failure(JournalIssue.revisionConflict);
  }

  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    check();
    if (!binding.matches(next.binding) ||
        expectedRevision != (before?.revision ?? 0) ||
        expectedKey != before?.command?.key ||
        !_bytesEqual(replacement, JournalCodec.encode(next))) {
      return JournalIssue.revisionConflict;
    }
    final issue = await delegate.compareAndSwap(
      binding: binding,
      expectedRevision: expectedRevision,
      expectedKey: expectedKey,
      replacement: replacement,
    );
    casSucceeded = issue == null;
    check();
    return issue;
  }
}
