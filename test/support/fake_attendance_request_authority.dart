// Fictional host authority only. No SDK auth, tokens or network accounts.
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_request_authority.dart';

import 'fake_attendance_operation_ports.dart';

class FictionalRequestAuthority implements AttendanceRequestAuthority {
  FictionalRequestAuthority(this.issuer);
  final FictionalAttendanceIssuer issuer;
  bool authorized = true;
  bool throwOnCurrent = false;
  int acquisitions = 0;
  Future<AttendanceRequestScope> Function(AttendanceOperationIdentity)?
  onAcquire;
  @override
  bool isCurrent(AttendanceOperationIdentity identity) {
    if (throwOnCurrent) throw StateError('fictional private authority error');
    return authorized &&
        issuer.binding.matches(identity.binding) &&
        issuer.generation == identity.generation;
  }

  AttendanceRequestScope scope({
    AttendanceOperationIdentity? asIdentity,
    Uri? projectUrl,
    String token = 'fictional-pinned-token',
    String key = 'fictional-publishable-key',
    bool Function()? current,
  }) {
    final captured =
        asIdentity ??
        AttendanceOperationIdentity(issuer.binding, issuer.generation);
    return AttendanceRequestScope(
      identity: captured,
      projectUrl: projectUrl ?? Uri.parse(captured.binding.baseUrl),
      publishableKey: key,
      accessToken: token,
      isCurrent: current ?? () => isCurrent(captured),
    );
  }

  @override
  Future<AttendanceRequestScope> acquire(
    AttendanceOperationIdentity identity,
  ) async {
    acquisitions++;
    return onAcquire == null ? scope() : await onAcquire!(identity);
  }
}
