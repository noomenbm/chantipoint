import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/authorized_user.dart';
import 'attendance_models.dart';
import 'attendance_repository.dart';

typedef AttendanceControllerFactory = AttendanceController Function(
  AuthorizedUser user,
);

enum AttendanceStatus { loading, ready, submitting, pending, blocked }

class AttendanceState {
  const AttendanceState({
    required this.status,
    this.active,
    this.completed,
    this.message,
  });
  final AttendanceStatus status;
  final WorkSession? active;
  final WorkSession? completed;
  final String? message;
}

class AttendanceController extends ChangeNotifier {
  AttendanceController(
    this.repository,
    this.store,
    this.user, {
    this.onAuthorizationFailure,
  });
  final AttendanceRepository repository;
  final PendingCommandStore store;
  final AuthorizedUser user;
  final Future<void> Function()? onAuthorizationFailure;
  String get owner => '${user.companyId}:${user.profileId}';
  AttendanceState _state = const AttendanceState(
    status: AttendanceStatus.loading,
  );
  AttendanceState get state => _state;
  AttendanceCommand? _pending;
  bool _busy = false;
  bool _disposed = false;

  bool get canCheckIn =>
      _state.status == AttendanceStatus.ready && _state.active == null;
  bool get canCheckOut =>
      _state.status == AttendanceStatus.ready &&
      _state.active?.isFactory == true &&
      _state.active?.isActive == true;

  Future<void> refresh() => _run(() async {
    _pending = await store.read(owner);
    if (_disposed) return;
    if (_pending != null) {
      await _reconcile(_pending!);
    } else {
      final active = await repository.activeSession();
      _publish(AttendanceState(status: AttendanceStatus.ready, active: active));
    }
  });

  Future<void> checkIn() async {
    if (!canCheckIn) return;
    await _newCommand(() => AttendanceCommand.factoryCheckIn());
  }

  Future<void> checkOut() async {
    if (!canCheckOut) return;
    final expected = _state.active!;
    await _newCommand(
      () => AttendanceCommand.checkOut(expected),
      expected: expected,
    );
  }

  Future<void> _newCommand(
    AttendanceCommand Function() create, {
    WorkSession? expected,
  }) => _run(() async {
    // Recheck both the journal and the backend immediately before a new intent.
    _pending = await store.read(owner);
    if (_disposed) return;
    if (_pending != null) {
      await _reconcile(_pending!);
      return;
    }
    final active = await repository.activeSession();
    if (_disposed) return;
    if ((expected == null && active != null) ||
        (expected != null &&
            (active?.id != expected.id || active?.isFactory != true))) {
      _publish(
        AttendanceState(
          status: AttendanceStatus.ready,
          active: active,
          message:
              'Le pointage a changé sur le serveur. Vérifiez l’état actuel.',
        ),
      );
      return;
    }
    final command = create();
    await store.save(owner, command);
    _pending = command;
    if (_disposed) return;
    await _send(command, firstAttempt: true);
  }, status: AttendanceStatus.submitting);

  Future<void> retryPending() => _run(() async {
    _pending = await store.read(owner);
    if (_disposed) return;
    if (_pending == null) {
      final active = await repository.activeSession();
      _publish(AttendanceState(status: AttendanceStatus.ready, active: active));
      return;
    }
    if (!await _reconcile(_pending!)) {
      if (!_disposed) {
        _publish(const AttendanceState(status: AttendanceStatus.submitting));
        await _send(_pending!);
      }
    }
  }, status: AttendanceStatus.submitting);

  /// A missing match is not proof that a timed-out request never committed.
  /// Keep the original intent and do not offer a new key.
  Future<bool> _reconcile(AttendanceCommand command) async {
    final match = await repository.findCommand(command);
    if (_disposed) return false;
    final active = await repository.activeSession();
    if (_disposed) return false;
    if (match != null) {
      await _finish(command, match, active);
      return true;
    }
    _publish(
      AttendanceState(
        status: AttendanceStatus.pending,
        active: active,
        message: 'Pointage en attente de confirmation. Vérifiez et réessayez.',
      ),
    );
    return false;
  }

  Future<void> _send(
    AttendanceCommand command, {
    bool firstAttempt = false,
  }) async {
    try {
      final acknowledged = await repository.submit(command);
      if (_disposed) return;
      final active = await repository.activeSession();
      if (_disposed) return;
      await _finish(command, acknowledged, active);
    } on AttendanceFailure catch (failure) {
      // A definitive rejection of the first request has no earlier uncertain
      // attempt. Clear that intent only after retrieving canonical server state.
      if (firstAttempt &&
          const {
            AttendanceFailureKind.duplicateActive,
            AttendanceFailureKind.sessionNotActive,
            AttendanceFailureKind.idempotencyConflict,
          }.contains(failure.kind)) {
        final active = await repository.activeSession();
        if (_disposed) return;
        await store.clear(owner, command.key);
        _pending = null;
        _publish(
          AttendanceState(
            status: AttendanceStatus.ready,
            active: active,
            message: failure.message,
          ),
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _finish(
    AttendanceCommand command,
    WorkSession acknowledged,
    WorkSession? active,
  ) async {
    if (_disposed) return;
    await store.clear(owner, command.key);
    if (_disposed) return;
    _pending = null;
    _publish(
      AttendanceState(
        status: AttendanceStatus.ready,
        active: active,
        completed: acknowledged.isActive ? null : acknowledged,
        message: acknowledged.isActive
            ? 'Entrée à l’usine confirmée par le serveur.'
            : acknowledged.lifecycleStatus == 'voided'
            ? 'Cette session a été annulée sur le serveur.'
            : command.kind == AttendanceCommandKind.checkIn
            ? 'Entrée retrouvée sur le serveur. Cette session est déjà terminée.'
            : 'Session terminée. Sortie confirmée par le serveur.',
      ),
    );
  }

  Future<void> _run(
    Future<void> Function() work, {
    AttendanceStatus status = AttendanceStatus.loading,
  }) async {
    if (_disposed || _busy) return;
    _busy = true;
    _publish(AttendanceState(status: status));
    try {
      if (!user.roles.contains(AuthorizedRole.employee)) {
        throw const AttendanceFailure(AttendanceFailureKind.unauthorized);
      }
      await work();
    } catch (error) {
      if (_disposed) return;
      final failure = error is AttendanceFailure
          ? error
          : const AttendanceFailure(AttendanceFailureKind.backend);
      _publish(
        AttendanceState(
          status: _pending == null
              ? AttendanceStatus.blocked
              : AttendanceStatus.pending,
          message: failure.message,
        ),
      );
      if (failure.kind == AttendanceFailureKind.unauthorized ||
          failure.kind == AttendanceFailureKind.sessionExpired) {
        final revalidate = onAuthorizationFailure;
        if (revalidate != null) unawaited(revalidate());
      }
    } finally {
      _busy = false;
    }
  }

  void _publish(AttendanceState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
