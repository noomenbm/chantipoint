import 'dart:async';

import '../attendance_models.dart';
import '../attendance_operation_coordinator.dart';
import '../attendance_operation_transport.dart';
import '../journal/command_journal.dart';
import '../journal/journal_command.dart';
import '../journal/journal_json.dart';
import '../journal/journal_record.dart';
import 'session_note_ports.dart';
import 'session_note_record.dart';

enum NoteOperationOutcome {
  applied,
  notApplied,
  terminalNeedsRefresh,
  uncertain,
  blocked,
  invalidated,
  checkoutFinished,
  attendanceFinished,
}

enum NoteOperationProblem {
  storage,
  pending,
  checkoutPending,
  conflict,
  attendancePending,
  canonical,
  context,
  transport,
}

final class NoteOperationResult {
  const NoteOperationResult._(
    this._outcome,
    this._owner, {
    this.problem,
    this._receipt,
    this._session,
    this._attendance,
  });
  final NoteOperationOutcome _outcome;
  final _Attempt? _owner;
  final NoteOperationProblem? problem;
  final SessionNoteReceipt? _receipt;
  final WorkSession? _session;
  final AttendanceOperationResult? _attendance;
  bool get isCurrent => _owner?.current ?? false;
  NoteOperationOutcome get outcome => _owner != null && !isCurrent
      ? NoteOperationOutcome.invalidated
      : _outcome;
  SessionNoteReceipt? get receipt => isCurrent ? _receipt : null;
  WorkSession? get session => isCurrent ? _session : null;
  AttendanceOperationResult? get attendance => isCurrent ? _attendance : null;
}

/// Application-lifetime note and checkout boundary, used by normal composition.
/// Shared isolate queue plus durable native CAS reservations; all cooperating note
/// and checkout callers must use this boundary. It does not fence legacy writers.
final class SessionNoteCoordinator {
  SessionNoteCoordinator({
    required this.storage,
    required this.transport,
    required this.canonical,
    required this.attendance,
    required this.issueContext,
    this.requireV2 = false,
  });
  final SessionNoteStorage storage;
  final SessionNoteTransport transport;
  final AttendanceCanonicalReader canonical;
  final AttendanceOperationCoordinator attendance;
  final AttendanceOperationContext Function() issueContext;
  final bool requireV2;
  static final _tails = <String, Future<void>>{};
  static final _used = Expando<bool>('note-attempt');
  final _seen = <String>{};

  Future<NoteOperationResult> save(
    AttendanceOperationContext context,
    SessionNoteCommand command,
  ) => _run(context, (owner) async {
    if (!command.identity.binding.matches(owner.identity.binding) ||
        (requireV2 && command.contractVersion != 2) ||
        command.identity.generation != owner.identity.generation) {
      return _blocked(owner, NoteOperationProblem.conflict);
    }
    var record = await _read(owner);
    if (record.phase == SessionNotePhase.pending) {
      return _blocked(owner, NoteOperationProblem.pending);
    }
    if (record.phase == SessionNotePhase.checkout) {
      return _blocked(owner, NoteOperationProblem.checkoutPending);
    }
    if (record.command?.key == command.key) {
      if (!record.command!.same(command)) {
        return _blocked(owner, NoteOperationProblem.conflict);
      }
      return _terminal(owner, record);
    }
    if (record.phase == SessionNotePhase.terminal) {
      final settled = await _terminal(owner, record);
      if (settled.session == null) return settled;
    }
    await _attendanceClear(owner);
    owner.requireCurrent();
    final pending = record.prepare(command);
    await _write(record, pending);
    record = pending;
    owner.requireCurrent();
    // No note POST precedes durable pending CAS + exact verification.
    return _dispatch(owner, record, replayOnly: false);
  });

  /// Explicit reauthorization, same full binding only. Original generation and
  /// request bytes stay unchanged; a fresh login can ONLY replay retained work.
  Future<NoteOperationResult> recover(AttendanceOperationContext context) =>
      _run(context, (owner) async {
        final record = await _read(owner);
        if (record.phase == SessionNotePhase.terminal) {
          return _terminal(owner, record);
        }
        if (record.phase != SessionNotePhase.pending) {
          return _blocked(
            owner,
            record.phase == SessionNotePhase.checkout
                ? NoteOperationProblem.checkoutPending
                : NoteOperationProblem.pending,
          );
        }
        await _verify(record);
        await _attendanceClear(owner);
        owner.requireCurrent();
        return _dispatch(owner, record, replayOnly: true);
      });

