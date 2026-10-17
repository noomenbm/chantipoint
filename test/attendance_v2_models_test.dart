import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_receipt.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attendance_v2_fixtures.dart';

void main() {
  for (final context in sqlLocationContexts) {
    test('SELECT preserves $context arrival, description and general note', () {
      final row = attendanceSessionRow(
        context: context,
        description: context == 'factory'
            ? 'JMService — nom du serveur'
            : 'Chantier facultatif',
        note: 'Le client ne s’est pas présenté aujourd’hui.',
      );
      final session = WorkSession.fromJson(row);
      expect(session.locationContext, context);
      expect(session.siteDescription, row['site_description']);
      expect(session.employeeNote, row['employee_note']);
      expect(session.startedAt, DateTime.utc(2026, 10, 15, 14));
      expect(session.startedAt.isUtc, isTrue);
    });
  }
  for (final review in sqlReviewStatuses) {
    test('SELECT and v2 receipt preserve review status $review', () {
      expect(
        WorkSession.fromJson(attendanceSessionRow(review: review)).reviewStatus,
        review,
      );
      expect(
        AttendanceReceipt.fromJson(v2AttendanceReceipt(review: review))
            .session!
            .reviewStatus,
        review,
      );
    });
  }
  test('legacy rows and six-field receipts do not invent optional data', () {
    final receipt = AttendanceReceipt.fromJson(legacyAttendanceReceipt());
    expect(receipt.status, AttendanceReceiptStatus.created);
    expect(receipt.isAcknowledged, isTrue);
    expect(receipt.contractVersion, isNull);
    expect(receipt.eventId, isNull);
    expect(receipt.locationOutcome, isNull);
    expect(receipt.session!.siteDescription, isNull);
    expect(receipt.session!.employeeNote, isNull);
    expect(receipt.session!.reviewStatus, isNull);
  });
  for (final closed in [false, true]) {
    test('legacy replay preserves current closed=$closed lifecycle', () {
      final receipt = AttendanceReceipt.fromJson(
        legacyAttendanceReceipt(status: 'idempotent_replay', closed: closed),
      );
      expect(receipt.status, AttendanceReceiptStatus.idempotentReplay);
      expect(receipt.session!.isActive, !closed);
    });
  }
  test('checkout outcome does not overwrite arrival classification', () {
    final receipt = AttendanceReceipt.fromJson(
      v2AttendanceReceipt(
        status: 'closed',
        closed: true,
        context: 'factory',
        departure: 'location_unverified',
        reasonCode: 'permission_denied',
        review: 'anomaly_open',
      ),
    );
    expect(receipt.status, AttendanceReceiptStatus.closed);
    expect(receipt.session!.locationContext, 'factory');
    expect(receipt.locationOutcome!.classification, 'location_unverified');
    expect(receipt.locationOutcome!.reasonCode, 'permission_denied');
    expect(receipt.locationOutcome!.policyVersion, 'dev-v1');
    expect(receipt.eventId, 'checkout-event');
    expect(receipt.session!.endedAt!.isUtc, isTrue);
  });
  test('replay-only miss contains no fabricated attendance', () {
    final receipt = AttendanceReceipt.fromJson({
      'contract_version': 2,
      'status': 'not_found',
    });
    expect(receipt.status, AttendanceReceiptStatus.notFound);
    expect(receipt.isAcknowledged, isFalse);
    expect(receipt.session, isNull);
    expect(receipt.eventId, isNull);
    expect(receipt.locationOutcome, isNull);
  });
  for (final field in [
    'contract_version',
    'status',
    'session_id',
    'lifecycle_status',
    'location_context',
    'started_at',
    'ended_at',
    'review_status',
    'event_id',
    'location_outcome',
  ]) {
    test('incomplete v2 receipt missing $field is rejected', () {
      final row = v2AttendanceReceipt()..remove(field);
      expect(() => AttendanceReceipt.fromJson(row), throwsFormatException);
    });
  }
  for (final field in ['classification', 'reason_code', 'policy_version']) {
    test('incomplete outcome missing $field is rejected', () {
      final row = v2AttendanceReceipt();
      (row['location_outcome'] as Map).remove(field);
      expect(() => AttendanceReceipt.fromJson(row), throwsFormatException);
    });
  }
  final malformed = <String, Map<String, dynamic>>{
    'unsupported contract': {'contract_version': 3},
    'NULL contract': {'contract_version': null},
    'floating contract': {'contract_version': 2.0},
    'unknown status': {'status': 'accepted'},
    'blank event': {'event_id': ''},
    'NULL review': {'review_status': null},
    'unknown review': {'review_status': 'approved'},
    'unknown context': {'location_context': 'home'},
    'missing offset': {'started_at': '2026-10-15T14:00:00'},
    'invalid timestamp': {'started_at': 'invalidZ'},
    'created already closed': {
      'ended_at': '2026-10-15T22:00:00Z',
      'lifecycle_status': 'closed_manual',
    },
    'closed still active': {'status': 'closed'},
    'disagreeing identifiers': {'id': 'another-session'},
    'NULL outcome': {'location_outcome': null},
    'invalid outcome': {
      'location_outcome': {
        'classification': 'home',
        'reason_code': null,
        'policy_version': 'dev-v1',
      },
    },
    'empty policy': {
      'location_outcome': {
        'classification': 'factory',
        'reason_code': null,
        'policy_version': '',
      },
    },
    'invalid reason': {
      'location_outcome': {
        'classification': 'factory',
        'reason_code': 42,
        'policy_version': 'dev-v1',
      },
    },
    'miss with session': {'status': 'not_found'},
  };
  for (final entry in malformed.entries) {
    test('malformed receipt: ${entry.key}', () {
      expect(
        () => AttendanceReceipt.fromJson({
          ...v2AttendanceReceipt(),
          ...entry.value,
        }),
        throwsFormatException,
      );
    });
  }
  test('optional row data validates types, review enum and Unicode length', () {
    for (final patch in [
      {'site_description': 7},
      {'employee_note': true},
      {'review_status': 'unknown'},
      {'employee_note': '🚧' * 1001},
      {'site_description': 'é' * 501},
    ]) {
      expect(
        () => WorkSession.fromJson({...attendanceSessionRow(), ...patch}),
        throwsFormatException,
      );
    }
    final text = '${'é' * 999}🚧';
    expect(
      WorkSession.fromJson(attendanceSessionRow(note: text)).employeeNote,
      text,
    );
  });
  test('missing GPS and NULL diagnostic inputs remain genuinely absent', () {
    final unknown = const LocationEvidence().toRpcParameters();
    expect(unknown, {
      'p_latitude': null,
      'p_longitude': null,
      'p_accuracy_meters': null,
      'p_location_observed_at': null,
      'p_permission': 'unknown',
      'p_services_enabled': null,
      'p_location_result': 'unknown',
      'p_provider': 'unknown',
    });
    final nulls = const LocationEvidence(
      permission: null,
      result: null,
      provider: null,
    ).toRpcParameters();
    expect(nulls['p_permission'], isNull);
    expect(nulls['p_location_result'], isNull);
    expect(nulls['p_provider'], isNull);
  });
  test('diagnostic enums match the finalized SQL input values', () {
    expect(LocationPermissionState.values.map((value) => value.sqlValue), [
      'precise',
      'approximate',
      'denied',
      'unknown',
    ]);
    expect(LocationAcquisitionResult.values.map((value) => value.sqlValue), [
      'fix',
      'permission_denied',
      'location_services_disabled',
      'timeout',
      'provider_error',
      'unavailable',
      'unknown',
    ]);
    expect(LocationProvider.values.map((value) => value.sqlValue), [
      'gps',
      'network',
      'fused',
      'emulator',
      'unknown',
    ]);
  });
  test(
    'genuine low-quality claims are not rounded, clamped or reclassified',
    () {
      final oldFix = DateTime.utc(2020);
      final evidence = LocationEvidence(
        latitude: 91.0000001,
        accuracyMeters: -1,
        observedAt: oldFix,
        permission: LocationPermissionState.approximate,
        result: LocationAcquisitionResult.fix,
      );
      expect(evidence.toRpcParameters()['p_latitude'], 91.0000001);
      expect(evidence.toRpcParameters()['p_longitude'], isNull);
      expect(evidence.toRpcParameters()['p_accuracy_meters'], -1);
      expect(
        evidence.toRpcParameters()['p_location_observed_at'],
        oldFix.toIso8601String(),
      );
    },
  );
  test(
    'non-finite claims fail instead of JSON silently converting them to NULL',
    () {
      for (final evidence in [
        LocationEvidence(latitude: double.nan),
        LocationEvidence(longitude: double.infinity),
        LocationEvidence(accuracyMeters: double.negativeInfinity),
      ]) {
        expect(evidence.toRpcParameters, throwsFormatException);
      }
    },
  );
  test('request replay changes only the operational flag, never evidence or note intent', () {
    final request = CheckOutV2Request(
      workSessionId: 'session-1',
      idempotencyKey: 'immutable-key-001',
      deviceObservedAt: DateTime.parse('2026-10-15T10:00:00-04:00'),
      evidence: LocationEvidence(
        latitude: 45.123456789,
        longitude: -73.123456789,
        accuracyMeters: 10.12345,
        observedAt: DateTime.parse('2026-10-15T09:59:58-04:00'),
      ),
      noteIntent: const CheckoutNoteIntent.replace('  e\u0301 🚧  '),
    );
    final first = request.toRpcParameters();
    final replay = request.toRpcParameters(replayOnly: true);
    expect(replay, {...first, 'p_replay_only': true});
    expect(first['p_replay_only'], isFalse);
    expect(first['p_device_observed_at'], '2026-10-15T14:00:00.000Z');
    expect(first['p_location_observed_at'], '2026-10-15T13:59:58.000Z');
    expect(first['p_employee_note'], '  e\u0301 🚧  ');
    expect(() => first['p_latitude'] = 0, throwsUnsupportedError);
  });
  test('note update receipts distinguish clear and empty text', () {
    for (final note in [null, '', 'Un texte de travail']) {
      expect(
        EmployeeNoteUpdateResult.fromJson({
          'status': 'updated',
          'session_id': 'session-1',
          'employee_note': note,
        }).employeeNote,
        note,
      );
    }
    expect(
      () => EmployeeNoteUpdateResult.fromJson({
        'status': 'updated',
        'session_id': 'session-1',
      }),
      throwsFormatException,
    );
  });
}
