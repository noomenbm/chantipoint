import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_repository.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_attendance.dart';
import 'support/test_users.dart';
import 'support/legacy_writer_native_fixture.dart';

void main() {
  legacyWriterNativeFixture();
  late _Backend backend;
  late SupabaseClient client;
  late SupabaseAttendanceRepository repository;
  setUp(() async {
    backend = _Backend();
    client = SupabaseClient(
      'https://fictional.example.test',
      'fictional-client-key',
      httpClient: MockClient((request) async {
        final response = await backend.handle(request);
        return http.Response.bytes(
          response.bodyBytes,
          response.statusCode,
          headers: response.headers,
          request: request,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      postgrestOptions: const PostgrestClientOptions(
        retryEnabled: false,
        retryCount: 0,
      ),
    );
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    String encode(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final token = '${encode({'alg': 'HS256'})}.${encode({'exp': expiry})}.test';
    await client.auth.setInitialSession(
      jsonEncode({
        'access_token': token,
        'refresh_token': 'fictional-refresh',
        'token_type': 'bearer',
        'user': {
          'id': 'fictional-auth-user',
          'aud': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-10-01T00:00:00Z',
        },
      }),
    );
    repository = SupabaseAttendanceRepository(client, testEmployee);
  });
  tearDown(() => client.dispose());

  for (final identifier in ['id', 'session_id']) {
    test('WorkSession parses $identifier with PostgreSQL timestamps', () {
      final row = <String, dynamic>{
        identifier: 'session-1',
        'location_context': 'factory',
        'lifecycle_status': 'active',
        'started_at': '2026-10-15T14:00:00+00:00',
        'ended_at': null,
      };
      final active = WorkSession.fromJson(row);
      expect(active.id, 'session-1');
      expect(active.startedAt, serverStart);
      expect(active.startedAt.isUtc, isTrue);
      expect(active.isActive, isTrue);
      expect(active.endedAt, isNull);

      final closed = WorkSession.fromJson({
        ...row,
        'lifecycle_status': 'closed_manual',
        'ended_at': '2026-10-15T22:00:00+00:00',
      });
      expect(closed.id, active.id);
      expect(closed.isActive, isFalse);
      expect(closed.endedAt, serverStart.add(const Duration(hours: 8)));
      expect(closed.endedAt!.isUtc, isTrue);
    });
  }

  test('active session SELECT is scoped to employee/company and protected backend state', () async {
    expect(await repository.activeSession(), isNull);
    final request = backend.requests.single;
    expect(request.url.path, '/rest/v1/work_sessions');
    expect(
      request.url.queryParameters['employee_profile_id'],
      'eq.profile-employee',
    );
    expect(request.url.queryParameters['company_id'], 'eq.company-jmservice');
    expect(request.url.queryParameters['lifecycle_status'], 'eq.active');
    expect(request.method, 'GET');
    expect(request.url.queryParameters['select'], isNot(contains('latitude')));
  });

  test('active session SELECT parses id without session_id', () async {
    final submitted = await repository.submit(
      AttendanceCommand.factoryCheckIn(),
    );
    expect(backend.rows.single['id'], submitted.id);
    expect(backend.rows.single, isNot(contains('session_id')));

    final active = await repository.activeSession();
    expect(active!.id, submitted.id);
    expect(active.isActive, isTrue);
    expect(active.startedAt, serverStart);
  });

  test(
    'factory check-in and checkout accept exact SQL RPC shapes without GPS',
    () async {
      final command = AttendanceCommand.factoryCheckIn(
        observedAt: DateTime.utc(2026, 10, 15, 13),
      );
      final active = await repository.submit(command);
      expect(active.id, 'session-1');
      expect(active.isActive, isTrue);
      expect(active.endedAt, isNull);
      expect(active.startedAt, serverStart);
      expect(backend.acknowledgements.single, {
        'status': 'created',
        'session_id': 'session-1',
        'lifecycle_status': 'active',
        'location_context': 'factory',
        'started_at': '2026-10-15T14:00:00+00:00',
        'ended_at': null,
      });
      expect(
        active.startedAt,
        isNot(
          DateTime.parse(command.payload['p_device_observed_at'] as String),
        ),
      );
      expect(backend.payloads.single.keys.toSet(), {
        'p_location_context',
        'p_site_description',
        'p_device_observed_at',
        'p_idempotency_key',
      });
      expect(backend.payloads.single['p_location_context'], 'factory');
      final completed = await repository.submit(
        AttendanceCommand.checkOut(active),
      );
      expect(completed.id, active.id);
      expect(completed.isActive, isFalse);
      expect(completed.startedAt, serverStart);
      expect(completed.endedAt, serverStart.add(const Duration(hours: 8)));
      expect(backend.acknowledgements.last, {
        'status': 'closed',
        'session_id': 'session-1',
        'lifecycle_status': 'closed_manual',
        'location_context': 'factory',
        'started_at': '2026-10-15T14:00:00+00:00',
        'ended_at': '2026-10-15T22:00:00+00:00',
      });
      expect(backend.payloads.last.keys.toSet(), {
        'p_work_session_id',
        'p_idempotency_key',
        'p_device_observed_at',
      });
    },
  );

  test(
    'same command retry uses an identical payload and only one session',
    () async {
      final command = AttendanceCommand.factoryCheckIn();
      final first = await repository.submit(command);
      final replay = await repository.submit(
        AttendanceCommand.fromJson(command.toJson()),
      );
      expect(replay.id, first.id);
      expect(replay.isActive, isTrue);
      expect(replay.startedAt, first.startedAt);
      expect(backend.acknowledgements.last, {
        ...backend.acknowledgements.first,
        'status': 'idempotent_replay',
      });
      expect(backend.rows.length, 1);
      expect(backend.payloads[0], backend.payloads[1]);
    },
  );

  test(
    'checkout replay accepts session_id and the original server times',
    () async {
      final active = await repository.submit(
        AttendanceCommand.factoryCheckIn(),
      );
      final command = AttendanceCommand.checkOut(active);
      final first = await repository.submit(command);
      final replay = await repository.submit(
        AttendanceCommand.fromJson(command.toJson()),
      );

      expect(replay.id, first.id);
      expect(replay.isActive, isFalse);
      expect(replay.startedAt, first.startedAt);
      expect(replay.endedAt, first.endedAt);
      expect(backend.acknowledgements.last, {
        ...backend.acknowledgements[1],
        'status': 'idempotent_replay',
      });
      expect(backend.payloads[2], backend.payloads[1]);
      expect(backend.rows, hasLength(1));
    },
  );

  test('check-in replay may return a session that has since closed', () async {
    final command = AttendanceCommand.factoryCheckIn();
    final active = await repository.submit(command);
    final completed = await repository.submit(
      AttendanceCommand.checkOut(active),
    );
    final replay = await repository.submit(command);

    expect(replay.id, active.id);
    expect(replay.isActive, isFalse);
    expect(replay.endedAt, completed.endedAt);
    expect(backend.acknowledgements.last, {
      ...backend.acknowledgements[1],
      'status': 'idempotent_replay',
    });
    expect(backend.payloads[2], backend.payloads[0]);
    expect(backend.rows, hasLength(1));
  });

  test(
    'a response lost after commit is recovered through its idempotency key',
    () async {
      final command = AttendanceCommand.factoryCheckIn();
      backend.loseNextResponse = true;
      await expectLater(
        repository.submit(command),
        throwsA(_failure(AttendanceFailureKind.network)),
      );
      final recovered = await repository.findCommand(command);
      expect(recovered!.id, 'session-1');
      expect(backend.payloads.length, 1);
      expect(
        backend.requests.last.url.queryParameters['check_in_idempotency_key'],
        'eq.${command.key}',
      );
    },
  );

  test(
    'reconciliation rejects a reused key with a different original payload',
    () async {
      final original = AttendanceCommand.factoryCheckIn(
        key: 'fictional-same-key',
        observedAt: DateTime.utc(2026, 10, 15),
      );
      await repository.submit(original);
      final changed = AttendanceCommand.factoryCheckIn(
        key: original.key,
        observedAt: DateTime.utc(2026, 10, 16),
      );
      await expectLater(
        repository.findCommand(changed),
        throwsA(_failure(AttendanceFailureKind.idempotencyConflict)),
      );
      await expectLater(
        repository.submit(changed),
        throwsA(_failure(AttendanceFailureKind.idempotencyConflict)),
      );
    },
  );

  for (final entry in {
    'employee_role_required': AttendanceFailureKind.unauthorized,
    'authentication_required': AttendanceFailureKind.sessionExpired,
    'active_session_exists': AttendanceFailureKind.duplicateActive,
    'idempotency_key_conflict': AttendanceFailureKind.idempotencyConflict,
    'session_not_active': AttendanceFailureKind.sessionNotActive,
    'private unexpected database error': AttendanceFailureKind.backend,
  }.entries) {
    test('RPC error ${entry.key} maps to a safe French failure', () async {
      backend.rpcError = entry.key;
      await expectLater(
        repository.submit(AttendanceCommand.factoryCheckIn()),
        throwsA(_failure(entry.value)),
      );
      expect(
        AttendanceFailure(entry.value).message,
        isNot(contains(entry.key)),
      );
    });
  }

  test(
    'query permission failure is a retryable backend problem, preserving auth',
    () async {
      backend.queryError = '42501';
      await expectLater(
        repository.activeSession(),
        throwsA(_failure(AttendanceFailureKind.backend)),
      );
      expect(client.auth.currentSession, isNotNull);
    },
  );

  test(
    'expired PostgREST session is distinguished from query permission failure',
    () async {
      backend.queryError = 'PGRST301';
      await expectLater(
        repository.activeSession(),
        throwsA(_failure(AttendanceFailureKind.sessionExpired)),
      );
    },
  );

  test(
    'administrator without employee role makes no attendance requests',
    () async {
      const administrator = AuthorizedUser(
        profileId: 'admin',
        companyId: 'company',
        displayName: 'Admin',
        email: '',
        roles: {AuthorizedRole.administrator},
      );
      final denied = SupabaseAttendanceRepository(client, administrator);
      await expectLater(
        denied.activeSession(),
        throwsA(_failure(AttendanceFailureKind.unauthorized)),
      );
      await expectLater(
        denied.submit(AttendanceCommand.factoryCheckIn()),
        throwsA(_failure(AttendanceFailureKind.unauthorized)),
      );
      expect(backend.requests, isEmpty);
    },
  );

  test('an account switch cannot execute a controller bound to the previous session', () async {
    await client.auth.signOut();
    backend.requests.clear();
    await expectLater(
      repository.submit(AttendanceCommand.factoryCheckIn()),
      throwsA(_failure(AttendanceFailureKind.sessionExpired)),
    );
    expect(backend.requests, isEmpty);
  });

  test('malformed RPC acknowledgement is never a successful session', () async {
    backend.malformed = true;
    await expectLater(
      repository.submit(AttendanceCommand.factoryCheckIn()),
      throwsA(_failure(AttendanceFailureKind.backend)),
    );
  });
}

Matcher _failure(AttendanceFailureKind kind) =>
    isA<AttendanceFailure>().having((failure) => failure.kind, 'kind', kind);

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

class _Backend {
  final requests = <http.Request>[];
  final payloads = <Map<String, dynamic>>[];
  final acknowledgements = <Map<String, dynamic>>[];
  final rows = <Map<String, dynamic>>[];
  final intents = <String, String>{};
  String? rpcError;
  String? queryError;
  bool loseNextResponse = false;
  bool malformed = false;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.url.path.endsWith('/logout')) return _json({});
    if (request.url.path.contains('/rpc/')) {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      payloads.add(payload);
      if (rpcError != null) {
        return _json({'code': '42501', 'message': rpcError}, 400);
      }
      final key = payload['p_idempotency_key'] as String;
      if (intents.containsKey(key) && intents[key] != jsonEncode(payload)) {
        return _json({
          'code': '23505',
          'message': 'idempotency_key_conflict',
        }, 409);
      }
      final checkIn = request.url.path.endsWith('/check_in');
      final replay = intents.containsKey(key);
      Map<String, dynamic> row;
      if (replay) {
        row = rows.singleWhere(
          (row) =>
              row[checkIn
                  ? 'check_in_idempotency_key'
                  : 'check_out_idempotency_key'] ==
              key,
        );
      } else if (checkIn) {
        row = {
          'id': 'session-1',
          'location_context': 'factory',
          'lifecycle_status': 'active',
          'started_at': '2026-10-15T14:00:00+00:00',
          'ended_at': null,
          'site_description': null,
          'check_in_idempotency_key': key,
          'check_in_device_observed_at': payload['p_device_observed_at'],
        };
        rows.add(row);
      } else {
        row = rows.singleWhere(
          (row) => row['id'] == payload['p_work_session_id'],
        );
        row.addAll({
          'lifecycle_status': 'closed_manual',
          'ended_at': '2026-10-15T22:00:00+00:00',
          'check_out_idempotency_key': key,
          'check_out_device_observed_at': payload['p_device_observed_at'],
        });
      }
      intents[key] = jsonEncode(payload);
      if (loseNextResponse) {
        loseNextResponse = false;
        throw http.ClientException('fictional lost acknowledgement');
      }
      // Match every successful/replay branch of the committed SQL functions.
      // SELECT-only columns (including id) must not mask RPC parsing failures.
      final acknowledgement = <String, dynamic>{
        'status': replay
            ? 'idempotent_replay'
            : checkIn
            ? 'created'
            : 'closed',
        'session_id': row['id'],
        'lifecycle_status': row['lifecycle_status'],
        'location_context': row['location_context'],
        'started_at': malformed ? null : row['started_at'],
        'ended_at': row['ended_at'],
      };
      acknowledgements.add(acknowledgement);
      return _json(acknowledgement);
    }
    if (request.url.path.endsWith('/work_sessions')) {
      if (queryError != null) {
        return _json({
          'code': queryError,
          'message': 'private database permission error',
        }, queryError == 'PGRST301' ? 401 : 403);
      }
      final query = request.url.queryParameters;
      return _json(
        rows.where((row) {
          for (final column in [
            'lifecycle_status',
            'check_in_idempotency_key',
            'check_out_idempotency_key',
          ]) {
            final filter = query[column];
            if (filter != null && 'eq.${row[column]}' != filter) {
              return false;
            }
          }
          return true;
        }).toList(),
      );
    }
    throw StateError('Unexpected mocked path');
  }
}