  /// Normal composition routes selection, check-in and receipt consumption
  /// through the same binding queue. A checkout lease must settle first.
  Future<NoteOperationResult> attendanceOperation(
    AttendanceOperationContext context,
    Future<AttendanceOperationResult> Function(AttendanceOperationContext)
    action,
  ) => _run(context, (owner) async {
    final record = await _read(owner);
    if (record.phase == SessionNotePhase.pending ||
        record.phase == SessionNotePhase.checkout) {
      return _blocked(
        owner,
        record.phase == SessionNotePhase.checkout
            ? NoteOperationProblem.checkoutPending
            : NoteOperationProblem.pending,
      );
    }
    if (record.phase == SessionNotePhase.terminal &&
        (await _terminal(owner, record)).session == null) {
      return _blocked(owner, NoteOperationProblem.canonical);
    }
    owner.requireCurrent();
    final child = issueContext();
    var transferred = false;
    try {
      if (identical(child, context) ||
          !child.isCurrent ||
          child.identity.generation != owner.identity.generation ||
          !child.identity.binding.matches(owner.identity.binding)) {
        throw const _Gate(NoteOperationProblem.context);
      }
      transferred = true;
      final result = await action(child);
      return NoteOperationResult._(
        NoteOperationOutcome.attendanceFinished,
        owner,
        attendance: result,
      );
    } finally {
      if (!transferred && !identical(child, context)) await child.release();
    }
  });

  Future<NoteOperationResult> _dispatch(
    _Attempt owner,
    SessionNoteRecord pending, {
    required bool replayOnly,
  }) async {
    SessionNoteReceipt receipt;
    try {
      receipt = await transport.saveNote(
        owner.identity,
        pending.command!,
        replayOnly: replayOnly,
      );
      // Validate even injected ports: no malformed/mismatched proof can persist.
      receipt = SessionNoteReceipt.parse(receipt.json, pending.command!);
    } catch (_) {
      return NoteOperationResult._(
        NoteOperationOutcome.uncertain,
        owner,
        problem: NoteOperationProblem.transport,
      );
    }
    // Submitted work retains ORIGINAL storage binding and ownership, even after
    // auth invalidation. Never issue a stale canonical read, but keep late proof.
    final terminal = pending.confirm(receipt);
    await _write(pending, terminal);
    return _terminal(owner, terminal);
  }

  Future<NoteOperationResult> _terminal(
    _Attempt owner,
    SessionNoteRecord record,
  ) async {
    await _verify(
      record,
    ); // Also required after restart/reported storage failure.
    owner.requireCurrent();
    WorkSession? session;
    try {
      session = await canonical.readSession(
        owner.identity,
        record.command!.sessionId,
      );
      owner.requireCurrent();
      if (session == null || session.id != record.command!.sessionId) {
        throw const _Gate(NoteOperationProblem.canonical);
      }
    } catch (_) {
      return NoteOperationResult._(
        NoteOperationOutcome.terminalNeedsRefresh,
        owner,
        problem: NoteOperationProblem.canonical,
        receipt: record.receipt,
      );
    }
    return NoteOperationResult._(
      record.receipt!.outcome == SessionNoteOutcome.applied
          ? NoteOperationOutcome.applied
          : NoteOperationOutcome.notApplied,
      owner,
      receipt: record.receipt,
      session: session,
    );
  }

  /// Durable checkout reservation, NOT another attendance outbox. The original
  /// note context remains owned while C3 consumes its own separately issued child.
  Future<NoteOperationResult> checkOut(
    AttendanceOperationContext context,
    JournalCommand command,
  ) => _run(context, (owner) async {
    if (command.protocol != JournalProtocol.attendanceV2 ||
        command.operation != AttendanceCommandKind.checkOut) {
      return _blocked(owner, NoteOperationProblem.conflict);
    }
    final before = await _read(owner);
    if (before.phase == SessionNotePhase.pending ||
        before.phase == SessionNotePhase.checkout) {
      return _blocked(owner, NoteOperationProblem.pending);
    }
    if (before.phase == SessionNotePhase.terminal &&
        (await _terminal(owner, before)).session == null) {
      return _blocked(owner, NoteOperationProblem.canonical);
    }
    await _attendanceClear(owner);
    owner.requireCurrent();
    final lease = before.reserveCheckout(
      SessionNoteCheckout(
        sessionId: command.parameters['p_work_session_id'] as String,
        key: command.key,
        commandSha256: SessionNoteCheckout.fingerprint(command),
        generation: owner.identity.generation,
      ),
    );
    await _write(before, lease);
    return _checkout(
      owner,
      lease,
      (child) => attendance.submit(child, command),
    );
  });

