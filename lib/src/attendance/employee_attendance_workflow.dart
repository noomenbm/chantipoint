import 'dart:async';

import 'package:flutter/foundation.dart';

import 'attendance_action_capture.dart';
import 'attendance_models.dart';
import 'attendance_operation_coordinator.dart';
import 'attendance_operation_transport.dart';
import 'attendance_v2_requests.dart';
import 'journal/command_journal.dart';
import 'journal/journal_command.dart';
import 'journal/journal_json.dart';
import 'journal/journal_record.dart';
import 'integration/attendance_integration_guard.dart';

/// Injected canonical read, not the legacy repository's current-account lookup.
/// Implementations must scope by the full identity, enforce authorization and
/// reject stale/wrong-owner results. Null means an authorized empty selection.
/// The synchronous observation checks the ORIGINAL checkout session; it must
/// never establish authorization merely from matching session UUIDs.
abstract interface class AttendanceActiveSessionReader
    implements Listenable, AttendanceActiveSessionQuery {
  /// Monotonic revision for changes known outside an in-flight read. A delayed
  /// query cannot overwrite a newer observation. Reading alone does not advance
  /// this revision; it establishes no authorization or backend truth itself.
  int get revision;
  @override
  Future<WorkSession?> readActiveSession(AttendanceOperationIdentity identity);
  bool isSessionCurrent(AttendanceOperationIdentity identity, String sessionId);
}

enum EmployeeAttendanceStatus {
  loading,
  ready,
  acquiringLocation,
  awaitingConfirmation,
  confirmed,
  pending,
  blocked,
  authorizationUnavailable,
  refreshUnavailable,
  confirmedNeedsRefresh,
  invalidInput,
  consumingConfirmation,
  consumptionUnresolved,
}

enum AttendanceInputError {
  descriptionTooLong,
  noteTooLong,
  invalidText,
  invalidCapture;

  String get message => switch (this) {
    descriptionTooLong =>
      'La description du lieu ne doit pas dépasser '
          '${AttendanceActionCapture.siteDescriptionLimit} caractères Unicode. '
          'Un accent décomposé peut compter pour plusieurs caractères.',
    noteTooLong =>
      'La note finale ne doit pas dépasser '
          '${AttendanceActionCapture.finalNoteLimit} caractères Unicode. '
          'Un accent décomposé peut compter pour plusieurs caractères.',
    invalidText =>
      'Le texte contient un caractère non pris en charge. '
          'Corrigez la description ou la note avant de réessayer.',
    invalidCapture =>
      'Les informations de ce pointage sont invalides. '
          'Vérifiez votre saisie avant de réessayer.',
  };
}

/// Exactly C4's text contract. Never truncates, trims or normalizes the input.
AttendanceInputError? validateAttendanceInput({
  String? siteDescription,
  CheckoutNoteIntent note = const CheckoutNoteIntent.preserve(),
}) {
  if (siteDescription != null &&
      siteDescription.runes.length >
          AttendanceActionCapture.siteDescriptionLimit) {
    return AttendanceInputError.descriptionTooLong;
  }
  if (note.action == CheckoutNoteAction.replace &&
      note.text!.runes.length > AttendanceActionCapture.finalNoteLimit) {
    return AttendanceInputError.noteTooLong;
  }
  try {
    if (siteDescription != null) {
      journalText(
        siteDescription,
        max: AttendanceActionCapture.siteDescriptionLimit,
        empty: true,
      );
    }
    if (note.action == CheckoutNoteAction.replace) {
      journalText(
        note.text,
        max: AttendanceActionCapture.finalNoteLimit,
        empty: true,
      );
    }
    return null;
  } catch (_) {
    return AttendanceInputError.invalidText;
  }
}

enum AttendanceRecoveryAction { none, replay, recoverConfirmed, recoverEmpty }

