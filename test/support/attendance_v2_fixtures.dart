/// Fictional fixtures matching SQL RPC acknowledgements: no SELECT-only id,
/// site_description or employee_note fields are added to attendance receipts.
// Keep these SQL vocabularies independent of the model's accepted-value sets.
const sqlLocationContexts = [
  'factory',
  'external_worksite',
  'location_unverified',
];
const sqlReviewStatuses = [
  'normal',
  'anomaly_open',
  'correction_pending',
  'reviewed',
  'corrected',
  'disputed',
];

Map<String, dynamic> legacyAttendanceReceipt({
  String status = 'created',
  String context = 'factory',
  String sessionId = 'session-1',
  bool closed = false,
}) => {
  'status': status,
  'session_id': sessionId,
  'lifecycle_status': closed ? 'closed_manual' : 'active',
  'location_context': context,
  'started_at': '2026-10-15T14:00:00+00:00',
  'ended_at': closed ? '2026-10-15T22:00:00+00:00' : null,
};

Map<String, dynamic> v2AttendanceReceipt({
  String status = 'created',
  String context = 'factory',
  String? departure,
  String? reasonCode,
  String review = 'normal',
  bool closed = false,
}) => {
  ...legacyAttendanceReceipt(status: status, context: context, closed: closed),
  'contract_version': 2,
  'review_status': review,
  'event_id': closed ? 'checkout-event' : 'check-in-event',
  'location_outcome': {
    'classification': departure ?? context,
    'reason_code': reasonCode,
    'policy_version': 'dev-v1',
  },
};

Map<String, dynamic> attendanceSessionRow({
  String context = 'factory',
  String? description,
  String? note,
  String review = 'normal',
}) => {
  'id': 'session-1',
  'location_context': context,
  'lifecycle_status': 'active',
  'started_at': '2026-10-15T14:00:00+00:00',
  'ended_at': null,
  'site_description': description,
  'employee_note': note,
  'review_status': review,
};
