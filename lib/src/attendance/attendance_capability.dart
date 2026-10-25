import 'attendance_operation_transport.dart';
import 'journal/journal_json.dart';

/// Canonical server UUID, supplied independently by trusted deployment config.
/// Older journal environment strings remain readable, but cannot authorize v2.
bool isAttendanceEpoch(Object? value) =>
    value is String &&
    value.length == 36 &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);

/// A read-only snapshot, never device approval or a reusable dispatch lease.
final class AttendanceCapability {
  const AttendanceCapability._(this.deploymentEpoch, this.writeContract);

  static AttendanceCapability parse(String text) {
    final row = journalObject(JournalJson.decodeText(text, limit: 1024));
    journalFields(row, {
      'capability_version',
      'deployment_epoch',
      'write_contract',
      'v2_available',
    });
    if (row['capability_version'] is! int ||
        row['capability_version'] != 1 ||
        row['v2_available'] is! bool) {
      invalidJournal();
    }
    final epoch = row['deployment_epoch'];
    final gate = row['write_contract'];
    // The server's explicit missing-singleton response is unavailable, not an
    // invitation to fill in identity or mode from local/client state.
    if (epoch == null && gate == null && row['v2_available'] == false) {
      return const AttendanceCapability._(null, null);
    }
    if (!isAttendanceEpoch(epoch) ||
        gate is! int ||
        (gate != 1 && gate != 2) ||
        row['v2_available'] != (gate == 2)) {
      invalidJournal();
    }
    return AttendanceCapability._(epoch as String, gate);
  }

  final String? deploymentEpoch;
  final int? writeContract;
  bool get v2Available => deploymentEpoch != null && writeContract == 2;
}

abstract interface class AttendanceCapabilityReader {
  /// Must reject stale authorization and compare against an independently
  /// trusted scope epoch. Callers must not promote this snapshot to approval.
  Future<AttendanceCapability> readCapability(
    AttendanceOperationIdentity identity,
  );
}