final class EmployeeAttendanceState {
  const EmployeeAttendanceState(
    this.status, {
    this.session,
    this.recovery = AttendanceRecoveryAction.none,
    this.message,
    this.inputError,
  });
  final EmployeeAttendanceStatus status;
  // Canonical server data only. Never derived from an RPC/receipt or a draft.
  final WorkSession? session;
  final AttendanceRecoveryAction recovery;
  final String? message;
  final AttendanceInputError? inputError;
}

/// C5 presentation with an optional fail-closed integration guard. No HTTP/auth
/// fallback, file migration or direct journal compaction. One instance per route;
/// coordinator/auth/storage lifetimes remain outside that route.
final class EmployeeAttendanceWorkflow extends ChangeNotifier {
  EmployeeAttendanceWorkflow({
    required this.issueContext,
    required this.authorizationChanges,
    required this.activeSessions,
    required this.capture,
    required this.coordinator,
    this.integrationGuard,
    this.onDisposed,
  }) {
    authorizationChanges.addListener(_authorizationChanged);
    activeSessions.addListener(_sessionsChanged);
  }

  final AttendanceOperationContext Function() issueContext;
  final Listenable authorizationChanges;
  final AttendanceActiveSessionReader activeSessions;
  final AttendanceActionCapture capture;
  final AttendanceOperationCoordinator coordinator;
  final AttendanceIntegrationGuard? integrationGuard;
  final VoidCallback? onDisposed;
  bool get noteDataAvailable => integrationGuard?.enrichedSessions ?? true;
  String? get integrationMessage =>
      integrationGuard?.configurationMessage ??
      (integrationGuard != null && !integrationGuard!.allows(_viewIdentity)
          ? AttendanceIntegrationGuard.notActivated
          : null);
  bool get _actionsApproved => integrationGuard?.allows(_viewIdentity) ?? true;
  EmployeeAttendanceState _state = const EmployeeAttendanceState(
    EmployeeAttendanceStatus.loading,
  );
  AttendanceOperationContext? _viewOwner;
  AttendanceOperationIdentity? _viewIdentity;
  int? _viewSessionRevision;
  bool _disposed = false;
  bool _busy = false;
  bool _emptyJournal = false;
  Completer<void>? _settlement;

  EmployeeAttendanceState get state =>
      _viewOwner != null && !_current(_viewOwner!, _viewIdentity!)
      ? const EmployeeAttendanceState(
          EmployeeAttendanceStatus.authorizationUnavailable,
        )
      : _viewSessionRevision != null &&
            _viewSessionRevision != activeSessions.revision
      ? const EmployeeAttendanceState(
          EmployeeAttendanceStatus.refreshUnavailable,
        )
      : _state;
  bool get isBusy => _busy;
  Future<void> get settled => _settlement?.future ?? Future<void>.value();
  bool get canCheckIn => _canAct && state.session == null;
  bool get canCheckOut => _canAct && state.session?.isActive == true;
  bool get _canAct =>
      !_disposed &&
      !_busy &&
      _actionsApproved &&
      _emptyJournal &&
      const {
        EmployeeAttendanceStatus.ready,
        EmployeeAttendanceStatus.invalidInput,
      }.contains(state.status);
  bool get canRecover =>
      !_disposed &&
      !_busy &&
      _actionsApproved &&
      state.recovery != AttendanceRecoveryAction.none;
  bool get canConsume =>
      !_disposed &&
      !_busy &&
      _actionsApproved &&
      state.status == EmployeeAttendanceStatus.confirmed;

