import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_auth_owner.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/supabase_auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;

import 'support/attendance_auth_backend.dart';
import 'support/fake_attendance_operation_ports.dart';
import 'support/journal_fixtures.dart';

void main() {
  late AttendanceAuthBackend b;
  setUp(() => b = AttendanceAuthBackend());
  tearDown(() => b.close());

  test('only a completed real profile/employee authorization issues a bound context/scope', () async {
    expect(
      b.owner.issueContext,
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
    await b.login();
    expect(
      b.controller.state.status,
      AuthStatus.authenticated,
      reason:
          '${b.controller.state.message}; profiles=${b.profileCalls}; refreshes=${b.refreshCalls}',
    );
    expect(b.repository.attendanceAuthorization, isNotNull);
    expect(
      b.repository.attendanceAuthorization!.session.sameSession(
        b.repository.currentCredentials,
      ),
      true,
    );
    final context = b.context();
    final scope = await b.owner.acquire(context.identity);
    expect(context.isCurrent, true);
    expect(scope.isCurrent, true);
    expect(context.identity.binding.toJson(), journalBinding().toJson());
    expect(scope.identity.generation, context.identity.generation);
    expect(scope.accessToken, b.client.auth.currentSession!.accessToken);
    expect(scope.projectUrl.toString(), 'https://fixture.invalid');
    expect(b.owner.outstandingAttempts, 1);
    expect(b.profileCalls, 1);
  });
  test('owner may attach after successful authorization without recreating the auth session', () async {
    await b.login();
    final other = AttendanceAuthOwner(
      auth: b.controller,
      repository: b.repository,
      deployment: b.deployment(),
    );
    final context = other.issueContext();
    expect(context.isCurrent, true);
    expect(b.owner.isCurrent(context.identity), false);
    await context.release();
    await other.close();
  });
  test('logout invalidates synchronously before queued SDK logout or signed-out event', () async {
    await b.login();
    final context = b.context();
    final generation = context.identity.generation;
    final logout = b.controller.signOut();
    expect(b.controller.state.status, AuthStatus.signingOut);
    expect(b.client.auth.currentSession, isNotNull);
    expect(b.logoutCalls, 0);
    expect(context.isCurrent, false);
    expect(b.owner.generation, isNot(generation));
    expect(b.owner.outstandingAttempts, 1);
    await expectLater(
      b.owner.acquire(context.identity),
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
    await logout;
    expect(b.owner.outstandingAttempts, 1);
    await context.release();
    expect(b.owner.outstandingAttempts, 0);
  });
  test(
    'repository-direct logout initiation also invalidates before SDK execution',
    () async {
      await b.login();
      final context = b.context();
      final logout = b.repository.signOut();
      expect(b.client.auth.currentSession, isNotNull);
      expect(context.isCurrent, false);
      await logout;
    },
  );
  test('logout during real SDK credential refresh waits for settlement but issues no scope', () async {
    await b.login();
    final context = b.context();
    b.expire();
    b.refreshResponse = Completer<http.Response>();
    var settled = false;
    final acquisition = b.owner
        .acquire(context.identity)
        .whenComplete(() => settled = true);
    final expected = expectLater(
      acquisition,
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
    await b.refreshStarted.future;
    final logout = b.controller.signOut();
    expect(context.isCurrent, false);
    await turn();
    expect(settled, false);
    b.refreshResponse!.complete(json(b.session()));
    await expected;
    await logout;
    expect(b.client.auth.currentSession, isNull);
  });
  test('adapter cannot send attendance when logout begins during credential acquisition', () async {
    await b.login();
    final context = b.context();
    b.expire();
    b.refreshResponse = Completer<http.Response>();
    var sends = 0;
    final httpClient = MockClient((_) async {
      sends++;
      return json(journalReceipt(journalCommand()));
    });
    addTearDown(httpClient.close);
    final adapter = SupabaseAttendanceOperationTransport(
      authority: b.owner,
      client: httpClient,
    );
    final expected = expectLater(
      adapter.dispatch(context.identity, journalCommand(), replayOnly: false),
      throwsA(isA<AttendanceHttpFailure>()),
    );
    await b.refreshStarted.future;
    final logout = b.controller.signOut();
    b.refreshResponse!.complete(json(b.session()));
    await expected;
    await logout;
    expect(sends, 0);
  });
  for (final different in [false, true]) {
    test(
      'controller relogin different=$different invalidates at initiation, not UUID comparison',
      () async {
        await b.login();
        final old = b.context();
        final scope = await b.owner.acquire(old.identity);
        if (different) b.account = journalOtherId;
        final login = b.login();
        expect(b.controller.state.status, AuthStatus.authenticating);
        expect(old.isCurrent, false);
        expect(scope.isCurrent, false);
        await login;
        final next = b.context();
        expect(next.identity.generation, isNot(old.identity.generation));
        expect(next.identity.binding.authUserId, b.account);
        expect(next.isCurrent, true);
        expect(old.isCurrent, false);
      },
    );
  }
  test('raw SDK same-user replacement is blocked before asynchronous signed-in delivery', () async {
    await b.login();
    final old = b.context();
    final original = b.client.auth.currentSession;
    var observed = false;
    final subscription = b.client.auth.onAuthStateChange.listen((event) {
      if (identical(event.session, original)) return; // SDK replays last event.
      observed = true;
      expect(old.isCurrent, false);
    });
    await b.client.auth.signInWithPassword(
      email: 'fictional@example.test',
      password: 'fictional',
    );
    await turn();
    expect(observed, true);
    expect(old.isCurrent, false);
    expect(b.context().isCurrent, true);
    await subscription.cancel();
  });
  test(
    'token refresh stays in one generation, old issued token is immutable',
    () async {
      await b.login();
      final context = b.context();
      final oldScope = await b.owner.acquire(context.identity);
      final generation = b.owner.generation;
      await b.client.auth.refreshSession();
      await turn();
      final newScope = await b.owner.acquire(context.identity);
      expect(b.owner.generation, generation);
      expect(context.isCurrent, true);
      expect(newScope.accessToken, isNot(oldScope.accessToken));
      expect(oldScope.isCurrent, true);
      expect(b.context().identity.generation, generation);
      expect(b.profileCalls, 1);
    },
  );
  test('on-demand refresh acquisition shares the generation without extra authorization queries', () async {
    await b.login();
    final context = b.context();
    final generation = b.owner.generation;
    b.expire();
    final scope = await b.owner.acquire(context.identity);
    expect(scope.isCurrent, true);
    expect(context.isCurrent, true);
    expect(b.owner.generation, generation);
    expect(b.refreshCalls, 1);
    expect(b.profileCalls, 1);
  });
  for (final reason in ['disabled', 'revoked', 'admin-only', 'offline']) {
    test(
      '$reason revalidation invalidates old contexts/scopes and cannot revive them',
      () async {
        await b.login();
        final old = b.context();
        final scope = await b.owner.acquire(old.identity);
        b.disabled = reason == 'disabled';
        b.roleRevoked = reason == 'revoked';
        b.administratorOnly = reason == 'admin-only';
        b.offlineProfile = reason == 'offline';
        final validation = b.controller.revalidateOnResume();
        expect(old.isCurrent, false);
        expect(scope.isCurrent, false);
        await validation;
        expect(
          b.owner.issueContext,
          throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
        );
        b.disabled = b.roleRevoked = b.administratorOnly = b.offlineProfile =
            false;
        await b.login();
        expect(b.context().isCurrent, true);
        expect(old.isCurrent, false);
      },
    );
  }
  test('successful resume validation grants a fresh epoch; old results remain invalid', () async {
    await b.login();
    final old = b.context();
    await b.controller.revalidateOnResume();
    expect(b.context().identity.generation, isNot(old.identity.generation));
    expect(old.isCurrent, false);
  });
  test(
    'release is idempotent and does not itself invalidate the auth observation',
    () async {
      await b.login();
      final context = b.context();
      await context.release();
      await context.release();
      expect(b.owner.outstandingAttempts, 0);
      expect(context.isCurrent, true);
      await b.controller.signOut();
      expect(context.isCurrent, false);
    },
  );
  test(
    'controller disposal invalidates authority without early context release',
    () async {
      await b.login();
      final context = b.context();
      b.controller.dispose();
      expect(context.isCurrent, false);
      expect(b.owner.outstandingAttempts, 1);
      await context.release();
      // Fixture close avoids a second ChangeNotifier dispose.
    },
  );
  test('application owner close waits for outstanding contexts, with no forced release', () async {
    await b.login();
    final context = b.context();
    var closed = false;
    final closing = b.owner.close().then((_) => closed = true);
    await turn();
    expect(context.isCurrent, false);
    expect(closed, false);
    expect(b.owner.outstandingAttempts, 1);
    await context.release();
    await closing;
    expect(closed, true);
  });
  test(
    'wrong complete binding/generation cannot acquire another owner scope',
    () async {
      await b.login();
      final context = b.context();
      for (final other in [
        journalBinding(environment: 'other'),
        journalBinding(url: 'https://other.invalid'),
        journalBinding(auth: journalOtherId),
        journalBinding(company: journalOtherId),
        journalBinding(profile: journalOtherId),
      ]) {
        await expectLater(
          b.owner.acquire(
            AttendanceOperationIdentity(other, context.identity.generation),
          ),
          throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
        );
      }
      await expectLater(
        b.owner.acquire(
          AttendanceOperationIdentity(
            context.identity.binding,
            context.identity.generation + 100,
          ),
        ),
        throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
      );
    },
  );
  test('mismatched controller/repository or trusted project cannot construct an owner', () async {
    final otherRepository = SupabaseAuthRepository(b.client);
    expect(
      () => AttendanceAuthOwner(
        auth: b.controller,
        repository: otherRepository,
        deployment: b.deployment(),
      ),
      throwsA(authFailure(AttendanceAuthFailureKind.configuration)),
    );
    expect(
      () => AttendanceAuthOwner(
        auth: b.controller,
        repository: b.repository,
        deployment: b.deployment(url: 'https://other.invalid'),
      ),
      throwsA(authFailure(AttendanceAuthFailureKind.configuration)),
    );
  });

  for (final action in ['logout', 'relogin', 'close']) {
    test(
      'real authority + HTTP + C3.1 late receipt after $action retains ownership until body settles',
      () async {
        await b.login();
        final context = b.context();
        final scope = await b.owner.acquire(context.identity);
        final h = FictionalAttendanceOperations();
        final entered = Completer<void>();
        final body = StreamController<List<int>>();
        final sent = <http.BaseRequest>[];
        final httpClient = MockClient.streaming((request, bytes) async {
          await bytes.drain<void>();
          sent.add(request);
          entered.complete();
          return http.StreamedResponse(body.stream, 200);
        });
        addTearDown(httpClient.close);
        final adapter = SupabaseAttendanceOperationTransport(
          authority: b.owner,
          client: httpClient,
        );
        final core = AttendanceOperationCoordinator(
          storage: h.storage,
          transport: adapter,
          canonical: adapter,
        );
        final command = journalCommand();
        final raw = ' \n${jsonEncode(journalReceipt(command))} ';
        final operation = core.submit(context, command);
        await entered.future;
        body.add(utf8.encode(raw.substring(0, 20)));
        Future<void>? closing;
        if (action == 'close') {
          closing = b.owner.close();
        } else if (action == 'relogin') {
          await b.login();
        } else {
          await b.controller.signOut();
        }
        expect(context.isCurrent, false);
        expect(scope.isCurrent, false);
        expect(b.owner.outstandingAttempts, 1);
        body.add(utf8.encode(raw.substring(20)));
        await body.close();
        final result = await operation;
        expect(result.outcome, AttendanceOperationOutcome.invalidated);
        expect(result.snapshot, isNull);
        expect(h.record!.confirmation!.dataJson, raw);
        expect(h.record!.command!.toJson(), command.toJson());
        expect(h.record!.phase, JournalPhase.confirmed);
        expect(sent.length, 1);
        expect(
          sent.single.headers['Authorization'],
          'Bearer ${scope.accessToken}',
        );
        expect(b.owner.outstandingAttempts, 0);
        await closing;
      },
    );
  }
  test('concurrent same-binding attempts remain held through caller timeout, no duplicate dispatch', () async {
    await b.login();
    final h = FictionalAttendanceOperations();
    final entered = Completer<void>();
    final body = StreamController<List<int>>();
    final calls = <String>[];
    final httpClient = MockClient.streaming((request, bytes) async {
      await bytes.drain<void>();
      calls.add(request.method);
      if (request.method == 'POST') {
        entered.complete();
        return http.StreamedResponse(body.stream, 200);
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode([
              {
                'id': journalSessionId,
                'employee_profile_id': journalBinding().profileId,
                'company_id': journalBinding().companyId,
                'location_context': 'factory',
                'lifecycle_status': 'active',
                'started_at': '2026-10-17T12:00:00Z',
                'ended_at': null,
                'site_description': null,
                'employee_note': null,
                'review_status': 'normal',
              },
            ]),
          ),
        ),
        200,
      );
    });
    addTearDown(httpClient.close);
    final adapter = SupabaseAttendanceOperationTransport(
      authority: b.owner,
      client: httpClient,
    );
    final core = AttendanceOperationCoordinator(
      storage: h.storage,
      transport: adapter,
      canonical: adapter,
    );
    final first = core.submit(b.context(), journalCommand());
    await entered.future;
    final second = core.submit(b.context(), journalCommand());
    await expectLater(
      first.timeout(Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    expect(b.owner.outstandingAttempts, 2);
    expect(calls, ['POST']);
    body.add(utf8.encode(jsonEncode(journalReceipt(journalCommand()))));
    await body.close();
    expect((await first).outcome, AttendanceOperationOutcome.confirmed);
    expect((await second).outcome, AttendanceOperationOutcome.confirmed);
    expect(calls, ['POST', 'GET', 'GET']);
    expect(b.owner.outstandingAttempts, 0);
  });
  test(
    'session replacement blocks immediately before public event delivery',
    () async {
      await b.login();
      final old = b.context();
      final replacement = b.client.auth.setInitialSession(
        jsonEncode(b.session(login: journalOtherId)),
      );
      // setInitialSession replaces synchronously; its public event is asynchronous.
      expect(old.isCurrent, false);
      expect(
        b.owner.issueContext,
        throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
      );
      await replacement;
      await turn();
      expect(
        b.owner.issueContext,
        throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
      );
      await b.controller.revalidateOnResume();
      expect(b.context().isCurrent, true);
      expect(old.isCurrent, false);
    },
  );
  test('setSession emits tokenRefreshed for another same-user login, which must not inherit authority', () async {
    await b.login();
    final old = b.context();
    final originalGeneration = b.owner.generation;
    b.refreshResponse = Completer<http.Response>();
    final replacement = b.client.auth.setSession(
      'fictional-other-login-refresh',
    );
    await b.refreshStarted.future;
    b.refreshResponse!.complete(json(b.session(login: journalOtherId)));
    await replacement;
    await turn();
    expect(b.controller.state.status, AuthStatus.authenticated);
    expect(old.isCurrent, false);
    expect(b.owner.generation, isNot(originalGeneration));
    expect(
      b.owner.issueContext,
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
    await b.controller.revalidateOnResume();
    expect(b.context().isCurrent, true);
  });
  test('refresh observation gap blocks issuance without rotating an authorized login epoch', () async {
    await b.login();
    late AttendanceAuthOwner other;
    var armed = false;
    var observed = false;
    int? generation;
    final subscription = b.client.auth.onAuthStateChange.listen((event) {
      if (!armed || event.event != AuthChangeEvent.tokenRefreshed) return;
      observed = true;
      expect(
        other.issueContext,
        throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
      );
      expect(other.generation, generation);
    });
    other = AttendanceAuthOwner(
      auth: b.controller,
      repository: b.repository,
      deployment: b.deployment(),
    );
    await turn(); // Settle the SDK's replayed existing event before this attempt.
    final context = other.issueContext();
    generation = other.generation;
    armed = true;
    try {
      await b.client.auth.refreshSession();
      await turn();
      expect(observed, true);
      expect(context.isCurrent, true);
      expect(other.generation, generation);
    } finally {
      await subscription.cancel();
      await context.release();
      await other.close();
    }
  });
  test('concurrent credential acquisitions share SDK refresh and preserve exact generation', () async {
    await b.login();
    final first = b.context();
    final second = b.context();
    b.expire();
    b.refreshResponse = Completer<http.Response>();
    final acquisitions = [
      b.owner.acquire(first.identity),
      b.owner.acquire(second.identity),
    ];
    await b.refreshStarted.future;
    expect(b.refreshCalls, 1);
    b.refreshResponse!.complete(json(b.session()));
    final scopes = await Future.wait(acquisitions);
    expect(scopes.every((scope) => scope.isCurrent), true);
    expect(scopes[0].accessToken, scopes[1].accessToken);
    expect(b.owner.generation, first.identity.generation);
    expect(b.owner.outstandingAttempts, 2);
  });
  test('late refresh result after different-user login cannot retarget credential acquisition', () async {
    await b.login();
    final old = b.context();
    final oldReply = json(b.session());
    b.expire();
    b.refreshResponse = Completer<http.Response>();
    final expected = expectLater(
      b.owner.acquire(old.identity),
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
    await b.refreshStarted.future;
    b.account = journalOtherId;
    await b.login();
    b.refreshResponse!.complete(oldReply);
    await expected;
    final fresh = b.context();
    expect(
      (await b.owner.acquire(fresh.identity)).identity.binding.authUserId,
      journalOtherId,
    );
    expect(old.isCurrent, false);
  });
  test('ambiguous replacement during profile lookup withholds attendance evidence without changing auth outcome', () async {
    b.profileResponse = Completer<http.Response>();
    final login = b.login();
    await b.profileStarted.future;
    await b.client.auth.setInitialSession(
      jsonEncode(b.session(login: journalOtherId)),
    );
    b.profileResponse!.complete(
      json([
        {
          'id': journalBinding().profileId,
          'company_id': journalBinding().companyId,
          'display_name': 'Fictional employee',
          'email': 'fictional@example.test',
          'status': 'active',
        },
      ]),
    );
    await login;
    expect(b.controller.state.status, AuthStatus.authenticated);
    expect(b.repository.attendanceAuthorization, isNull);
    expect(
      b.owner.issueContext,
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
    b.profileResponse = null;
    await b.controller.revalidateOnResume();
    expect(b.context().isCurrent, true);
  });
  test('failed refresh exposes only safe failure and never releases a context early', () async {
    await b.login();
    final context = b.context();
    b.expire();
    b.refreshResponse = Completer<http.Response>();
    final expected = expectLater(
      b.owner.acquire(context.identity),
      throwsA(authFailure(AttendanceAuthFailureKind.credentialsUnavailable)),
    );
    await b.refreshStarted.future;
    b.refreshResponse!.complete(
      json({
        'code': 'refresh_token_not_found',
        'msg': 'private fictional error',
      }, 400),
    );
    await expected;
    await turn();
    expect(context.isCurrent, false);
    expect(b.owner.outstandingAttempts, 1);
  });
  test('logout backend failure cannot restore attendance authority', () async {
    await b.login();
    final old = b.context();
    b.logoutFails = true;
    await b.controller.signOut();
    expect(old.isCurrent, false);
    expect(b.owner.outstandingAttempts, 1);
    expect(
      b.owner.issueContext,
      throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
    );
  });
  test('malformed trusted deployment fails with safe codes only', () {
    for (final url in [
      'https://fixture.invalid/rest/v1',
      'https://fixture.invalid/',
      'https://user:private@fixture.invalid',
      'http://fixture.invalid',
      'https://fixture.invalid?private=value',
    ]) {
      expect(
        () => b.deployment(url: url),
        throwsA(authFailure(AttendanceAuthFailureKind.configuration)),
      );
    }
    expect(
      () => AttendanceTrustedDeployment(
        environmentId: '',
        projectUrl: Uri.parse('https://fixture.invalid'),
        publishableKey: 'fictional',
      ),
      throwsA(authFailure(AttendanceAuthFailureKind.configuration)),
    );
  });
  for (final missing in ['session_id', 'exp', 'sub', 'invalid-session']) {
    test(
      '$missing cannot establish a usable attendance credential scope',
      () async {
        final session = b.session();
        final parts = (session['access_token'] as String).split('.');
        final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        ) as Map<String, dynamic>;
        if (missing == 'invalid-session') {
          claims['session_id'] = 'not-a-server-login-marker';
        } else {
          claims.remove(missing);
        }
        parts[1] = base64Url
            .encode(utf8.encode(jsonEncode(claims)))
            .replaceAll('=', '');
        session['access_token'] = parts.join('.');
        b.passwordResponse = Completer<http.Response>()
          ..complete(json(session));
        await b.login();
        expect(b.controller.state.status, AuthStatus.authenticated);
        if (missing == 'exp') {
          final context = b.context();
          await expectLater(
            b.owner.acquire(context.identity),
            throwsA(
              authFailure(AttendanceAuthFailureKind.credentialsUnavailable),
            ),
          );
        } else {
          expect(
            b.owner.issueContext,
            throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
          );
        }
      },
    );
  }
  test('late attachment after refresh requires fresh authorization rather than UUID continuity', () async {
    await b.login();
    await b.client.auth.refreshSession();
    await turn();
    final other = AttendanceAuthOwner(
      auth: b.controller,
      repository: b.repository,
      deployment: b.deployment(),
    );
    try {
      await turn();
      expect(
        other.issueContext,
        throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
      );
      await b.controller.revalidateOnResume();
      final context = other.issueContext();
      expect(context.isCurrent, true);
      await context.release();
    } finally {
      await other.close();
    }
  });
  test('superseded refresh event cannot rotate an epoch or adopt an unobserved replacement', () async {
    await b.login();
    late AttendanceAuthOwner other;
    var armed = false;
    Future<dynamic>? recovery;
    final subscription = b.client.auth.onAuthStateChange.listen((event) {
      if (armed && event.event == AuthChangeEvent.tokenRefreshed) {
        // Public recoverSession silently replaces an unexpired same-user SDK
        // session. Do this before the later owner's queued event is delivered.
        recovery = b.client.auth.recoverSession(jsonEncode(b.session()));
      }
    });
    other = AttendanceAuthOwner(
      auth: b.controller,
      repository: b.repository,
      deployment: b.deployment(),
    );
    await turn();
    final context = other.issueContext();
    final generation = other.generation;
    armed = true;
    try {
      await b.client.auth.refreshSession();
      await recovery;
      await turn();
      expect(other.generation, generation);
      expect(context.isCurrent, false);
      expect(
        other.issueContext,
        throwsA(authFailure(AttendanceAuthFailureKind.contextInvalidated)),
      );
      await b.controller.revalidateOnResume();
      final fresh = other.issueContext();
      expect(fresh.isCurrent, true);
      expect(context.isCurrent, false);
      await fresh.release();
    } finally {
      await subscription.cancel();
      await context.release();
      await other.close();
    }
  });
}

Matcher authFailure(AttendanceAuthFailureKind kind) =>
    isA<AttendanceAuthFailure>()
        .having((e) => e.kind, 'kind', kind)
        .having(
          (e) => e.toString(),
          'safe text',
          'AttendanceAuthFailure(${kind.name})',
        );
