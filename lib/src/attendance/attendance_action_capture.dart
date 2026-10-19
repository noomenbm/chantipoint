import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'attendance_models.dart';
import 'attendance_operation_transport.dart';
import 'attendance_v2_requests.dart';
import 'foreground_location.dart';
import 'journal/journal_command.dart';
import 'journal/journal_json.dart';
import 'location_evidence.dart';

abstract interface class AttendanceActionClock {
  DateTime now();
}

abstract interface class AttendanceActionKeys {
  String next();
}

final class SystemAttendanceActionClock implements AttendanceActionClock {
  const SystemAttendanceActionClock();
  @override
  DateTime now() => DateTime.now().toUtc();
}

final class SecureAttendanceActionKeys implements AttendanceActionKeys {
  SecureAttendanceActionKeys() : _random = Random.secure();
  final Random _random;
  @override
  String next() =>
      base64Url.encode(List.generate(24, (_) => _random.nextInt(256)));
}

enum AttendanceCaptureStatus {
  captured,
  busy,
  invalidated,
  invalidInput,
  contextUnavailable,
  closed,
}

final class AttendanceCaptureResult {
  const AttendanceCaptureResult(this._status, [this._action]);
  final AttendanceCaptureStatus _status;
  final CapturedAttendanceAction? _action;
  AttendanceCaptureStatus get status => _action != null && !_action.isCurrent
      ? AttendanceCaptureStatus.invalidated
      : _status;
  CapturedAttendanceAction? get action =>
      _action?.isCurrent == true ? _action : null;

  /// Release the original unsubmitted capture even if invalidation now hides
  /// its action. Never releases ownership already handed to the coordinator.
  Future<void> abandon() => _action?.abandon() ?? Future<void>.value();
}

/// A single explicit handoff, NOT a dispatch. Only the coordinator may release
/// the returned context after all submitted work/late-receipt finalization.
final class CapturedAttendanceSubmission {
  const CapturedAttendanceSubmission(this.command, this.context);
  final JournalCommand command;
  final AttendanceOperationContext context;
}

final class CapturedAttendanceAction {
  CapturedAttendanceAction._(this._owner, this._command, this._sessionCurrent);
  final _CaptureOwner _owner;
  final JournalCommand _command;
  final bool Function() _sessionCurrent;
  bool _handed = false;
  bool _abandoned = false;
  Future<void>? _abandoning;
  bool get isCurrent =>
      !_abandoned && _owner.isCurrent && _safe(_sessionCurrent);
  JournalCommand? get command => isCurrent ? _command : null;

  CapturedAttendanceSubmission? handoff() {
    if (_handed || !isCurrent) return null;
    _handed = true;
    return CapturedAttendanceSubmission(_command, _SubmittedContext(_owner));
  }

  /// No-op after handoff: screen/caller disposal cannot release submitted work.
  Future<void> abandon() {
    if (_handed) return Future.value();
    _abandoned = true;
    return _abandoning ??= _owner.release();
  }
}

/// One pending acquisition/ready intent/submission per capture instance. No
/// default composition, journal writes, RPCs, classification or note-save API.
/// Future UI must additionally honor server/outbox state before a new action.
final class AttendanceActionCapture {
  static const siteDescriptionLimit = 500;
  static const finalNoteLimit = 1000;

  AttendanceActionCapture({
    required this.location,
    required this.clock,
    required this.keys,
  });
  final ForegroundLocationAcquisition location;
  final AttendanceActionClock clock;
  final AttendanceActionKeys keys;
  static final _consumed = Expando<bool>('attendance-action-context');
  bool _closed = false;
  Completer<void>? _attemptDone;
  CapturedAttendanceAction? _ready;
  bool get isBusy => _attemptDone != null;

  Future<AttendanceCaptureResult> checkIn({
    required AttendanceOperationContext context,
    String? siteDescription,
  }) => _capture(
    context,
    null,
    siteDescription,
    const CheckoutNoteIntent.preserve(),
    () => true,
  );

  Future<AttendanceCaptureResult> checkOut({
    required AttendanceOperationContext context,
    required WorkSession activeSession,
    required bool Function(String originalSessionId) isSessionCurrent,
    CheckoutNoteIntent note = const CheckoutNoteIntent.preserve(),
  }) {
    // Read the original session once, synchronously, never a post-await getter.
    final id = activeSession.id;
    final active = activeSession.isActive;
    return _capture(
      context,
      id,
      null,
      note,
      () => active && isSessionCurrent(id),
    );
  }