  /// Pending attendance uses C3's unchanged replay/proof recovery. Prepared,
  /// missing, changed, consumed or unreadable attendance evidence stays blocked:
  /// this foundation never guesses away a checkout reservation.
  Future<NoteOperationResult> recoverCheckout(
    AttendanceOperationContext context,
  ) => _run(context, (owner) async {
    final lease = await _read(owner);
    if (lease.phase != SessionNotePhase.checkout) {
      return _blocked(owner, NoteOperationProblem.checkoutPending);
    }
    await _verify(lease);
    final read = await CommandJournal(attendance.storage)
        .read(owner.identity.binding);
    final record = read.record;
    if (read.isBlocked ||
        record?.command?.protocol != JournalProtocol.attendanceV2 ||
        record?.command?.operation != AttendanceCommandKind.checkOut ||
        record?.command?.key != lease.checkout!.key ||
        record?.command?.parameters['p_work_session_id'] !=
            lease.checkout!.sessionId ||
        (record?.command != null &&
            SessionNoteCheckout.fingerprint(record!.command!) !=
                lease.checkout!.commandSha256)) {
      return _blocked(owner, NoteOperationProblem.attendancePending);
    }
    if (record!.phase == JournalPhase.confirmed) {
      return _checkout(owner, lease, attendance.recoverConfirmed);
    }
    if (const {
      JournalPhase.uncertain,
      JournalPhase.mayHaveSent,
    }.contains(record.phase)) {
      return _checkout(owner, lease, attendance.replay);
    }
    return _blocked(owner, NoteOperationProblem.attendancePending);
  });

  Future<NoteOperationResult> _checkout(
    _Attempt owner,
    SessionNoteRecord lease,
    Future<AttendanceOperationResult> Function(AttendanceOperationContext)
    submit,
  ) async {
    owner.requireCurrent();
    final child = issueContext();
    if (identical(child, owner.context)) {
      throw const _Gate(NoteOperationProblem.context);
    }
    var transferred = false;
    late final AttendanceOperationResult result;
    try {
      if (!_Attempt(child, child.identity, transport).current ||
          child.identity.generation != owner.identity.generation ||
          !child.identity.binding.matches(owner.identity.binding)) {
        throw const _Gate(NoteOperationProblem.context);
      }
      owner.requireCurrent();
      // C3 consumes/releases child. Parent spans reservation cleanup as well.
      transferred = true;
      result = await submit(child);
    } finally {
      if (!transferred) await child.release();
    }
    owner.requireCurrent();
    final canonical = result.snapshot?.canonicalSession;
    if (result.outcome != AttendanceOperationOutcome.confirmed ||
        canonical == null ||
        canonical.id != lease.checkout!.sessionId ||
        canonical.isActive) {
      return NoteOperationResult._(
        NoteOperationOutcome.blocked,
        owner,
        problem: NoteOperationProblem.checkoutPending,
        attendance: result,
      );
    }
    await _write(lease, lease.releaseCheckout());
    return NoteOperationResult._(
      NoteOperationOutcome.checkoutFinished,
      owner,
      session: canonical,
      attendance: result,
    );
  }

  Future<void> _attendanceClear(_Attempt owner) async {
    final read = await CommandJournal(attendance.storage)
        .read(owner.identity.binding);
    if (read.isBlocked ||
        read.record?.command != null ||
        read.record?.migration?.plaintextCleanupComplete == false) {
      throw const _Gate(NoteOperationProblem.attendancePending);
    }
    if (read.record != null) {
      // Restore C3's OWN exact empty-state proof, not just an independent note
      // verifier check. Otherwise a cold recovered note could reserve checkout
      // before C3 rejects its still-unverified empty tombstone.
      owner.requireCurrent();
      final child = issueContext();
      if (identical(child, owner.context)) {
        throw const _Gate(NoteOperationProblem.context);
      }
      var transferred = false;
      try {
        if (!_Attempt(child, child.identity, transport).current ||
            child.identity.generation != owner.identity.generation ||
            !child.identity.binding.matches(owner.identity.binding)) {
          throw const _Gate(NoteOperationProblem.context);
        }
        transferred = true;
        final proof = await attendance.recoverEmpty(child);
        owner.requireCurrent();
        if (proof.outcome != AttendanceOperationOutcome.emptyVerified) {
          throw const _Gate(NoteOperationProblem.attendancePending);
        }
      } finally {
        if (!transferred) await child.release();
      }
      final again = await CommandJournal(attendance.storage)
          .read(owner.identity.binding);
      if (again.record == null ||
          JournalJson.encode(again.record!.toJson()) !=
              JournalJson.encode(read.record!.toJson())) {
        throw const _Gate(NoteOperationProblem.attendancePending);
      }
    }
    owner.requireCurrent();
  }