  void _authorizationChanged() {
    if (_disposed) return;
    if (_viewOwner != null && !_current(_viewOwner!, _viewIdentity!)) {
      _emptyJournal = false;
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.authorizationUnavailable,
        ),
      );
    }
  }

  static bool _current(
    AttendanceOperationContext context,
    AttendanceOperationIdentity identity,
  ) {
    try {
      return context.isCurrent &&
          context.identity.generation == identity.generation &&
          context.identity.binding.matches(identity.binding);
    } catch (_) {
      return false;
    }
  }

  void _sessionsChanged() {
    if (_disposed || _viewSessionRevision == null) return;
    if (_viewSessionRevision != activeSessions.revision) {
      _emptyJournal = false;
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.refreshUnavailable,
        ),
      );
    }
  }

  bool _visible(AttendanceOperationContext context) =>
      !_disposed &&
      _viewIdentity != null &&
      _current(context, _viewIdentity!) &&
      _viewSessionRevision == activeSessions.revision;

  void _set(EmployeeAttendanceState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  bool _begin() {
    if (_disposed || _busy) return false;
    _busy = true;
    _settlement = Completer<void>();
    return true;
  }

  void _finish() {
    _busy = false;
    _settlement?.complete();
    if (!_disposed) notifyListeners();
  }

  bool _adopt(AttendanceOperationContext context) {
    try {
      final identity = context.identity;
      if (!_current(context, identity)) throw StateError('Unavailable context');
      _viewOwner = context;
      _viewIdentity = identity;
      _viewSessionRevision = activeSessions.revision;
      return true;
    } catch (_) {
      _emptyJournal = false;
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.authorizationUnavailable,
        ),
      );
      return false;
    }
  }

  Future<void> _release(AttendanceOperationContext context) async {
    try {
      await context.release();
    } catch (_) {
      _emptyJournal = false;
      if (_visible(context)) {
        _set(const EmployeeAttendanceState(EmployeeAttendanceStatus.blocked));
      }
    }
  }

  /// Refresh does not replay or submit. A readable confirmed record still needs
  /// C3 proof; restart recovery is a separate explicit control.
  Future<void> refresh() async {
    if (!_begin()) return;
    try {
      await _refreshSelection();
    } finally {
      _finish();
    }
  }

  Future<void> _refreshSelection({
    AttendanceOperationIdentity? expected,
    int? expectedSessionRevision,
  }) async {
    if (_disposed) return;
    AttendanceOperationContext? context;
    var transferred = false;
    _emptyJournal = false;
    try {
      final configuration = integrationGuard?.configurationMessage;
      if (configuration != null) {
        throw AttendanceIntegrationFailure(configuration);
      }
      context = issueContext();
      if (!_adopt(context)) return;
      if (integrationGuard != null) {
        await integrationGuard!.beforeRead(context.identity);
      }
      if (!_visible(context)) return;
      if (expected != null &&
          (expected.generation != context.identity.generation ||
              !expected.binding.matches(context.identity.binding))) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
        return;
      }
      if (expectedSessionRevision != null &&
          expectedSessionRevision != activeSessions.revision) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
        return;
      }
      _set(const EmployeeAttendanceState(EmployeeAttendanceStatus.loading));
      final read = await CommandJournal(coordinator.storage)
          .read(context.identity.binding);
      if (!_visible(context)) return;
      final record = read.record;
      if (read.isBlocked ||
          record?.command?.protocol == JournalProtocol.legacyV1 ||
          record?.migration?.plaintextCleanupComplete == false) {
        _set(const EmployeeAttendanceState(EmployeeAttendanceStatus.blocked));
      } else if (record?.phase == JournalPhase.confirmed) {
        transferred = true;
        _apply(await coordinator.refresh(context), context);
      } else if (record?.command != null) {
        _set(
          EmployeeAttendanceState(
            EmployeeAttendanceStatus.pending,
            recovery: _recovery(record!),
          ),
        );
      } else {
        transferred = true;
        _apply(await coordinator.readActive(context, activeSessions), context);
      }
    } on AttendanceIntegrationFailure catch (failure) {
      if (context == null || _visible(context)) {
        _set(
          EmployeeAttendanceState(
            EmployeeAttendanceStatus.blocked,
            message: failure.message,
          ),
        );
      }
    } catch (_) {
      if (context == null) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
      } else if (_visible(context)) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
      }
    } finally {
      if (context != null && !transferred) await _release(context);
    }
  }

  Future<void> consume() async {
    if (!canConsume || !_begin()) return;
    AttendanceOperationContext? context;
    var transferred = false;
    try {
      final original = _viewIdentity!;
      final originalRevision = _viewSessionRevision;
      context = issueContext();
      if (!_adopt(context)) return;
      if (original.generation != context.identity.generation ||
          !original.binding.matches(context.identity.binding)) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
        return;
      }
      if (originalRevision != activeSessions.revision) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
        return;
      }
      if (integrationGuard != null) {
        await integrationGuard!.beforeAction(context.identity);
      }
      if (!_visible(context)) return;
      final revision = _viewSessionRevision;
      _emptyJournal = false;
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.consumingConfirmation,
        ),
      );
      transferred = true;
      final result = await coordinator.consumeConfirmed(context);
      if (!_visible(context) || !result.isCurrent) return;
      if (result.outcome == AttendanceOperationOutcome.consumed) {
        await _refreshSelection(
          expected: context.identity,
          expectedSessionRevision: revision,
        );
      } else {
        _apply(result, context);
      }
    } catch (_) {
      if (context == null) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
      } else if (_visible(context)) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.consumptionUnresolved,
          ),
        );
      }
    } finally {
      if (context != null && !transferred) await _release(context);
      _finish();
    }
  }

  Future<void> checkIn({String? siteDescription}) async {
    if (!canCheckIn) return;
    await _action(description: siteDescription);
  }

  /// Editing clears only presentation feedback. Every subsequent explicit action
  /// is validated again; no authority, command or journal state is changed here.
  void clearInputError() {
    if (_disposed ||
        _busy ||
        state.status != EmployeeAttendanceStatus.invalidInput) {
      return;
    }
    _set(
      EmployeeAttendanceState(
        EmployeeAttendanceStatus.ready,
        session: state.session,
      ),
    );
  }

  Future<void> checkOut({
    CheckoutNoteIntent note = const CheckoutNoteIntent.preserve(),
  }) async {
    if (!canCheckOut) return;
    await _action(session: state.session!, note: note);
  }

  Future<void> _action({
    WorkSession? session,
    String? description,
    CheckoutNoteIntent note = const CheckoutNoteIntent.preserve(),
  }) async {
    if (!_begin()) return;
    AttendanceOperationContext? context;
    AttendanceCaptureResult? captureResult;
    var captured = false;
    try {
      // Strings and note intent are immutable; validate this exact button-time
      // input before issuing a context, generating a key or requesting location.
      final inputError = validateAttendanceInput(
        siteDescription: description,
        note: note,
      );
      if (inputError != null) {
        _set(
          EmployeeAttendanceState(
            EmployeeAttendanceStatus.invalidInput,
            session: session,
            inputError: inputError,
            message: inputError.message,
          ),
        );
        return;
      }
      final previous = _viewIdentity!;
      final previousSessionRevision = _viewSessionRevision;
      context = issueContext();
      if (!_adopt(context)) return;
      if (previous.generation != context.identity.generation ||
          !previous.binding.matches(context.identity.binding)) {
        _emptyJournal = false;
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
        return;
      }
      if (previousSessionRevision != activeSessions.revision) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
        return;
      }
      if (integrationGuard != null) {
        await integrationGuard!.beforeAction(context.identity);
      }
      if (!_visible(context)) return;
      _emptyJournal = false;
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.acquiringLocation,
        ),
      );
      // C4 freezes time/key/input synchronously, before its location awaits.
      captured = true; // From here C4 owns release, including rejected capture.
      final result = captureResult = await (session == null
          ? capture.checkIn(context: context, siteDescription: description)
          : capture.checkOut(
              context: context,
              activeSession: session,
              isSessionCurrent: (id) =>
                  !_disposed &&
                  activeSessions.isSessionCurrent(context!.identity, id),
              note: note,
            ));
      final action = result.action;
      if (!_visible(context)) return;
      if (result.status != AttendanceCaptureStatus.captured) {
        if (result.status == AttendanceCaptureStatus.invalidInput) {
          // C4 rejected capture without any journal/network handoff. Keep the
          // original canonical selection and let the draft be corrected.
          _emptyJournal = true;
          _set(
            EmployeeAttendanceState(
              EmployeeAttendanceStatus.invalidInput,
              session: session,
              inputError: AttendanceInputError.invalidCapture,
              message: AttendanceInputError.invalidCapture.message,
            ),
          );
          return;
        }
        _set(
          EmployeeAttendanceState(
            result.status == AttendanceCaptureStatus.invalidated
                ? EmployeeAttendanceStatus.authorizationUnavailable
                : EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
        return;
      }
      if (integrationGuard != null) {
        await integrationGuard!.beforeAction(context.identity);
      }
      if (!_visible(context)) return;
      final submission = action?.handoff();
      if (submission == null) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
        return;
      }
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.awaitingConfirmation,
        ),
      );
      // This future owns the handed context through late receipt settlement.
      _apply(
        await coordinator.submit(submission.context, submission.command),
        context,
      );
    } on AttendanceIntegrationFailure catch (failure) {
      _emptyJournal = false;
      if (context == null || _visible(context)) {
        _set(
          EmployeeAttendanceState(
            EmployeeAttendanceStatus.blocked,
            message: failure.message,
          ),
        );
      }
    } catch (_) {
      if (context == null) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
      } else if (_visible(context)) {
        _set(const EmployeeAttendanceState(EmployeeAttendanceStatus.pending));
      }
    } finally {
      try {
        // Currency may hide result.action before this caller ever obtains it.
        await captureResult?.abandon(); // No-op after coordinator handoff.
        if (context != null && !captured) await _release(context);
      } catch (_) {
        if (context != null && _visible(context)) {
          _set(const EmployeeAttendanceState(EmployeeAttendanceStatus.blocked));
        }
      } finally {
        _finish();
      }
    }
  }

  /// Exact-command recovery only. No capture, new key, fresh evidence, mutation
  /// on replay miss, or fallback to a legacy attendance RPC.
  Future<void> recover() async {
    if (!canRecover || !_begin()) return;
    final recovery = state.recovery;
    AttendanceOperationContext? context;
    var transferred = false;
    try {
      final original = _viewIdentity!;
      final originalRevision = _viewSessionRevision;
      context = issueContext();
      if (!_adopt(context)) return;
      if (original.generation != context.identity.generation ||
          !original.binding.matches(context.identity.binding)) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.authorizationUnavailable,
          ),
        );
        return;
      }
      if (originalRevision != activeSessions.revision) {
        _set(
          const EmployeeAttendanceState(
            EmployeeAttendanceStatus.refreshUnavailable,
          ),
        );
        return;
      }
      if (integrationGuard != null) {
        await integrationGuard!.beforeAction(context.identity);
      }
      if (!_visible(context)) return;
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.awaitingConfirmation,
        ),
      );
      transferred = true;
      final revision = _viewSessionRevision;
      final result = await switch (recovery) {
        AttendanceRecoveryAction.recoverConfirmed =>
          coordinator.recoverConfirmed(context),
        AttendanceRecoveryAction.recoverEmpty => coordinator.recoverEmpty(
          context,
        ),
        _ => coordinator.replay(context),
      };
      if (_visible(context) &&
          result.isCurrent &&
          result.outcome == AttendanceOperationOutcome.emptyVerified) {
        await _refreshSelection(
          expected: context.identity,
          expectedSessionRevision: revision,
        );
      } else {
        _apply(result, context);
      }
    } catch (_) {
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.authorizationUnavailable,
        ),
      );
    } finally {
      if (context != null && !transferred) await _release(context);
      _finish();
    }
  }

  static AttendanceRecoveryAction _recovery(JournalRecord record) =>
      switch (record.phase) {
        JournalPhase.confirmed => AttendanceRecoveryAction.recoverConfirmed,
        JournalPhase.mayHaveSent ||
        JournalPhase.uncertain => AttendanceRecoveryAction.replay,
        _ => AttendanceRecoveryAction.none,
      };

  void _apply(
    AttendanceOperationResult result,
    AttendanceOperationContext context,
  ) {
    if (!_visible(context)) return;
    if (!result.isCurrent) {
      _set(const EmployeeAttendanceState(EmployeeAttendanceStatus.blocked));
      return;
    }
    final snapshot = result.snapshot;
    if (result.outcome == AttendanceOperationOutcome.ready &&
        snapshot != null) {
      _emptyJournal = true;
      _set(
        EmployeeAttendanceState(
          EmployeeAttendanceStatus.ready,
          session: snapshot.canonicalSession,
        ),
      );
    } else if (result.problem ==
            AttendanceOperationProblem.consumptionUncertain ||
        result.problem == AttendanceOperationProblem.emptyRecoveryRequired) {
      _emptyJournal = false;
      _set(
        EmployeeAttendanceState(
          EmployeeAttendanceStatus.consumptionUnresolved,
          recovery:
              result.problem == AttendanceOperationProblem.emptyRecoveryRequired
              ? AttendanceRecoveryAction.recoverEmpty
              : AttendanceRecoveryAction.none,
        ),
      );
    } else if (result.problem ==
            AttendanceOperationProblem.canonicalUnavailable &&
        result.outcome != AttendanceOperationOutcome.confirmedNeedsRefresh) {
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.refreshUnavailable,
        ),
      );
    } else if (result.outcome == AttendanceOperationOutcome.confirmed &&
        snapshot?.canonicalSession != null) {
      _set(
        EmployeeAttendanceState(
          EmployeeAttendanceStatus.confirmed,
          session: snapshot!.canonicalSession,
          message:
              'Le justificatif est conservé. Terminez la vérification avant '
              'un nouveau pointage.',
        ),
      );
    } else if (result.outcome ==
        AttendanceOperationOutcome.confirmedNeedsRefresh) {
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.confirmedNeedsRefresh,
          recovery: AttendanceRecoveryAction.recoverConfirmed,
        ),
      );
    } else if (result.outcome == AttendanceOperationOutcome.invalidated) {
      _set(
        const EmployeeAttendanceState(
          EmployeeAttendanceStatus.authorizationUnavailable,
        ),
      );
    } else {
      final problem = result.problem;
      final blocked =
          result.outcome == AttendanceOperationOutcome.gated ||
          problem == AttendanceOperationProblem.journalUnavailable ||
          problem == AttendanceOperationProblem.contextUnavailable;
      _set(
        EmployeeAttendanceState(
          blocked
              ? EmployeeAttendanceStatus.blocked
              : EmployeeAttendanceStatus.pending,
          recovery: blocked
              ? AttendanceRecoveryAction.none
              : problem == AttendanceOperationProblem.recoveryRequired
              ? AttendanceRecoveryAction.recoverConfirmed
              : const {
                  AttendanceOperationProblem.transportUncertain,
                  AttendanceOperationProblem.replayMiss,
                  AttendanceOperationProblem.malformedAcknowledgement,
                  AttendanceOperationProblem.pendingCommand,
                }.contains(problem)
              ? AttendanceRecoveryAction.replay
              : AttendanceRecoveryAction.none,
        ),
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    authorizationChanges.removeListener(_authorizationChanged);
    activeSessions.removeListener(_sessionsChanged);
    // This only revokes unsubmitted capture. Submitted work drains normally.
    unawaited(capture.close().catchError((Object _) {}));
    onDisposed?.call();
    super.dispose();
  }
}
