import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';

import 'attendance_v2_fixtures.dart';

// Entirely fictional owner/session identifiers; no accounts or services used.
const journalSessionId = '00000000-0000-4000-8000-000000000010';
const journalOtherId = '00000000-0000-4000-8000-000000000020';
const journalKey = 'fictional-journal-key-0001';
final journalTime = DateTime.utc(2026, 10, 17, 14, 30);

JournalBinding journalBinding({
  String environment = 'fixture-deployment-1',
  String url = 'https://fixture.invalid',
  String auth = '00000000-0000-4000-8000-000000000001',
  String company = '00000000-0000-4000-8000-000000000002',
  String profile = '00000000-0000-4000-8000-000000000003',
}) => JournalBinding(
  environmentId: environment,
  baseUrl: url,
  authUserId: auth,
  companyId: company,
  profileId: profile,
);

WorkSession journalSession() => WorkSession(
  id: journalSessionId,
  locationContext: 'factory',
  lifecycleStatus: 'active',
  startedAt: journalTime,
);

JournalCommand journalCommand({
  JournalProtocol protocol = JournalProtocol.attendanceV2,
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
  String key = journalKey,
  CheckoutNoteIntent note = const CheckoutNoteIntent.preserve(),
}) {
  if (protocol == JournalProtocol.legacyV1) {
    return JournalCommand.legacy(
      operation == AttendanceCommandKind.checkIn
          ? AttendanceCommand.factoryCheckIn(key: key, observedAt: journalTime)
          : AttendanceCommand.checkOut(
              journalSession(),
              key: key,
              observedAt: journalTime,
            ),
    );
  }
  final evidence = LocationEvidence(
    latitude: 45.123456789,
    longitude: -73.234567891,
    accuracyMeters: 12.345,
    observedAt: journalTime.subtract(const Duration(seconds: 2)),
    permission: LocationPermissionState.precise,
    servicesEnabled: true,
    result: LocationAcquisitionResult.fix,
    provider: LocationProvider.fused,
  );
  return operation == AttendanceCommandKind.checkIn
      ? JournalCommand.checkInV2(
          CheckInV2Request(
            idempotencyKey: key,
            deviceObservedAt: journalTime,
            siteDescription: '  e\u0301 🚧  ',
            evidence: evidence,
          ),
        )
      : JournalCommand.checkOutV2(
          CheckOutV2Request(
            workSessionId: journalSessionId,
            idempotencyKey: key,
            deviceObservedAt: journalTime,
            evidence: evidence,
            noteIntent: note,
          ),
        );
}

Map<String, dynamic> journalReceipt(
  JournalCommand command, {
  bool replay = false,
}) {
  final out = command.operation == AttendanceCommandKind.checkOut;
  final status = replay
      ? 'idempotent_replay'
      : out
      ? 'closed'
      : 'created';
  final row = command.protocol == JournalProtocol.legacyV1
      ? legacyAttendanceReceipt(status: status, closed: out)
      : v2AttendanceReceipt(status: status, closed: out);
  row['session_id'] = journalSessionId;
  if (command.protocol == JournalProtocol.attendanceV2) {
    row['event_id'] = journalOtherId;
  }
  return row;
}

JournalConfirmation journalConfirmation(
  JournalCommand command, {
  bool replay = false,
}) => JournalConfirmation(
  source: command.protocol == JournalProtocol.legacyV1
      ? JournalConfirmationSource.rpcV1
      : JournalConfirmationSource.rpcV2,
  dataJson: JournalJson.encode(journalReceipt(command, replay: replay)),
  command: command,
);

JournalRecord recordAt(JournalPhase phase, {JournalCommand? command}) {
  var record = JournalRecord.absent(journalBinding());
  if (phase == JournalPhase.empty) {
    return JournalRecord.fromJson({...record.toJson(), 'revision': 1});
  }
  record = record.prepare(command ?? journalCommand());
  if (phase == JournalPhase.prepared) return record;
  record = record.markMayHaveSent();
  if (phase == JournalPhase.mayHaveSent) return record;
  record = record.markUncertain();
  if (phase == JournalPhase.uncertain) return record;
  record = record.confirm(journalConfirmation(record.command!));
  if (phase == JournalPhase.confirmed) return record;
  return record.blockRecovery(JournalBlockReason.manualReview);
}

List<int> legacySource({
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
  JournalBinding? binding,
}) {
  final owner = binding ?? journalBinding();
  final command = journalCommand(
    protocol: JournalProtocol.legacyV1,
    operation: operation,
  );
  return utf8.encode(
    jsonEncode({
      'version': 1,
      'kind': operation.name,
      'payload': command.parameters,
      'owner': '${owner.companyId}:${owner.profileId}',
    }),
  );
}

LegacyBindingApproval legacyApproval(
  List<int> source, {
  JournalBinding? binding,
}) {
  final owner = binding ?? journalBinding();
  final legacyOwner = '${owner.companyId}:${owner.profileId}';
  return LegacyBindingApproval(
    binding: owner,
    approvedSource: source,
    metadata: JournalMigration(
      sourceBasename:
          'attendance_${base64Url.encode(utf8.encode(legacyOwner)).replaceAll('=', '')}.json',
      sourceSha256: 'a' * 64,
      legacyOwner: legacyOwner,
      bindingApprovalRef: 'fictional-reviewed-deployment-record',
    ),
  );
}
