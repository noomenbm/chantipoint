import 'dart:async';

import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_failure.dart';
import 'auth_repository.dart';
import 'auth_session_evidence.dart';
import 'authorized_user.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;
  int _operation = 0;
  AuthFailureKind? _terminationReason;
  Session? _authorizedSession;
  Future<void> _authCommands = Future.value();
  AuthorizedSessionEvidence? _attendanceAuthorization;

  // Additive evidence only: no new queries, auth mutations or changed UI result.
  // Operation changes synchronously at restore/login/logout initiation, including
  // while an SDK logout is still queued behind an earlier auth command.
  int get authorizationOperation => _operation;
  String get attendanceRestUrl => _client.rest.url;
  AuthSessionEvidence? get currentCredentials {
    final session = _client.auth.currentSession;
    return session == null ? null : AuthSessionEvidence(session);
  }

  AuthorizedSessionEvidence? get attendanceAuthorization =>
      _attendanceAuthorization?.operation == _operation
      ? _attendanceAuthorization
      : null;

  Stream<AuthSessionObservation> get attendanceSessionChanges =>
      _client.auth.onAuthStateChange.map(AuthSessionObservation.new);

  // The caller must check its original epoch before and after this SDK lookup.
  // getSession may refresh, or return a stale result after a concurrent mutation;
  // its result alone never grants attendance authority.
  Future<AuthSessionEvidence?> resolveAttendanceCredentials() async {
    final session = await _client.auth.getSession();
    return session == null ? null : AuthSessionEvidence(session);
  }

  @override
  bool get hasSession => _client.auth.currentSession != null;

  @override
  Stream<AuthSessionEvent> get sessionChanges =>
      _client.auth.onAuthStateChange.transform(
        StreamTransformer<AuthState, AuthSessionEvent>.fromHandlers(
          handleData: (state, sink) {
            switch (state.event) {
              case AuthChangeEvent.signedOut:
                sink.add(switch (_terminationReason) {
                  AuthFailureKind.accessDenied => AuthSessionEvent.accessDenied,
                  AuthFailureKind.sessionExpired =>
                    AuthSessionEvent.sessionExpired,
                  _ =>
                    state.signOutReason == SignOutReason.sessionExpired ||
                            state.signOutReason == SignOutReason.sessionMissing
                        ? AuthSessionEvent.sessionExpired
                        : AuthSessionEvent.signedOut,
                });
              case AuthChangeEvent.signedIn:
                if (!identical(state.session, _authorizedSession)) {
                  sink.add(AuthSessionEvent.signedIn);
                }
              case AuthChangeEvent.tokenRefreshed:
                sink.add(AuthSessionEvent.tokenRefreshed);
              case AuthChangeEvent.userUpdated:
                sink.add(AuthSessionEvent.userUpdated);
              default:
                break;
            }
          },
          handleError: (error, stack, sink) {
            sink.addError(_failureFor(error), stack);
          },
        ),
      );

  @override
  Future<AuthorizedUser?> restoreSession() async {
    final operation = ++_operation;
    if (!hasSession) return null;
    return _authorize(operation);
  }

  @override
  Future<AuthorizedUser> signIn({
    required String email,
    required String password,
  }) async {
    final operation = ++_operation;
    _terminationReason = null;
    try {
      final response = await _serializeAuth(
        () => _client.auth.signInWithPassword(
          email: email.trim(),
          password: password,
        ),
      );
      if (response.user == null || response.session == null) {
        throw const AuthFailure(AuthFailureKind.invalidCredentials);
      }
      _ensureCurrent(operation, response.user!.id);
    } catch (error) {
      throw _failureFor(error, signingIn: true);
    }
    return _authorize(operation);
  }

  Future<AuthorizedUser> _authorize(int operation) async {
    String? userId;
    try {
      final session = await _client.auth.getSession();
      if (session == null ||
          (session.expiresAt != null &&
              DateTime.now().millisecondsSinceEpoch >=
                  session.expiresAt! * 1000)) {
        throw const AuthFailure(AuthFailureKind.sessionExpired);
      }
      userId = session.user.id;
      _ensureCurrent(operation, userId);
      final user = await _loadAuthorizedUser(operation, session.user);
      _ensureCurrent(operation, userId);
      _authorizedSession = _client.auth.currentSession;
      // Withhold attendance attestation if any SDK session replacement occurred
      // during authorization. A new successful validation can establish it; do
      // not change the existing auth outcome or infer same-login continuity here.
      _attendanceAuthorization = identical(session, _client.auth.currentSession)
          ? AuthorizedSessionEvidence(
              user,
              AuthSessionEvidence(session),
              operation,
            )
          : null;
      _terminationReason = null;
      return user;
    } catch (error) {
      final failure = _failureFor(error);
      if (operation == _operation &&
          (userId == null || _client.auth.currentUser?.id == userId) &&
          (failure.kind == AuthFailureKind.accessDenied ||
              failure.kind == AuthFailureKind.sessionExpired)) {
        _terminationReason = failure.kind;
        try {
          await _serializeAuth(() async {
            // An older denied lookup must never clear a newer login.
            if (operation == _operation) {
              await _client.auth.signOut(scope: SignOutScope.local);
            }
          });
        } catch (_) {
          // Preserve the denial. The controller checks whether cleanup left a
          // session and keeps application content blocked in either case.
        }
      }
      throw failure;
    }
  }

  @override
  Future<void> signOut() async {
    ++_operation;
    _terminationReason = null;
    try {
      // Serialize auth mutations so a delayed login cannot recreate a session
      // after a newer logout has already completed.
      await _serializeAuth(
        () => _client.auth.signOut(scope: SignOutScope.local),
      );
      if (hasSession) throw const AuthFailure(AuthFailureKind.unknown);
    } catch (error) {
      throw _failureFor(error);
    }
  }

  Future<T> _serializeAuth<T>(Future<T> Function() command) {
    final result = _authCommands.then((_) => command());
    _authCommands = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _ensureCurrent(int operation, String userId) {
    if (operation != _operation ||
        _client.auth.currentUser?.id != userId ||
        !hasSession) {
      throw const AuthFailure(AuthFailureKind.sessionExpired);
    }
  }

  Future<AuthorizedUser> _loadAuthorizedUser(
    int operation,
    User authUser,
  ) async {
    final profile = await _client
        .from('user_profiles')
        .select('id, company_id, display_name, email, status')
        .eq('auth_user_id', authUser.id)
        .maybeSingle();
    _ensureCurrent(operation, authUser.id);
    if (profile == null || profile['status'] != 'active') {
      throw const AuthFailure(AuthFailureKind.accessDenied);
    }

    final roleResponse = await _client
        .from('role_assignments')
        .select('role')
        .eq('user_profile_id', profile['id'] as String)
        .eq('status', 'active');
    _ensureCurrent(operation, authUser.id);

    final roles = <AuthorizedRole>{};
    for (final row in roleResponse) {
      final role = AuthorizedRole.fromDatabase(row['role'] as String? ?? '');
      if (role != null) roles.add(role);
    }
    if (roles.isEmpty) throw const AuthFailure(AuthFailureKind.accessDenied);

    return AuthorizedUser(
      profileId: profile['id'] as String,
      companyId: profile['company_id'] as String,
      displayName: profile['display_name'] as String,
      email: profile['email'] as String? ?? authUser.email ?? '',
      roles: roles,
    );
  }

  AuthFailure _failureFor(Object error, {bool signingIn = false}) {
    if (error is AuthFailure) return error;
    if (error is TimeoutException || error is ClientException) {
      return const AuthFailure(AuthFailureKind.network);
    }
    if (error is AuthException) {
      final status = int.tryParse(error.statusCode ?? '');
      if (status != null && (status >= 500 || status == 429)) {
        return const AuthFailure(AuthFailureKind.serviceUnavailable);
      }
      if (error is AuthRetryableFetchException ||
          error is AuthUnknownException) {
        return const AuthFailure(AuthFailureKind.network);
      }
      if (signingIn && error.code == 'invalid_credentials') {
        return const AuthFailure(AuthFailureKind.invalidCredentials);
      }
      if (error.code == 'user_banned' || error.code == 'email_not_confirmed') {
        return const AuthFailure(AuthFailureKind.accessDenied);
      }
      if (error is AuthSessionMissingException ||
          const {
            'session_expired',
            'session_not_found',
            'session_missing',
            'refresh_token_not_found',
            'refresh_token_already_used',
            'bad_jwt',
            'invalid_jwt',
          }.contains(error.code)) {
        return const AuthFailure(AuthFailureKind.sessionExpired);
      }
    }
    if (error is PostgrestException) {
      if (const {'PGRST301', 'PGRST303', '401'}.contains(error.code)) {
        return const AuthFailure(AuthFailureKind.sessionExpired);
      }
      // Query permission failures (42501/403) can reflect backend grants or
      // configuration, so they are not evidence of revoked account access.
      return const AuthFailure(AuthFailureKind.serviceUnavailable);
    }
    return const AuthFailure(AuthFailureKind.unknown);
  }
}
