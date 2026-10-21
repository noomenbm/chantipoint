import 'dart:async';

import 'package:chantipoint/src/attendance/history/session_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/session_history_fixture.dart';

void main() {
  late HistoryHttpFixture fixture;
  final window = HistoryWindow.sixMonths(historyNow);
  setUp(() async {
    fixture = HistoryHttpFixture();
    await fixture.login();
  });
  tearDown(() => fixture.client.dispose());
  final failure = throwsA(isA<HistoryFailure>());

  test(
    'bounded legacy query validates employee/role even for empty history',
    () async {
      final page = await fixture.repository().load(window);
      expect(page.sessions, isEmpty);
      expect(page.next, isNull);
      final request = fixture.requests.single;
      final q = request.url.queryParameters;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/user_profiles');
      expect(q['id'], 'eq.${historyEmployee.profileId}');
      expect(q['auth_user_id'], 'eq.$historyAuthId');
      expect(q['company_id'], 'eq.${historyEmployee.companyId}');
      expect(q['employee_role.role'], 'eq.employee');
      expect(q['employee_role.status'], 'eq.active');
      expect(q['sessions.company_id'], 'eq.${historyEmployee.companyId}');
      expect(
        q['sessions.employee_profile_id'],
        'eq.${historyEmployee.profileId}',
      );
      expect(q['sessions.limit'], '21');
      expect(q['employee_role.limit'], '2');
      expect(q['limit'], '2');
      expect(
        q['sessions.order'],
        'started_at.desc.nullslast,id.desc.nullslast',
      );
      expect(q['select'], isNot(contains('employee_note')));
      expect(q['select'], isNot(contains('review_status')));
      expect(q.keys, isNot(contains('sessions.lifecycle_status')));
      expect(request.url.queryParametersAll['sessions.started_at'], [
        'gte.${window.fromUtc.toIso8601String()}',
        'lt.${window.untilUtc.toIso8601String()}',
      ]);
    },
  );

  test(
    'three keyset pages retain all tied microsecond timestamps exactly once',
    () async {
      fixture.rows.addAll(List.generate(41, (index) => historyRow(index + 1)));
      final repository = fixture.repository();
      final first = await repository.load(window);
      final second = await repository.load(window, before: first.next);
      final third = await repository.load(window, before: second.next);
      final all = [...first.sessions, ...second.sessions, ...third.sessions];
      expect(
        [first.sessions.length, second.sessions.length, third.sessions.length],
        [20, 20, 1],
      );
      expect(all.map((s) => s.id), List.generate(41, (i) => historyId(41 - i)));
      expect(third.next, isNull);
      expect(
        fixture.requests[1].url.queryParameters['sessions.or'],
        contains('2026-10-15T14:00:00.123456Z'),
      );
      expect(
        fixture.requests[1].url.queryParameters['sessions.or'],
        contains('id.lt.${first.sessions.last.id}'),
      );
    },
  );

  test(
    'query includes exact lower boundary and excludes upper and older sessions',
    () async {
      for (final (index, time) in [
        (1, window.fromUtc),
        (2, window.fromUtc.subtract(const Duration(microseconds: 1))),
        (3, window.untilUtc),
        (4, window.untilUtc.subtract(const Duration(microseconds: 1))),
      ]) {
        fixture.rows.add({
          ...historyRow(index, start: time.toIso8601String()),
          'ended_at': null,
          'lifecycle_status': 'active',
        });
      }
      final page = await fixture.repository().load(window);
      expect(page.sessions.map((s) => s.id), [historyId(4), historyId(1)]);
    },
  );

  for (final caps in [
    const HistoryCapabilities(notes: true),
    const HistoryCapabilities(review: true),
    const HistoryCapabilities(notes: true, review: true),
  ]) {
    test(
      'approved capability notes=${caps.notes} review=${caps.review} selects canonical fields',
      () async {
        final row = {
          ...historyRow(1),
          if (caps.notes) 'employee_note': '  Réparation é  ',
          if (caps.review) 'review_status': 'anomaly_open',
        };
        fixture.handler = (_) async => HistoryHttpFixture.json([
          historyProfile([row]),
        ]);
        final page = await fixture.repository(capabilities: caps).load(window);
        expect(
          page.sessions.single.employeeNote,
          caps.notes ? '  Réparation é  ' : null,
        );
        expect(
          page.sessions.single.reviewStatus,
          caps.review ? 'anomaly_open' : null,
        );
        expect(
          fixture.requests.single.url.queryParameters['select']!.contains(
            'employee_note',
          ),
          caps.notes,
        );
        expect(
          fixture.requests.single.url.queryParameters['select']!.contains(
            'review_status',
          ),
          caps.review,
        );
      },
    );
  }
  test('null canonical note remains null; not a manufactured note', () async {
    fixture.handler = (_) async => HistoryHttpFixture.json([
      historyProfile([
        {...historyRow(1), 'employee_note': null},
      ]),
    ]);
    final page = await fixture
        .repository(capabilities: const HistoryCapabilities(notes: true))
        .load(window);
    expect(page.sessions.single.employeeNote, isNull);
  });
  for (final code in ['42703', '42501', 'PGRST200', 'PGRST301']) {
    test(
      'schema/authorization error $code never becomes empty or retries weaker columns',
      () async {
        fixture.handler = (_) async => HistoryHttpFixture.json({
          'code': code,
          'message': 'private fictional message',
        }, 400);
        await expectLater(
          fixture
              .repository(
                capabilities: const HistoryCapabilities(
                  notes: true,
                  review: true,
                ),
              )
              .load(window),
          failure,
        );
        expect(fixture.requests.length, 1);
      },
    );
  }
  for (final problem in [
    'hidden profile',
    'revoked role',
    'disabled profile',
    'wrong auth',
    'wrong company',
    'wrong profile',
    'wrong role owner',
  ]) {
    test('fails closed on $problem instead of claiming empty', () async {
      final root = historyProfile([]);
      switch (problem) {
        case 'revoked role':
          root['employee_role'] = [];
        case 'disabled profile':
          root['status'] = 'disabled';
        case 'wrong auth':
          root['auth_user_id'] = historyId(99);
        case 'wrong company':
          root['company_id'] = historyId(99);
        case 'wrong profile':
          root['id'] = historyId(99);
        case 'wrong role owner':
          (root['employee_role'] as List).single['user_profile_id'] = historyId(
            99,
          );
      }
      fixture.handler = (_) async =>
          HistoryHttpFixture.json(problem == 'hidden profile' ? [] : [root]);
      await expectLater(fixture.repository().load(window), failure);
    });
  }
  for (final problem in [
    'owner',
    'company',
    'order',
    'duplicate',
    'too many',
    'old',
    'invalid date',
    'missing description',
    'unapproved note',
    'missing approved note',
    'missing approved review',
  ]) {
    test('rejects mismatched/malformed page: $problem', () async {
      var rows = [historyRow(2), historyRow(1)];
      switch (problem) {
        case 'owner':
          rows.first['employee_profile_id'] = historyId(99);
        case 'company':
          rows.first['company_id'] = historyId(99);
        case 'order':
          rows = rows.reversed.toList();
        case 'duplicate':
          rows = [historyRow(1), historyRow(1)];
        case 'too many':
          rows = List.generate(22, (i) => historyRow(30 - i));
        case 'old':
          rows.first['started_at'] = '2020-01-01T00:00:00Z';
        case 'invalid date':
          rows.first['started_at'] = '2026-09-31T00:00:00Z';
        case 'missing description':
          rows.first.remove('site_description');
        case 'unapproved note':
          rows.first['employee_note'] = 'Unrequested';
      }
      fixture.handler = (_) async =>
          HistoryHttpFixture.json([historyProfile(rows)]);
      final caps = HistoryCapabilities(
        notes: problem == 'missing approved note',
        review: problem == 'missing approved review',
      );
      await expectLater(
        fixture.repository(capabilities: caps).load(window),
        failure,
      );
    });
  }
  test('network and malformed JSON remain safe errors', () async {
    fixture.handler = (_) async =>
        throw http.ClientException('private fixture detail');
    await expectLater(fixture.repository().load(window), failure);
    fixture.handler = (_) async => http.Response('[{"truncated":', 200);
    await expectLater(fixture.repository().load(window), failure);
    expect(const HistoryFailure().toString(), isNot(contains('private')));
  });
  test('invalid cursor cannot inject filters or initiate a request', () async {
    await expectLater(
      fixture.repository().load(
        window,
        before: HistoryCursor(historyNow, 'x),id.gt.0'),
      ),
      failure,
    );
    expect(fixture.requests, isEmpty);
  });
  test('logout during delayed response suppresses its page', () async {
    final reply = Completer<http.Response>();
    final started = Completer<void>();
    fixture.handler = (_) {
      started.complete();
      return reply.future;
    };
    final pending = fixture.repository().load(window);
    await started.future;
    fixture.current = false;
    reply.complete(
      HistoryHttpFixture.json([
        historyProfile([historyRow(1)]),
      ]),
    );
    await expectLater(pending, failure);
  });
  for (final sameUser in [true, false]) {
    test(
      'delayed response is suppressed after ${sameUser ? 'same-user' : 'different-user'} session replacement',
      () async {
        final repository = fixture.repository();
        final started = Completer<void>();
        final reply = Completer<http.Response>();
        fixture.handler = (_) {
          started.complete();
          return reply.future;
        };
        final pending = repository.load(window);
        await started.future;
        await fixture.login(
          authId: sameUser ? historyAuthId : historyId(99),
          generation: 2,
        );
        reply.complete(
          HistoryHttpFixture.json([
            historyProfile([historyRow(1)]),
          ]),
        );
        await expectLater(pending, failure);
      },
    );
    test(
      'rejects ${sameUser ? 'same-user relogin' : 'account switch'} before or after request',
      () async {
        final repository = fixture.repository();
        await fixture.login(
          authId: sameUser ? historyAuthId : historyId(99),
          generation: 2,
        );
        await expectLater(repository.load(window), failure);
        expect(fixture.requests, isEmpty);
      },
    );
  }
  test('token replacement within the same login can read history', () async {
    final repository = fixture.repository();
    await fixture.login(); // Same login session_id, new SDK Session instance.
    expect(repository.isCurrent, isTrue);
    expect((await repository.load(window)).sessions, isEmpty);
  });
}