  Future<SessionNoteRecord> _read(_Attempt owner) async {
    final binding = owner.identity.binding;
    final read = await storage.read(binding);
    if (read == null) {
      if (_seen.contains(binding.storageIdentity)) {
        throw const _Gate(NoteOperationProblem.storage);
      }
      return SessionNoteRecord.absent(binding);
    }
    _seen.add(binding.storageIdentity);
    final record = SessionNoteRecord.decode(read.bytes, binding);
    if (requireV2 &&
        record.command != null &&
        record.command!.contractVersion != 2) {
      throw const _Gate(NoteOperationProblem.storage);
    }
    return record;
  }

  Future<void> _verify(SessionNoteRecord record) async {
    await storage.verify(record);
    final again = await storage.read(record.binding);
    if (again == null || !_same(again, record)) {
      throw const _Gate(NoteOperationProblem.storage);
    }
  }

  static bool _same(SessionNoteRecord a, SessionNoteRecord b) =>
      JournalJson.encode(a.toJson()) == JournalJson.encode(b.toJson());
  Future<void> _write(SessionNoteRecord before, SessionNoteRecord next) async {
    await storage.compareAndSwap(before, next);
    _seen.add(next.binding.storageIdentity);
    await _verify(next);
  }

  static NoteOperationResult _blocked(
    _Attempt owner,
    NoteOperationProblem problem,
  ) => NoteOperationResult._(
    NoteOperationOutcome.blocked,
    owner,
    problem: problem,
  );
  Future<NoteOperationResult> _run(
    AttendanceOperationContext context,
    Future<NoteOperationResult> Function(_Attempt) action,
  ) async {
    if (_used[context] == true) {
      return const NoteOperationResult._(
        NoteOperationOutcome.blocked,
        null,
        problem: NoteOperationProblem.context,
      );
    }
    _used[context] = true;
    _Attempt? owner;
    Completer<void>? done;
    String? key;
    NoteOperationResult result;
    try {
      owner = _Attempt(context, context.identity, transport);
      key = owner.identity.binding.storageIdentity;
      final previous = _tails[key];
      done = Completer<void>();
      _tails[key] = done.future;
      await previous;
      owner.requireCurrent();
      result = await action(owner);
    } on _InvalidContext {
      result = NoteOperationResult._(
        NoteOperationOutcome.invalidated,
        owner,
        problem: NoteOperationProblem.context,
      );
    } on _Gate catch (error) {
      result = NoteOperationResult._(
        NoteOperationOutcome.blocked,
        owner,
        problem: error.problem,
      );
    } catch (_) {
      result = NoteOperationResult._(
        NoteOperationOutcome.uncertain,
        owner,
        problem: NoteOperationProblem.storage,
      );
    } finally {
      // Release only after all local storage/network work settles, even if the
      // caller times out, auth changes, or its route disappears.
      try {
        await context.release();
      } catch (_) {
        // No data or provider error escapes. The result cannot claim success.
        owner = null;
      }
      if (done != null) {
        if (identical(_tails[key], done.future)) _tails.remove(key);
        done.complete();
      }
    }
    return owner == null
        ? const NoteOperationResult._(
            NoteOperationOutcome.blocked,
            null,
            problem: NoteOperationProblem.context,
          )
        : result;
  }
}

final class _Attempt {
  const _Attempt(this.context, this.identity, this.transport);
  final AttendanceOperationContext context;
  final AttendanceOperationIdentity identity;
  final SessionNoteTransport transport;
  bool get current {
    try {
      return context.isCurrent &&
          context.identity.generation == identity.generation &&
          context.identity.binding.matches(identity.binding) &&
          transport.authority.isCurrent(identity);
    } catch (_) {
      return false;
    }
  }

  void requireCurrent() {
    if (!current) throw const _InvalidContext();
  }
}

final class _InvalidContext implements Exception {
  const _InvalidContext();
}

final class _Gate implements Exception {
  const _Gate(this.problem);
  final NoteOperationProblem problem;
}
