import 'attendance_models.dart';

enum AttendanceReceiptStatus {
  created('created'),
  closed('closed'),
  idempotentReplay('idempotent_replay'),
  notFound('not_found');

  const AttendanceReceiptStatus(this.sqlValue);
  final String sqlValue;
}

class LocationOutcome {
  const LocationOutcome._(
    this.classification,
    this.reasonCode,
    this.policyVersion,
  );

  final String classification;
  final String? reasonCode;
  final String policyVersion;

  factory LocationOutcome.fromJson(Map<String, dynamic> json) {
    final classification = json['classification'];
    final reason = json['reason_code'];
    final policy = json['policy_version'];
    if (!WorkSession.locationContexts.contains(classification) ||
        !json.containsKey('reason_code') ||
        (reason != null &&
            (reason is! String ||
                reason.isEmpty ||
                reason.runes.length > 80)) ||
        policy is! String ||
        policy.isEmpty) {
      throw const FormatException('Invalid location outcome');
    }
    return LocationOutcome._(
      classification as String,
      reason as String?,
      policy,
    );
  }
}

/// An operation receipt is separate from the session's arrival classification.
/// A replay-only miss has no fabricated session, event or location outcome.
class AttendanceReceipt {
  const AttendanceReceipt._({
    required this.status,
    this.contractVersion,
    this.session,
    this.eventId,
    this.locationOutcome,
  });

  final int? contractVersion;
  final AttendanceReceiptStatus status;
  final WorkSession? session;
  final String? eventId;
  final LocationOutcome? locationOutcome;
  bool get isAcknowledged => status != AttendanceReceiptStatus.notFound;

  factory AttendanceReceipt.fromJson(Map<String, dynamic> json) {
    final status = AttendanceReceiptStatus.values
        .where((value) => value.sqlValue == json['status'])
        .firstOrNull;
    if (status == null ||
        (json.containsKey('contract_version') &&
            (json['contract_version'] is! int ||
                json['contract_version'] != 2))) {
      throw const FormatException('Invalid attendance contract');
    }
    final isV2 = json['contract_version'] == 2;
    if (status == AttendanceReceiptStatus.notFound) {
      if (!isV2 || json.length != 2) {
        throw const FormatException('Invalid replay-only miss');
      }
      return AttendanceReceipt._(status: status, contractVersion: 2);
    }
    const requiredFields = {
      'status',
      'session_id',
      'lifecycle_status',
      'location_context',
      'started_at',
      'ended_at',
    };
    if (!json.keys.toSet().containsAll(requiredFields) ||
        json['session_id'] is! String ||
        (json['session_id'] as String).isEmpty ||
        (json.containsKey('id') && json['id'] != json['session_id'])) {
      throw const FormatException('Incomplete attendance receipt');
    }
    final session = WorkSession.fromJson(json);
    if ((status == AttendanceReceiptStatus.created && !session.isActive) ||
        (status == AttendanceReceiptStatus.closed &&
            session.lifecycleStatus != 'closed_manual')) {
      throw const FormatException('Inconsistent attendance receipt');
    }
    if (!isV2) {
      if (json.length != requiredFields.length) {
        throw const FormatException('Invalid legacy receipt');
      }
      return AttendanceReceipt._(status: status, session: session);
    }
    final event = json['event_id'];
    final outcome = json['location_outcome'];
    if (session.reviewStatus == null ||
        event is! String ||
        event.isEmpty ||
        outcome is! Map<String, dynamic>) {
      throw const FormatException('Incomplete v2 receipt');
    }
    return AttendanceReceipt._(
      contractVersion: 2,
      status: status,
      session: session,
      eventId: event,
      locationOutcome: LocationOutcome.fromJson(outcome),
    );
  }
}

class EmployeeNoteUpdateResult {
  const EmployeeNoteUpdateResult._(this.sessionId, this.employeeNote);

  final String sessionId;
  final String? employeeNote;

  factory EmployeeNoteUpdateResult.fromJson(Map<String, dynamic> json) {
    final id = json['session_id'];
    final note = json['employee_note'];
    if (json['status'] != 'updated' ||
        id is! String ||
        id.isEmpty ||
        !json.containsKey('employee_note') ||
        (note != null && (note is! String || note.runes.length > 1000))) {
      throw const FormatException('Invalid employee note receipt');
    }
    return EmployeeNoteUpdateResult._(id, note as String?);
  }
}
