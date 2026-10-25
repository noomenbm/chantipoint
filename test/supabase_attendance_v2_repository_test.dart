import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_receipt.dart';
import 'package:chantipoint/src/attendance/attendance_repository.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_repository.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/attendance_v2_fixtures.dart';
import 'support/test_users.dart';
import 'support/legacy_writer_native_fixture.dart';

void main() {
  legacyWriterNativeFixture();
  late SupabaseClient client;
  late AttendanceV2Repository repository;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  late Object? response;
  late int status;

  http.Response reply(http.Request request, Object? body, [int code = 200]) =>
      http.Response(
        jsonEncode(body),
        code,
        request: request,
        headers: {'content-type': 'application/json'},
      );
  const checkIn = CheckInV2Request(idempotencyKey: 'v2-check-in-key-001');
  const checkOut = CheckOutV2Request(
    workSessionId: 'session-1',
    idempotencyKey: 'v2-check-out-key-001',
  );

  setUp(() async {
    requests = [];
    response = v2AttendanceReceipt();
    status = 200;
    handler = (request) async => reply(request, response, status);
    client = SupabaseClient(
      'https://fictional.example.test',
      'fictional-publishable-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/logout')) return reply(request, {});
        return handler(request);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: const PostgrestClientOptions(
        retryEnabled: false,
        retryCount: 0,
      ),
    );
    await _authenticate(client, 'fictional-auth-user');
    repository = SupabaseAttendanceRepository(client, testEmployee);
  });
  tearDown(() => client.dispose());

  for (final context in sqlLocationContexts) {
    test(
      'v2 check-in accepts server-derived $context with no client classification',
      () async {
        response = v2AttendanceReceipt(
          context: context,
          review: context == 'location_unverified' ? 'anomaly_open' : 'normal',
          reasonCode: context == 'location_unverified'
              ? 'factory_configuration_missing'
              : null,
        );
        final receipt = await repository.checkInV2(checkIn);
        expect(receipt.status, AttendanceReceiptStatus.created);
        expect(receipt.contractVersion, 2);
        expect(receipt.session!.locationContext, context);
        expect(receipt.locationOutcome!.classification, context);
        expect(requests.single.url.path, '/rest/v1/rpc/check_in_v2');
        expect(requests.single.method, 'POST');
        expect(jsonDecode(requests.single.body), {
          'p_idempotency_key': 'v2-check-in-key-001',
          'p_device_observed_at': null,
          'p_site_description': null,
          'p_latitude': null,
          'p_longitude': null,
          'p_accuracy_meters': null,
          'p_location_observed_at': null,
          'p_permission': 'unknown',
          'p_services_enabled': null,
          'p_location_result': 'unknown',
          'p_provider': 'unknown',
          'p_replay_only': false,
        });
      },
    );
  }
  test('exact check-in params preserve action/fix times, description and raw evidence', () async {
    final request = CheckInV2Request(
      idempotencyKey: 'v2-evidence-key-001',
      deviceObservedAt: DateTime.parse('2026-10-15T10:00:05-04:00'),
      siteDescription: '  chantier proposé  ',
      evidence: LocationEvidence(
        latitude: 45.123456789,
        longitude: -73.987654321,
        accuracyMeters: 10.12345,
        observedAt: DateTime.parse('2026-10-15T10:00:01-04:00'),
        permission: LocationPermissionState.precise,
        servicesEnabled: true,
        result: LocationAcquisitionResult.fix,
        provider: LocationProvider.fused,
      ),
    );
    final receipt = await repository.checkInV2(request);
    expect(jsonDecode(requests.single.body), {
      'p_idempotency_key': 'v2-evidence-key-001',
      'p_device_observed_at': '2026-10-15T14:00:05.000Z',
      'p_site_description': '  chantier proposé  ',
      'p_latitude': 45.123456789,
      'p_longitude': -73.987654321,
      'p_accuracy_meters': 10.12345,
      'p_location_observed_at': '2026-10-15T14:00:01.000Z',
      'p_permission': 'precise',
      'p_services_enabled': true,
      'p_location_result': 'fix',
      'p_provider': 'fused',
      'p_replay_only': false,
    });
    expect(
      receipt.session!.siteDescription,
      isNull,
      reason: 'SQL receipt omits description; never fill a factory name from client text',
    );
  });
  for (final context in sqlLocationContexts) {
    test(
      'v2 SELECT scopes $context and returns backend site name/note',
      () async {
        final description = context == 'factory'
            ? 'Nom usine fourni par le serveur'
            : 'Chantier facultatif';
        response = [
          attendanceSessionRow(
            context: context,
            description: description,
            note: 'Le client ne s’est pas présenté.',
            review: 'anomaly_open',
          ),
        ];
        final session = await repository.activeSessionV2();
        expect(session!.siteDescription, description);
        expect(session.employeeNote, 'Le client ne s’est pas présenté.');
        expect(session.reviewStatus, 'anomaly_open');
        final query = requests.single.url.queryParameters;
        expect(query['employee_profile_id'], 'eq.${testEmployee.profileId}');
        expect(query['company_id'], 'eq.${testEmployee.companyId}');
        expect(query['lifecycle_status'], 'eq.active');
        expect(query['select'], contains('employee_note'));
        expect(query['select'], contains('review_status'));
        expect(query['select'], isNot(contains('latitude')));
      },
    );
  }
  test(
    'legacy SELECT never requests columns missing on hosted baseline',
    () async {
      response = [];
      await (repository as AttendanceRepository).activeSession();
      expect(
        requests.single.url.queryParameters['select'],
        'id,location_context,lifecycle_status,started_at,ended_at,site_description,check_in_device_observed_at,check_out_device_observed_at',
      );
    },
  );
  for (final intent in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.replace('  Note finale 🚧  '),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace(''),
  ]) {
    test(
      'checkout ${intent.action.name}/${intent.text == '' ? 'empty' : 'value'} preserves independent departure',
      () async {
        response = v2AttendanceReceipt(
          status: 'closed',
          closed: true,
          context: 'factory',
          departure: 'external_worksite',
          review: 'reviewed',
        );
        final receipt = await repository.checkOutV2(
          CheckOutV2Request(
            workSessionId: 'session-1',
            idempotencyKey: 'v2-note-out-key-001',
            noteIntent: intent,
          ),
        );
        expect(receipt.status, AttendanceReceiptStatus.closed);
        expect(receipt.session!.locationContext, 'factory');
        expect(receipt.locationOutcome!.classification, 'external_worksite');
        expect(receipt.session!.reviewStatus, 'reviewed');
        expect(requests.single.url.path, '/rest/v1/rpc/check_out_v2');
        expect(jsonDecode(requests.single.body), {
          'p_work_session_id': 'session-1',
          'p_idempotency_key': 'v2-note-out-key-001',
          'p_device_observed_at': null,
          'p_latitude': null,
          'p_longitude': null,
          'p_accuracy_meters': null,
          'p_location_observed_at': null,
          'p_permission': 'unknown',
          'p_services_enabled': null,
          'p_location_result': 'unknown',
          'p_provider': 'unknown',
          'p_replay_only': false,
          'p_note_action': intent.action.name,
          'p_employee_note': intent.text,
        });
      },
    );
  }
  test('checkout accepts an unverified arrival with separately unavailable departure', () async {
    response = v2AttendanceReceipt(
      status: 'closed',
      closed: true,
      context: 'location_unverified',
      reasonCode: 'permission_denied',
      review: 'anomaly_open',
    );
    final receipt = await repository.checkOutV2(
      const CheckOutV2Request(
        workSessionId: 'session-1',
        idempotencyKey: 'v2-no-gps-out-001',
        evidence: LocationEvidence(
          permission: LocationPermissionState.denied,
          servicesEnabled: false,
          result: LocationAcquisitionResult.permissionDenied,
        ),
      ),
    );
    expect(receipt.isAcknowledged, isTrue);
    expect(receipt.locationOutcome!.reasonCode, 'permission_denied');
    final body = jsonDecode(requests.single.body) as Map;
    expect(body['p_permission'], 'denied');
    expect(body['p_location_result'], 'permission_denied');
    expect(body['p_note_action'], 'preserve');
    expect(body['p_employee_note'], isNull);
    expect(body['p_location_observed_at'], isNull);
  });
  test('check-in retry and replay preserve original semantic payload after closure', () async {
    final request = CheckInV2Request(
      idempotencyKey: 'v2-replay-in-key-001',
      deviceObservedAt: DateTime.utc(2026, 10, 15, 13),
      siteDescription: 'Original description',
      evidence: LocationEvidence(
        latitude: 45,
        longitude: -73,
        accuracyMeters: 80,
        observedAt: DateTime.utc(2026, 10, 15, 12, 59),
        permission: LocationPermissionState.approximate,
        servicesEnabled: true,
        result: LocationAcquisitionResult.fix,
        provider: LocationProvider.network,
      ),
    );
    await repository.checkInV2(request);
    response = v2AttendanceReceipt(status: 'idempotent_replay', closed: true);
    final replay = await repository.checkInV2(request, replayOnly: true);
    expect(replay.status, AttendanceReceiptStatus.idempotentReplay);
    expect(replay.session!.isActive, isFalse);
    expect(jsonDecode(requests.last.body), {
      ...jsonDecode(requests.first.body) as Map,
      'p_replay_only': true,
    });
  });
  test('checkout replay keeps exact evidence and final note', () async {
    final request = CheckOutV2Request(
      workSessionId: 'session-1',
      idempotencyKey: 'v2-replay-out-key-001',
      deviceObservedAt: DateTime.utc(2026, 10, 15, 20),
      evidence: LocationEvidence(
        latitude: 45.111111111,
        longitude: -73.222222222,
        accuracyMeters: 30.123,
        observedAt: DateTime.utc(2026, 10, 15, 19, 59),
        permission: LocationPermissionState.precise,
        servicesEnabled: true,
        result: LocationAcquisitionResult.fix,
        provider: LocationProvider.fused,
      ),
      noteIntent: const CheckoutNoteIntent.replace('Final unchanged note'),
    );
    response = v2AttendanceReceipt(status: 'closed', closed: true);
    final first = await repository.checkOutV2(request);
    response = v2AttendanceReceipt(status: 'idempotent_replay', closed: true);
    final replay = await repository.checkOutV2(request, replayOnly: true);
    expect(replay.eventId, first.eventId);
    expect(replay.session!.endedAt, first.session!.endedAt);
    expect(jsonDecode(requests.last.body), {
      ...jsonDecode(requests.first.body) as Map,
      'p_replay_only': true,
    });
  });
  for (final checkout in [false, true]) {
    test(
      'replay-only miss for checkout=$checkout is not attendance success',
      () async {
        response = {'contract_version': 2, 'status': 'not_found'};
        final receipt = checkout
            ? await repository.checkOutV2(checkOut, replayOnly: true)
            : await repository.checkInV2(checkIn, replayOnly: true);
        expect(receipt.status, AttendanceReceiptStatus.notFound);
        expect(receipt.isAcknowledged, isFalse);
        expect(receipt.session, isNull);
        expect(requests, hasLength(1));
      },
    );
  }
  for (final scenario in [
    'legacy on v2',
    'not_found on write',
    'created on replay',
    'closed on check-in',
    'missing outcome',
    'wrong check-in outcome',
    'wrong checkout session',
    'active checkout',
  ]) {
    test(
      'repository rejects incompatible acknowledgement: $scenario',
      () async {
        var checkout = false;
        var replay = false;
        switch (scenario) {
          case 'legacy on v2':
            response = legacyAttendanceReceipt();
          case 'not_found on write':
            response = {'contract_version': 2, 'status': 'not_found'};
          case 'created on replay':
            replay = true;
          case 'closed on check-in':
            response = v2AttendanceReceipt(status: 'closed', closed: true);
          case 'missing outcome':
            response = v2AttendanceReceipt()..remove('location_outcome');
          case 'wrong check-in outcome':
            response = v2AttendanceReceipt(departure: 'external_worksite');
          case 'wrong checkout session':
            checkout = true;
            response = {
              ...v2AttendanceReceipt(status: 'closed', closed: true),
              'session_id': 'another-session',
            };
          case 'active checkout':
            checkout = true;
            response = v2AttendanceReceipt(status: 'idempotent_replay');
        }
        await expectLater(
          checkout
              ? repository.checkOutV2(checkOut, replayOnly: replay)
              : repository.checkInV2(checkIn, replayOnly: replay),
          throwsA(_failure(AttendanceFailureKind.backend)),
        );
        expect(
          requests,
          hasLength(1),
          reason: 'Never fall back to a legacy write',
        );
      },
    );
  }
  for (final note in [null, '', '  General note 🚧  ', '🚧' * 1000]) {
    test(
      'standalone note update preserves exact ${note == null ? 'clear' : 'text/${note.runes.length}'} semantics',
      () async {
        response = {
          'status': 'updated',
          'session_id': 'session-1',
          'employee_note': note,
        };
        final result = await repository.updateEmployeeNote(
          workSessionId: 'session-1',
          employeeNote: note,
        );
        expect(result.sessionId, 'session-1');
        expect(result.employeeNote, note);
        expect(requests.single.url.path, '/rest/v1/rpc/update_employee_note');
        expect(jsonDecode(requests.single.body), {
          'p_work_session_id': 'session-1',
          'p_employee_note': note,
        });
      },
    );
  }
  for (final bad in [
    {'status': 'updated', 'session_id': 'session-1'},
    {
      'status': 'updated',
      'session_id': 'another-session',
      'employee_note': 'expected',
    },
    {
      'status': 'updated',
      'session_id': 'session-1',
      'employee_note': 'different',
    },
    {
      'status': 'closed',
      'session_id': 'session-1',
      'employee_note': 'expected',
    },
  ]) {
    test(
      'malformed/mismatched note acknowledgement is rejected: $bad',
      () async {
        response = bad;
        await expectLater(
          repository.updateEmployeeNote(
            workSessionId: 'session-1',
            employeeNote: 'expected',
          ),
          throwsA(_failure(AttendanceFailureKind.backend)),
        );
        expect(requests, hasLength(1));
      },
    );
  }
  final errors = {
    'active_session_exists': AttendanceFailureKind.duplicateActive,
    'session_not_active': AttendanceFailureKind.sessionNotActive,
    'idempotency_key_conflict': AttendanceFailureKind.idempotencyConflict,
    'employee_role_required': AttendanceFailureKind.unauthorized,
    'active_session_not_found_for_employee': AttendanceFailureKind.unauthorized,
    'authentication_required': AttendanceFailureKind.sessionExpired,
    'attendance_contract_not_enabled':
        AttendanceFailureKind.contractUnavailable,
    'attendance_client_update_required':
        AttendanceFailureKind.contractUnavailable,
    'invalid_employee_note_operation': AttendanceFailureKind.invalidRequest,
    'employee_note_too_long': AttendanceFailureKind.employeeNoteTooLong,
    'company_not_active': AttendanceFailureKind.companyInactive,
    'attendance_receipt_unavailable': AttendanceFailureKind.backend,
    'private backend grant failure': AttendanceFailureKind.backend,
  };
  for (final entry in errors.entries) {
    test('v2 RPC ${entry.key} remains a safe failure, never a miss', () async {
      status = 400;
      response = {'code': '42501', 'message': entry.key};
      await expectLater(
        repository.checkInV2(checkIn),
        throwsA(_failure(entry.value)),
      );
      expect(
        AttendanceFailure(entry.value).message,
        isNot(contains(entry.key)),
      );
      expect(requests, hasLength(1));
      expect(client.auth.currentSession, isNotNull);
    });
  }
  for (final operation in ['check-in', 'checkout', 'note', 'read']) {
    test(
      '$operation network failure preserves session without a fallback write',
      () async {
        handler = (_) async =>
            throw http.ClientException('private transport details');
        await expectLater(switch (operation) {
          'check-in' => repository.checkInV2(checkIn),
          'checkout' => repository.checkOutV2(checkOut),
          'note' => repository.updateEmployeeNote(
            workSessionId: 'session-1',
            employeeNote: 'note',
          ),
          _ => repository.activeSessionV2(),
        }, throwsA(_failure(AttendanceFailureKind.network)));
        if (operation == 'read') {
          // Read retries are SDK policy, separate from retrying mutations.
          expect(requests, isNotEmpty);
          expect(
            requests.every(
              (request) =>
                  request.method == 'GET' &&
                  request.url.path == '/rest/v1/work_sessions' &&
                  request.url == requests.first.url,
            ),
            isTrue,
          );
        } else {
          expect(requests, hasLength(1));
        }
        expect(client.auth.currentSession, isNotNull);
      },
    );
  }
  for (final message in ['company_not_active', 'invalid_idempotency_key']) {
    test('legacy error handling remains unchanged for $message', () async {
      status = 400;
      response = {'code': 'P0001', 'message': message};
      await expectLater(
        (repository as AttendanceRepository).submit(
          AttendanceCommand.factoryCheckIn(),
        ),
        throwsA(_failure(AttendanceFailureKind.backend)),
      );
      expect(requests.single.url.path, '/rest/v1/rpc/check_in');
    });
  }
  test(
    'query permission error is backend failure, not authorization denial',
    () async {
      status = 403;
      response = {'code': '42501', 'message': 'private grant problem'};
      await expectLater(
        repository.activeSessionV2(),
        throwsA(_failure(AttendanceFailureKind.backend)),
      );
      expect(client.auth.currentSession, isNotNull);
    },
  );
  test('expired PostgREST token is distinguished', () async {
    status = 401;
    response = {'code': 'PGRST301', 'message': 'private jwt problem'};
    await expectLater(
      repository.checkOutV2(checkOut),
      throwsA(_failure(AttendanceFailureKind.sessionExpired)),
    );
  });
  test('admin-only profile cannot invoke any isolated API', () async {
    repository = SupabaseAttendanceRepository(
      client,
      const AuthorizedUser(
        profileId: 'admin',
        companyId: 'company',
        displayName: 'Fictional admin',
        email: '',
        roles: {AuthorizedRole.administrator},
      ),
    );
    for (final work in <Future<Object?> Function()>[
      () => repository.activeSessionV2(),
      () => repository.checkInV2(checkIn),
      () => repository.checkOutV2(checkOut),
      () => repository.updateEmployeeNote(
        workSessionId: 'session-1',
        employeeNote: null,
      ),
    ]) {
      await expectLater(
        work(),
        throwsA(_failure(AttendanceFailureKind.unauthorized)),
      );
    }
    expect(requests, isEmpty);
  });
  test('switching account before request makes no attendance call', () async {
    await _authenticate(client, 'different-auth-user');
    requests.clear();
    await expectLater(
      repository.checkInV2(checkIn),
      throwsA(_failure(AttendanceFailureKind.sessionExpired)),
    );
    expect(requests, isEmpty);
  });
  test(
    'account switch during a successful RPC cannot expose its receipt',
    () async {
      final delayed = Completer<http.Response>();
      handler = (_) => delayed.future;
      final operation = repository.checkInV2(checkIn);
      final expectation = expectLater(
        operation,
        throwsA(_failure(AttendanceFailureKind.sessionExpired)),
      );
      await Future<void>.delayed(Duration.zero);
      await _authenticate(client, 'different-auth-user');
      delayed.complete(reply(requests.single, v2AttendanceReceipt()));
      await expectation;
    },
  );
}

Matcher _failure(AttendanceFailureKind kind) =>
    isA<AttendanceFailure>().having((failure) => failure.kind, 'kind', kind);

Future<void> _authenticate(SupabaseClient client, String userId) async {
  String encode(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final token = '${encode({'alg': 'HS256'})}.${encode({'exp': expiry})}.test';
  await client.auth.setInitialSession(
    jsonEncode({
      'access_token': token,
      'refresh_token': 'fictional-refresh',
      'token_type': 'bearer',
      'user': {
        'id': userId,
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-10-01T00:00:00Z',
      },
    }),
  );
}
