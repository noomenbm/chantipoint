import 'package:flutter/foundation.dart';

import 'attendance_models.dart';
import 'attendance_operation_transport.dart';
import 'employee_attendance_workflow.dart';
import 'supabase_attendance_operation_transport.dart';

/// C5 observation port over C3.2, using that transport's exact authority. No SDK
/// current-user lookup, auth owner, subscription, polling or client ownership.
/// Keep this shared reader alive through its in-flight reads; dispose does not
/// cancel HTTP work or close the borrowed transport/client/auth owner.
final class ScopedAttendanceActiveSessionReader extends ChangeNotifier
    implements AttendanceActiveSessionReader {
  ScopedAttendanceActiveSessionReader({required this.transport});
  final SupabaseAttendanceOperationTransport transport;
  int _revision = 0;
  int _readSequence = 0;
  bool _closed = false;
  AttendanceOperationIdentity? _observedIdentity;
  String? _activeId;

  @override
  int get revision => _revision;

  bool _authorized(AttendanceOperationIdentity identity) {
    try {
      return !_closed && transport.authority.isCurrent(identity);
    } catch (_) {
      return false;
    }
  }

  void _requireCurrent(AttendanceOperationIdentity identity) {
    if (!_authorized(identity)) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.contextInvalidated,
      );
    }
  }

  @override
  Future<WorkSession?> readActiveSession(
    AttendanceOperationIdentity identity,
  ) async {
    _requireCurrent(identity);
    final revision = _revision;
    final sequence = ++_readSequence;
    _observedIdentity = null;
    _activeId = null;
    final session = await transport.readActiveSession(identity);
    _requireCurrent(identity);
    if (revision != _revision || sequence != _readSequence) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.staleObservation,
      );
    }
    // A read establishes a baseline only. Never notify or advance revision here:
    // C5 captured that revision before awaiting this very read.
    _observedIdentity = identity;
    _activeId = session?.id;
    return session;
  }

  @override
  bool isSessionCurrent(
    AttendanceOperationIdentity identity,
    String sessionId,
  ) {
    final observed = _observedIdentity;
    return _authorized(identity) &&
        observed != null &&
        observed.generation == identity.generation &&
        observed.binding.matches(identity.binding) &&
        _activeId == sessionId;
  }

  /// Explicit notification from a future trusted composition when it knows a
  /// session changed. This revokes the baseline; it neither grants authority nor
  /// fabricates a canonical replacement. Refresh is required before checkout.
  /// No production event source is connected in C6.1.
  void invalidateSession(AttendanceOperationIdentity identity) {
    _requireCurrent(identity);
    _observedIdentity = null;
    _activeId = null;
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _observedIdentity = null;
    _activeId = null;
    super.dispose();
  }
}
