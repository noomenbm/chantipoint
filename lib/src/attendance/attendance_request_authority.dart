import 'attendance_operation_transport.dart';

/// Trust boundary, not a production issuer. Must share the operation context's
/// authorization epochs, including logout intent and same-user relogin. UUID or
/// token presence alone is insufficient. No credentials belong in the journal.
abstract interface class AttendanceRequestAuthority {
  bool isCurrent(AttendanceOperationIdentity identity);

  /// Resolve only this complete binding/epoch. Any refresh/acquisition work must
  /// settle before this future settles; never fall back to another session.
  /// The scope must contain a usable token and independently trusted deployment
  /// configuration, not an endpoint/key inferred from a journal or JWT alone.
  Future<AttendanceRequestScope> acquire(AttendanceOperationIdentity identity);
}

/// Immutable, memory-only request credentials. Currency remains observable
/// through the same authority as the operation context. No refresh token,
/// persistence, logging, default account or production lifecycle is supplied.
final class AttendanceRequestScope {
  const AttendanceRequestScope({
    required this.identity,
    required this.projectUrl,
    required this.publishableKey,
    required this.accessToken,
    required this._isCurrent,
  });

  final AttendanceOperationIdentity identity;
  final Uri projectUrl;
  final String publishableKey;
  final String accessToken;
  final bool Function() _isCurrent;
  bool get isCurrent => _isCurrent();
}
