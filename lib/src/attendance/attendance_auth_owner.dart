import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;

import '../auth/auth_controller.dart';
import '../auth/auth_session_evidence.dart';
import '../auth/supabase_auth_repository.dart';
import 'attendance_operation_transport.dart';
import 'attendance_request_authority.dart';
import 'journal/journal_command.dart';
import 'journal/journal_json.dart';

enum AttendanceAuthFailureKind {
  configuration,
  contextInvalidated,
  credentialsUnavailable,
}

final class AttendanceAuthFailure implements Exception {
  const AttendanceAuthFailure(this.kind);
  final AttendanceAuthFailureKind kind;
  @override
  String toString() => 'AttendanceAuthFailure(${kind.name})';
}

/// Independently trusted application/deployment input, NEVER from a journal,
/// inferred from a current account or decoded JWT. No environment-file loading.
final class AttendanceTrustedDeployment {
  AttendanceTrustedDeployment({
    required this.environmentId,
    required this.projectUrl,
    required this.publishableKey,
  }) {
    try {
      journalText(environmentId, max: 128);
      if (projectUrl.host.isEmpty ||
          projectUrl.toString().length > 512 ||
          projectUrl.userInfo.isNotEmpty ||
          projectUrl.path.isNotEmpty ||
          projectUrl.hasQuery ||
          projectUrl.hasFragment ||
          (projectUrl.scheme != 'https' &&
              !(projectUrl.scheme == 'http' &&
                  const {
                    'localhost',
                    '127.0.0.1',
                    '::1',
                  }.contains(projectUrl.host))) ||
          publishableKey.isEmpty ||
          publishableKey.length > 4096 ||
          !publishableKey.codeUnits.every((c) => c >= 0x21 && c <= 0x7e)) {
        throw const AttendanceAuthFailure(
          AttendanceAuthFailureKind.configuration,
        );
      }
    } catch (_) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.configuration,
      );
    }
  }
  final String environmentId;
  final Uri projectUrl;
  final String publishableKey;
}

