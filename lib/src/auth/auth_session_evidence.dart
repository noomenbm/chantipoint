import 'package:supabase_flutter/supabase_flutter.dart';

import 'authorized_user.dart';

/// Memory-only evidence from the existing auth client. Opaque session identity
/// is compared by reference, never UUID/token equality. Never expose Session's
/// toString (which includes credentials), refresh tokens or serialized sessions.
final class AuthSessionEvidence {
  AuthSessionEvidence(Session session) : _session = session;
  final Session _session;
  String get authUserId => _session.user.id;
  String get accessToken => _session.accessToken;
  int? get expiresAt => _session.expiresAt;
  // Continuity only, NOT signature verification, authorization or deployment
  // provenance. Initial authority also requires successful server profile/role
  // validation. Bound parsing and keep all malformed-token details private.
  String? get loginSessionId {
    try {
      if (accessToken.length > 8192) return null;
      final payload = decodeJwt(accessToken).payload;
      final id = payload.claims['session_id'];
      if (payload.sub != authUserId ||
          id is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(id)) {
        return null;
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  bool sameLogin(AuthSessionEvidence other) {
    final login = loginSessionId;
    return login != null &&
        authUserId == other.authUserId &&
        login == other.loginSessionId;
  }

  bool sameSession(AuthSessionEvidence? other) =>
      other != null && identical(_session, other._session);
}

/// An attendance-only attestation; does not change authentication decisions.
final class AuthorizedSessionEvidence {
  AuthorizedSessionEvidence(this.user, this.session, this.operation)
    : employeeAuthorized = user.roles.contains(AuthorizedRole.employee);
  final AuthorizedUser user;
  final AuthSessionEvidence session;
  final int operation;
  final bool employeeAuthorized;
}

final class AuthSessionObservation {
  AuthSessionObservation(AuthState state)
    : event = state.event,
      session = state.session == null
          ? null
          : AuthSessionEvidence(state.session!);
  final AuthChangeEvent event;
  final AuthSessionEvidence? session;
}