  Future<AttendanceCaptureResult> _capture(
    AttendanceOperationContext context,
    String? sessionId,
    String? description,
    CheckoutNoteIntent note,
    bool Function() sessionCurrent,
  ) async {
    if (_consumed[context] == true) {
      return const AttendanceCaptureResult(
        AttendanceCaptureStatus.contextUnavailable,
      );
    }
    _consumed[context] = true;
    if (_closed || isBusy) {
      try {
        await context.release();
      } catch (_) {
        return const AttendanceCaptureResult(
          AttendanceCaptureStatus.contextUnavailable,
        );
      }
      return AttendanceCaptureResult(
        _closed ? AttendanceCaptureStatus.closed : AttendanceCaptureStatus.busy,
      );
    }
    final done = Completer<void>();
    _attemptDone = done;
    void complete() {
      _ready = null;
      _attemptDone = null;
      if (!done.isCompleted) done.complete();
    }

    _CaptureOwner? owner;
    try {
      owner = _CaptureOwner(context, complete);
      if (!owner.isCurrent || !_safe(sessionCurrent)) {
        await owner.release();
        return const AttendanceCaptureResult(
          AttendanceCaptureStatus.invalidated,
        );
      }
      // Capture EVERY input once before the first acquisition/permission await.
      final time = clock.now().toUtc();
      final key = keys.next();
      final frozenNote = switch (note.action) {
        CheckoutNoteAction.preserve => const CheckoutNoteIntent.preserve(),
        CheckoutNoteAction.clear => const CheckoutNoteIntent.clear(),
        CheckoutNoteAction.replace => CheckoutNoteIntent.replace(note.text!),
      };
      journalTimestamp(time.toIso8601String());
      journalText(key, max: 160);
      if (key.length < 8 || key.trim() != key) invalidJournal();
      if (description != null) {
        journalText(description, max: siteDescriptionLimit, empty: true);
      }
      if (frozenNote.text != null) {
        journalText(frozenNote.text, max: finalNoteLimit, empty: true);
      }
      if (sessionId != null &&
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(sessionId)) {
        invalidJournal();
      }
      if (!owner.isCurrent || !_safe(sessionCurrent) || _closed) {
        await owner.release();
        return const AttendanceCaptureResult(
          AttendanceCaptureStatus.invalidated,
        );
      }
      LocationEvidence evidence;
      try {
        evidence = await location.acquire(
          isCurrent: () =>
              owner!.isCurrent && _safe(sessionCurrent) && !_closed,
        );
      } catch (_) {
        evidence = const LocationEvidence(
          result: LocationAcquisitionResult.providerError,
        );
      }
      if (!owner.isCurrent || !_safe(sessionCurrent) || _closed) {
        await owner.release();
        return const AttendanceCaptureResult(
          AttendanceCaptureStatus.invalidated,
        );
      }
      final command = sessionId == null
          ? JournalCommand.checkInV2(
              CheckInV2Request(
                idempotencyKey: key,
                deviceObservedAt: time,
                siteDescription: description,
                evidence: evidence,
              ),
            )
          : JournalCommand.checkOutV2(
              CheckOutV2Request(
                workSessionId: sessionId,
                idempotencyKey: key,
                deviceObservedAt: time,
                evidence: evidence,
                noteIntent: frozenNote,
              ),
            );
      final action = CapturedAttendanceAction._(owner, command, sessionCurrent);
      _ready = action;
      return AttendanceCaptureResult(AttendanceCaptureStatus.captured, action);
    } catch (_) {
      try {
        if (owner != null) {
          await owner.release();
        } else {
          try {
            await context.release();
          } finally {
            complete();
          }
        }
      } catch (_) {
        return const AttendanceCaptureResult(
          AttendanceCaptureStatus.contextUnavailable,
        );
      }
      return AttendanceCaptureResult(
        owner == null
            ? AttendanceCaptureStatus.contextUnavailable
            : AttendanceCaptureStatus.invalidInput,
      );
    }
  }

  /// Waits for acquisition/submitted settlement. Does not cancel a native fix or
  /// release a context already handed to a coordinator.
  Future<void> close() async {
    _closed = true;
    final done = _attemptDone?.future;
    await _ready?.abandon();
    await done;
  }
}

bool _safe(bool Function() read) {
  try {
    return read();
  } catch (_) {
    return false;
  }
}

final class _CaptureOwner {
  _CaptureOwner(this.context, this.complete) : identity = context.identity;
  final AttendanceOperationContext context;
  final AttendanceOperationIdentity identity;
  final void Function() complete;
  Future<void>? _releasing;
  bool get isCurrent => _safe(
    () =>
        context.isCurrent &&
        context.identity.generation == identity.generation &&
        context.identity.binding.matches(identity.binding),
  );
  Future<void> release() => _releasing ??= _release();
  Future<void> _release() async {
    try {
      await context.release();
    } finally {
      complete();
    }
  }
}

final class _SubmittedContext implements AttendanceOperationContext {
  const _SubmittedContext(this.owner);
  final _CaptureOwner owner;
  @override
  AttendanceOperationIdentity get identity => owner.identity;
  @override
  bool get isCurrent => owner.isCurrent;
  @override
  Future<void> release() => owner.release();
}
