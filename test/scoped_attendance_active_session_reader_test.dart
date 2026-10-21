import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/scoped_attendance_active_session_reader.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/active_session_read_fixtures.dart';
import 'support/fake_attendance_operation_ports.dart';
import 'support/fake_attendance_request_authority.dart';
import 'support/journal_fixtures.dart';

Matcher failure([AttendanceHttpFailureKind? kind]) =>
    isA<AttendanceHttpFailure>().having(
      (e) => e.kind,
      'safe kind',
      kind ?? isNotNull,
    );

void main() {
  late FictionalAttendanceOperations h;
  late FictionalRequestAuthority authority;
  late AttendanceOperationIdentity identity;
  late MockClient client;
  late ScopedAttendanceActiveSessionReader reader;
  late Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  late List<http.BaseRequest> requests;

  http.StreamedResponse response(Object data, {int status = 200}) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(data))),
        status,
      );

  setUp(() {
    h = FictionalAttendanceOperations();
    identity = h.issuer.context().identity;
    authority = FictionalRequestAuthority(h.issuer);
    requests = [];
    handler = (_) async => response(activeSelection());
    client = MockClient.streaming((request, body) async {
      await body.drain<void>();
      requests.add(request);
      return handler(request);
    });
    reader = ScopedAttendanceActiveSessionReader(
      transport: SupabaseAttendanceOperationTransport(
        authority: authority,
        client: client,
      ),
    );
  });
  tearDown(() {
    reader.dispose();
    client.close();
  });

  test(
    'expired scope before sending never falls back to another credential',
    () async {
      authority.onAcquire = (_) async => authority.scope(current: () => false);
      await expectLater(reader.readActiveSession(identity), throwsA(failure()));
      expect(requests, isEmpty);
    },
  );
  test(
    'replaced captured generation is rejected before credential acquisition',
    () async {
      h.issuer.relogin();
      await expectLater(reader.readActiveSession(identity), throwsA(failure()));
      expect(requests, isEmpty);
      expect(authority.acquisitions, 0);
    },
  );
  test('failed fresh lookup retires previous checkout baseline without claiming no session', () async {
    await reader.readActiveSession(identity);
    handler = (_) async => throw http.ClientException('fictional failure');
    await expectLater(reader.readActiveSession(identity), throwsA(failure()));
    expect(reader.isSessionCurrent(identity, journalSessionId), false);
    expect(reader.revision, 0);
  });
  test('reader disposal does not detach submitted HTTP work or close borrowed authority', () async {
    final pending = Completer<http.StreamedResponse>();
    final entered = Completer<void>();
    handler = (_) {
      entered.complete();
      return pending.future;
    };
    var settled = false;
    final expected = expectLater(
      reader.readActiveSession(identity).whenComplete(() => settled = true),
      throwsA(failure()),
    );
    await entered.future;
    reader.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(settled, false);
    expect(authority.isCurrent(identity), true);
    pending.complete(response(activeSelection()));
    await expected;
    expect(reader.isSessionCurrent(identity, journalSessionId), false);
  });

  test('authorized active SELECT pins scope, projects owners/v2 fields and retains canonical values', () async {
    var notices = 0;
    reader.addListener(() => notices++);
    final result = await reader.readActiveSession(identity);
    expect(result!.id, journalSessionId);
    expect(result.employeeNote, 'Note canonique fictive');
    expect(result.locationContext, 'location_unverified');
    expect(result.reviewStatus, 'anomaly_open');
    expect(result.startedAt, DateTime.utc(2026, 10, 17, 14));
    expect(reader.isSessionCurrent(identity, result.id), true);
    expect(reader.revision, 0);
    expect(notices, 0);
    final request = requests.single;
    expect(request.method, 'GET');
    expect(request.url.origin, 'https://fixture.invalid');
    expect(request.url.path, '/rest/v1/user_profiles');
    final q = request.url.queryParameters;
    expect(q['id'], 'eq.${identity.binding.profileId}');
    expect(q['auth_user_id'], 'eq.${identity.binding.authUserId}');
    expect(q['company_id'], 'eq.${identity.binding.companyId}');
    expect(q['employee_role.role'], 'eq.employee');
    expect(q['employee_role.status'], 'eq.active');
    expect(
      q['employee_role.user_profile_id'],
      'eq.${identity.binding.profileId}',
    );
    expect(q['employee_role.company_id'], 'eq.${identity.binding.companyId}');
    expect(q['sessions.lifecycle_status'], 'eq.active');
    expect(q['sessions.company_id'], 'eq.${identity.binding.companyId}');
    expect(
      q['sessions.employee_profile_id'],
      'eq.${identity.binding.profileId}',
    );
    for (final key in ['limit', 'sessions.limit', 'employee_role.limit']) {
      expect(q[key], '2');
    }
    expect(
      q['select'],
      contains('work_sessions!work_sessions_employee_company_fk'),
    );
    expect(
      q['select'],
      contains('role_assignments!role_assignments_profile_company_fk'),
    );
    for (final field in [
      'employee_note',
      'review_status',
      'location_context',
      'company_id',
      'employee_profile_id',
    ]) {
      expect(q['select'], contains(field));
    }
    expect(request.headers['Authorization'], 'Bearer fictional-pinned-token');
    expect(request.headers['apikey'], 'fictional-publishable-key');
    expect(request.headers['Accept-Profile'], 'public');
    expect(request.followRedirects, false);
    expect(request.maxRedirects, 0);
  });

  test('only authorized profile/role with empty children returns null; reads never tick revision', () async {
    await reader.readActiveSession(identity);
    handler = (_) async => response(activeSelection(sessions: []));
    expect(await reader.readActiveSession(identity), isNull);
    expect(reader.isSessionCurrent(identity, journalSessionId), false);
    expect(reader.revision, 0);
    expect(requests.length, 2);
  });

  final corruptions = <String, void Function(Map<String, dynamic>)>{
    'wrong parent auth': (p) => p['auth_user_id'] = journalOtherId,
    'wrong parent company': (p) => p['company_id'] = journalOtherId,
    'wrong parent profile': (p) => p['id'] = journalOtherId,
    'disabled profile': (p) => p['status'] = 'disabled',
    'missing employee role': (p) => p['employee_role'] = [],
    'revoked role': (p) => p['employee_role'][0]['status'] = 'revoked',
    'administrator only': (p) =>
        p['employee_role'][0]['role'] = 'administrator',
    'wrong role company': (p) =>
        p['employee_role'][0]['company_id'] = journalOtherId,
    'wrong role owner': (p) =>
        p['employee_role'][0]['user_profile_id'] = journalOtherId,
    'multiple roles': (p) => p['employee_role'].add(
      Map<String, dynamic>.from(p['employee_role'][0]),
    ),
    'missing role shape': (p) => p['employee_role'][0].remove('status'),
    'wrong child company': (p) =>
        p['sessions'][0]['company_id'] = journalOtherId,
    'wrong child profile': (p) =>
        p['sessions'][0]['employee_profile_id'] = journalOtherId,
    'closed row': (p) {
      p['sessions'][0]['lifecycle_status'] = 'closed_manual';
      p['sessions'][0]['ended_at'] = '2026-10-17T18:00:00Z';
    },
    'active with end': (p) =>
        p['sessions'][0]['ended_at'] = '2026-10-17T18:00:00Z',
    'multiple active rows': (p) =>
        p['sessions'].add(Map<String, dynamic>.from(p['sessions'][0])),
    'missing v2 note': (p) => p['sessions'][0].remove('employee_note'),
    'missing v2 review': (p) => p['sessions'][0].remove('review_status'),
    'null review': (p) => p['sessions'][0]['review_status'] = null,
    'wrong classification': (p) =>
        p['sessions'][0]['location_context'] = 'fictional_invalid',
    'overflow timestamp': (p) =>
        p['sessions'][0]['started_at'] = '2026-02-31T10:00:00Z',
    'invalid session id': (p) => p['sessions'][0]['id'] = 'not-an-id',
    'invalid note': (p) => p['sessions'][0]['employee_note'] = 42,
    'absent child selection': (p) => p.remove('sessions'),
  };
  for (final entry in corruptions.entries) {
    test(
      '${entry.key} fails rather than returning an empty or wrong-owner session',
      () async {
        final rows = activeSelection();
        entry.value(rows.single);
        handler = (_) async => response(rows);
        await expectLater(
          reader.readActiveSession(identity),
          throwsA(failure()),
        );
        expect(reader.isSessionCurrent(identity, journalSessionId), false);
      },
    );
  }
  for (final shape in [
    [],
    [null],
    {},
    [activeSelection().single, activeSelection().single],
  ]) {
    test(
      'invalid/hidden parent shape ${shape.runtimeType} (${shape is List ? shape.length : -1}) is not no-active',
      () async {
        handler = (_) async => response(shape);
        await expectLater(
          reader.readActiveSession(identity),
          throwsA(failure()),
        );
      },
    );
  }
  for (final status in [302, 401, 403, 404, 503]) {
    test(
      'HTTP $status including denied/schema errors is a safe failure with one attempt',
      () async {
        handler = (_) async => response({
          'message': 'fictional private backend detail',
        }, status: status);
        try {
          await reader.readActiveSession(identity);
          fail('Expected read failure');
        } on AttendanceHttpFailure catch (e) {
          expect(e.kind, AttendanceHttpFailureKind.http);
          expect(e.toString(), isNot(contains('private')));
        }
        expect(requests.length, 1);
      },
    );
  }
  for (final error in [
    http.ClientException('fictional private network'),
    TimeoutException('fictional private timeout'),
  ]) {
    test('${error.runtimeType} cannot become an empty SELECT', () async {
      handler = (_) async => throw error;
      await expectLater(
        reader.readActiveSession(identity),
        throwsA(failure(AttendanceHttpFailureKind.network)),
      );
      expect(requests.length, 1);
    });
  }
  for (final text in [
    '[',
    '[{"id":1,"id":2}]',
    'null',
    'x' * (SupabaseAttendanceOperationTransport.responseLimit + 1),
  ]) {
    test(
      'malformed/oversized body length ${text.length} never returns null',
      () async {
        handler = (_) async =>
            http.StreamedResponse(Stream.value(utf8.encode(text)), 200);
        await expectLater(
          reader.readActiveSession(identity),
          throwsA(failure()),
        );
      },
    );
  }
  test('stream failure settles as failure after all body work', () async {
    final body = StreamController<List<int>>();
    handler = (_) async => http.StreamedResponse(body.stream, 200);
    var settled = false;
    final pending = reader
        .readActiveSession(identity)
        .whenComplete(() => settled = true);
    final expected = expectLater(
      pending,
      throwsA(failure(AttendanceHttpFailureKind.network)),
    );
    await Future<void>.delayed(Duration.zero);
    body.addError(StateError('fictional private stream'));
    await Future<void>.delayed(Duration.zero);
    expect(settled, false);
    await body.close();
    await expected;
  });

  test('invalidation during authority acquisition prevents dispatch', () async {
    final scope = authority.scope();
    final gate = Completer<void>();
    authority.onAcquire = (_) async {
      await gate.future;
      return scope;
    };
    final expected = expectLater(
      reader.readActiveSession(identity),
      throwsA(failure()),
    );
    authority.authorized = false;
    gate.complete();
    await expected;
    expect(requests, isEmpty);
  });
  for (final binding in [
    journalBinding(environment: 'other'),
    journalBinding(url: 'https://other.invalid'),
    journalBinding(auth: journalOtherId),
    journalBinding(company: journalOtherId),
    journalBinding(profile: journalOtherId),
  ]) {
    test(
      'complete captured binding mismatch ${binding.toJson().entries.where((e) => e.value != journalBinding().toJson()[e.key]).single.key} rejects before HTTP',
      () async {
        final wrong = AttendanceOperationIdentity(binding, identity.generation);
        await expectLater(reader.readActiveSession(wrong), throwsA(failure()));
        expect(requests, isEmpty);
      },
    );
  }
  test(
    'scope returned for a different epoch is rejected without HTTP',
    () async {
      authority.onAcquire = (_) async => authority.scope(
        asIdentity: AttendanceOperationIdentity(
          identity.binding,
          identity.generation + 1,
        ),
      );
      await expectLater(reader.readActiveSession(identity), throwsA(failure()));
      expect(requests, isEmpty);
    },
  );
  for (final empty in [false, true]) {
    test(
      'logout/expiry after response headers rejects delayed ${empty ? 'empty' : 'active'} body',
      () async {
        final body = StreamController<List<int>>();
        final entered = Completer<void>();
        var usable = true;
        authority.onAcquire = (_) async =>
            authority.scope(current: () => usable);
        handler = (_) async {
          entered.complete();
          return http.StreamedResponse(body.stream, 200);
        };
        final expected = expectLater(
          reader.readActiveSession(identity),
          throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
        );
        await entered.future;
        usable = false;
        body.add(
          utf8.encode(jsonEncode(activeSelection(sessions: empty ? [] : null))),
        );
        await body.close();
        await expected;
        expect(reader.isSessionCurrent(identity, journalSessionId), false);
      },
    );
  }

  test('known change invalidates original checkout and delayed read cannot erase newer selection', () async {
    var notices = 0;
    void changed() {
      notices++;
    }

    reader.addListener(changed);
    await reader.readActiveSession(identity);
    final late = Completer<http.StreamedResponse>();
    final entered = Completer<void>();
    handler = (_) {
      entered.complete();
      return late.future;
    };
    final expected = expectLater(
      reader.readActiveSession(identity),
      throwsA(failure(AttendanceHttpFailureKind.staleObservation)),
    );
    await entered.future;
    reader.invalidateSession(identity);
    expect(reader.isSessionCurrent(identity, journalSessionId), false);
    expect(reader.revision, 1);
    expect(notices, 1);
    handler = (_) async => response(
      activeSelection(sessions: [activeSessionRow(id: journalOtherId)]),
    );
    await reader.readActiveSession(identity);
    late.complete(response(activeSelection()));
    await expected;
    expect(reader.isSessionCurrent(identity, journalOtherId), true);
    expect(reader.revision, 1);
    expect(notices, 1);
    reader.removeListener(changed);
    reader.invalidateSession(identity);
    expect(reader.revision, 2);
    expect(notices, 1);
  });
  test(
    'newer read wins without impersonating an independently known revision',
    () async {
      final old = Completer<http.StreamedResponse>();
      final entered = Completer<void>();
      handler = (_) {
        entered.complete();
        return old.future;
      };
      final expected = expectLater(
        reader.readActiveSession(identity),
        throwsA(failure(AttendanceHttpFailureKind.staleObservation)),
      );
      await entered.future;
      handler = (_) async => response(
        activeSelection(sessions: [activeSessionRow(id: journalOtherId)]),
      );
      await reader.readActiveSession(identity);
      old.complete(response(activeSelection()));
      await expected;
      expect(reader.isSessionCurrent(identity, journalOtherId), true);
      expect(reader.revision, 0);
    },
  );
  test('reader lifetime and wrong-generation changes cannot revive cached observations', () async {
    await reader.readActiveSession(identity);
    h.issuer.relogin();
    expect(reader.isSessionCurrent(identity, journalSessionId), false);
    expect(() => reader.invalidateSession(identity), throwsA(failure()));
    expect(reader.revision, 0);
    reader.dispose();
    await expectLater(
      reader.readActiveSession(h.issuer.context().identity),
      throwsA(failure()),
    );
    expect(requests.length, 1);
  });
}