/// Application-lifetime owner AND C3.2 authority for the same in-process epochs.
/// Not composed in main/live attendance. Pair the exact controller/repository;
/// no screen owns/disposes this object. No global/native/restart fencing claim.
final class AttendanceAuthOwner
    implements AttendanceRequestAuthority, Listenable {
  AttendanceAuthOwner({
    required this.auth,
    required this.repository,
    required this.deployment,
  }) {
    if (!auth.usesRepository(repository) ||
        auth.isDisposed ||
        repository.attendanceRestUrl !=
            deployment.projectUrl.replace(path: '/rest/v1').toString()) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.configuration,
      );
    }
    _subscription = repository.attendanceSessionChanges.listen(
      _onSession,
      onError: (Object _, StackTrace _) => _invalidate(),
    );
    auth.addListener(_onAuth);
    repository.attendanceOperationChanges.addListener(_onOperation);
    _onAuth();
  }
  final AuthController auth;
  final SupabaseAuthRepository repository;
  final AttendanceTrustedDeployment deployment;
  late final StreamSubscription<AuthSessionObservation> _subscription;
  // Unique across owner replacement in this isolate; not persisted or journaled.
  static int _nextGeneration = 0;
  int _generation = ++_nextGeneration;
  AuthorizedSessionEvidence? _approval;
  AuthSessionEvidence? _credentials;
  AttendanceOperationIdentity? _identity;
  bool _closed = false;
  final _attempts = <_AttendanceContext>{};
  final _drained = Completer<void>();
  Future<void>? _closing;
  final _changes = _AttendanceAuthChanges();
  int _transitionDepth = 0;
  bool _notificationPending = false;

  @override
  void addListener(VoidCallback listener) {
    if (_closed) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.contextInvalidated,
      );
    }
    _changes.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  void _changed() {
    if (_transitionDepth != 0) {
      _notificationPending = true;
    } else {
      _changes.changed();
    }
  }

  // Publish only a complete transition, never the half-built approved identity.
  void _transition(void Function() work) {
    _transitionDepth++;
    try {
      work();
    } finally {
      _transitionDepth--;
      if (_transitionDepth == 0 && _notificationPending) {
        _notificationPending = false;
        _changes.changed();
      }
    }
  }

  void _onOperation() {
    if (!_closed && _approval != null) _invalidate();
  }

  int get generation => _generation;
  int get outstandingAttempts => _attempts.length;

  void _invalidate() {
    _generation = ++_nextGeneration;
    _approval = null;
    _credentials = null;
    _identity = null;
    _changed();
  }

  void _onAuth() => _transition(_updateAuth);
  void _updateAuth() {
    if (_closed) return;
    final state = auth.state;
    if (auth.isDisposed || state.status != AuthStatus.authenticated) {
      // signingOut/authenticating are synchronous pre-await initiation hooks.
      // Revalidation/checking/blocked also revoke old attempt authority; a later
      // successful authorization issues a fresh epoch, never revives old ones.
      if (_approval != null) _invalidate();
      return;
    }
    final approval = repository.attendanceAuthorization;
    final current = repository.currentCredentials;
    if (approval == null ||
        !identical(state.user, approval.user) ||
        !approval.employeeAuthorized ||
        approval.session.loginSessionId == null ||
        current == null) {
      if (_approval != null) _invalidate();
      return;
    }
    if (identical(_approval, approval)) {
      // A replacement is temporarily ineligible until its ordered SDK event is
      // observed. Do not turn a pending same-login refresh into a new epoch.
      return;
    }
    if (!approval.session.sameSession(current)) {
      // Await a fresh authorization or a proven refresh observation. A matching
      // UUID alone cannot connect a replaced SDK session to the approved login.
      if (_approval != null) _invalidate();
      return;
    }
    _invalidate();
    try {
      final binding = JournalBinding(
        environmentId: deployment.environmentId,
        baseUrl: deployment.projectUrl.toString(),
        authUserId: current.authUserId,
        companyId: approval.user.companyId,
        profileId: approval.user.profileId,
      );
      _identity = AttendanceOperationIdentity(binding, _generation);
      _approval = approval;
      _credentials = current;
    } catch (_) {
      // Invalid auth/profile identifiers or configuration grant no authority.
    }
  }

  void _onSession(AuthSessionObservation event) =>
      _transition(() => _updateSession(event));
  void _updateSession(AuthSessionObservation event) {
    if (_closed) return;
    if (event.event == AuthChangeEvent.tokenRefreshed) {
      final next = event.session;
      // An older event cannot establish or revoke continuity of a session that
      // has already superseded it. Exact-current guards keep unknown replacement
      // blocked until its own evidence arrives or authorization is revalidated.
      if (next == null || !next.sameSession(repository.currentCredentials)) {
        return;
      }
      final approval = _approval;
      if (approval != null &&
          approval.operation == repository.authorizationOperation &&
          identical(auth.state.user, approval.user) &&
          auth.state.status == AuthStatus.authenticated &&
          next.sameLogin(approval.session)) {
        // An ordered SDK event PLUS the approved server-login marker establish
        // continuity; tokenRefreshed alone also covers setSession(otherToken).
        // No new generation and no update to issued token bytes.
        _credentials = next;
      } else {
        _invalidate();
        _onAuth();
      }
      return;
    }
    // Signed-in (including same user), signed-out, recovery, user change and
    // initial-session observations are boundaries, not UUID-based continuity.
    _invalidate();
    _onAuth();
  }

  @override
  bool isCurrent(AttendanceOperationIdentity identity) {
    final captured = _identity;
    final approval = _approval;
    if (_closed || auth.isDisposed || captured == null || approval == null) {
      return false;
    }
    return identity.generation == captured.generation &&
        identity.binding.matches(captured.binding) &&
        approval.operation == repository.authorizationOperation &&
        identical(repository.attendanceAuthorization, approval) &&
        auth.state.status == AuthStatus.authenticated &&
        identical(auth.state.user, approval.user) &&
        approval.employeeAuthorized &&
        _credentials?.sameSession(repository.currentCredentials) == true;
  }

  AttendanceOperationContext issueContext() {
    // Synchronous controller state plus exact repository/session evidence; not
    // dependent on a later signed-out event or a widget's next frame.
    _onAuth();
    final identity = _identity;
    if (identity == null || !isCurrent(identity)) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.contextInvalidated,
      );
    }
    final context = _AttendanceContext(this, identity);
    _attempts.add(context);
    return context;
  }

  @override
  Future<AttendanceRequestScope> acquire(
    AttendanceOperationIdentity identity,
  ) async {
    _requireCurrent(identity);
    final AuthSessionEvidence? resolved;
    try {
      // Guarded SDK lookup captures this session before its first await. Refresh
      // is allowed to settle; subsequent guards reject fallback/stale results.
      resolved = await repository.resolveAttendanceCredentials();
    } catch (_) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.credentialsUnavailable,
      );
    }
    _requireCurrent(identity);
    if (resolved == null ||
        !resolved.sameSession(_credentials) ||
        !resolved.sameSession(repository.currentCredentials) ||
        !_usable(resolved)) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.credentialsUnavailable,
      );
    }
    final AuthSessionEvidence pinned = resolved;
    return AttendanceRequestScope(
      identity: identity,
      projectUrl: deployment.projectUrl,
      publishableKey: deployment.publishableKey,
      accessToken: pinned.accessToken,
      expectedAttendanceEpoch: deployment.environmentId,
      isCurrent: () => isCurrent(identity) && _usable(pinned),
    );
  }

  static bool _usable(AuthSessionEvidence credentials) {
    final expiry = credentials.expiresAt;
    return expiry != null &&
        DateTime.now().millisecondsSinceEpoch < expiry * 1000;
  }

  void _requireCurrent(AttendanceOperationIdentity identity) {
    if (!isCurrent(identity)) {
      throw const AttendanceAuthFailure(
        AttendanceAuthFailureKind.contextInvalidated,
      );
    }
  }

  void _release(_AttendanceContext context) {
    _attempts.remove(context);
    if (_closed && _attempts.isEmpty && !_drained.isCompleted) {
      _drained.complete();
    }
  }

  /// Application shutdown only. Revoke new work and detach listeners now; wait
  /// for every issued context's normal release. Never cancel/force-release work.
  Future<void> close() {
    if (_closing != null) return _closing!;
    // Store the future before synchronous invalidation notifies listeners.
    final done = Completer<void>();
    _closing = done.future;
    unawaited(_close().then(done.complete, onError: done.completeError));
    return done.future;
  }

  Future<void> _close() async {
    _closed = true;
    _invalidate();
    auth.removeListener(_onAuth);
    repository.attendanceOperationChanges.removeListener(_onOperation);
    try {
      await _subscription.cancel();
    } finally {
      _changes.dispose();
    }
    if (_attempts.isNotEmpty) await _drained.future;
  }
}

final class _AttendanceAuthChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

final class _AttendanceContext implements AttendanceOperationContext {
  _AttendanceContext(this.owner, this.identity);
  final AttendanceAuthOwner owner;
  @override
  final AttendanceOperationIdentity identity;
  bool _released = false;
  @override
  bool get isCurrent => owner.isCurrent(identity);
  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    owner._release(this);
  }
}
