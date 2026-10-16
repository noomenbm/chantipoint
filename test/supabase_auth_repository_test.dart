import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/auth_failure.dart';
import 'package:chantipoint/src/auth/auth_repository.dart';
import 'package:chantipoint/src/auth/supabase_auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('temporary refresh failure preserves a stored session', () async {
    final backend = _Backend()..authError = 'unexpected_failure';
    final repository = _repository(backend);
    await backend.client.auth.setInitialSession(
      jsonEncode(backend.expiredSession),
    );
    await expectLater(
      repository.restoreSession(),
      throwsA(_failure(AuthFailureKind.serviceUnavailable)),
    );
    expect(repository.hasSession, isTrue);
    expect(backend.logoutCalls, 0);
    expect(backend.profileCalls, 0);
  });

  test(
    'password login validates profile and roles with one lookup each',
    () async {
      final backend = _Backend();
      final repository = _repository(backend);
      final controller = AuthController(repository);
      addTearDown(controller.dispose);
      await controller.signIn(email: ' marie@example.test ', password: 'test');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.status, AuthStatus.authenticated);
      expect(controller.state.user!.displayName, 'Marie Tremblay');
      expect(backend.profileCalls, 1);
      expect(backend.roleCalls, 1);
      expect(backend.loginEmail, 'marie@example.test');
    },
  );

  for (final denial in [
    'missing profile',
    'disabled profile',
    'revoked roles',
  ]) {
    test('$denial clears the Supabase session after password login', () async {
      final backend = _Backend()..denial = denial;
      final repository = _repository(backend);
      final events = <AuthSessionEvent>[];
      final subscription = repository.sessionChanges.listen(events.add);
      addTearDown(subscription.cancel);
      await expectLater(
        _login(repository),
        throwsA(_failure(AuthFailureKind.accessDenied)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.hasSession, isFalse);
      expect(backend.logoutCalls, 1);
      expect(events, contains(AuthSessionEvent.accessDenied));
    });
  }

  for (final table in ['user_profiles', 'role_assignments']) {
    for (final code in ['503', '429', '42501', '403']) {
      test('$code during $table lookup preserves session for retry', () async {
        final backend = _Backend()
          ..failedTable = table
          ..lookupStatus = code == '42501' ? 403 : int.parse(code)
          ..lookupCode = code == '42501' ? code : null;
        final repository = _repository(backend);
        await expectLater(
          _login(repository),
          throwsA(_failure(AuthFailureKind.serviceUnavailable)),
        );
        expect(repository.hasSession, isTrue);
        expect(backend.logoutCalls, 0);
        backend.failedTable = null;
        expect(
          (await repository.restoreSession())!.displayName,
          'Marie Tremblay',
        );
      });
    }

    test(
      '42501 during $table resume check hides content and preserves session',
      () async {
        final backend = _Backend();
        final repository = _repository(backend);
        final controller = AuthController(repository);
        addTearDown(controller.dispose);
        await controller.signIn(email: 'marie@example.test', password: 'test');
        expect(controller.state.status, AuthStatus.authenticated);

        backend
          ..failedTable = table
          ..lookupStatus = 403
          ..lookupCode = '42501';
        await controller.revalidateOnResume();

        expect(controller.state.status, AuthStatus.accessBlocked);
        expect(controller.state.user, isNull);
        expect(repository.hasSession, isTrue);
        expect(backend.logoutCalls, 0);
        expect(
          controller.state.message,
          'Service temporairement indisponible. Réessayez dans un moment.',
        );
        expect(
          controller.state.message,
          isNot(contains('private lookup error')),
        );
        expect(controller.state.message, isNot(contains('42501')));

        backend.failedTable = null;
        await controller.restoreSession();
        expect(controller.state.status, AuthStatus.authenticated);
        expect(backend.loginCalls, 1);
      },
    );
  }

  test(
    'offline profile retrieval is a network failure without logout',
    () async {
      final backend = _Backend()..offlineLookup = true;
      final repository = _repository(backend);
      await expectLater(
        _login(repository),
        throwsA(_failure(AuthFailureKind.network)),
      );
      expect(repository.hasSession, isTrue);
      expect(backend.logoutCalls, 0);
    },
  );

  for (final entry in {
    'invalid_credentials': AuthFailureKind.invalidCredentials,
    'user_banned': AuthFailureKind.accessDenied,
    'session_expired': AuthFailureKind.sessionExpired,
    'unexpected_failure': AuthFailureKind.serviceUnavailable,
  }.entries) {
    test(
      'auth error ${entry.key} has a safe distinct classification',
      () async {
        final backend = _Backend()..authError = entry.key;
        final repository = _repository(backend);
        await expectLater(_login(repository), throwsA(_failure(entry.value)));
        expect(backend.profileCalls, 0);
      },
    );
  }

  test(
    'stored session is reauthorized without another password login',
    () async {
      final backend = _Backend();
      final repository = _repository(backend);
      await backend.client.auth.setInitialSession(jsonEncode(backend.session));
      expect(
        (await repository.restoreSession())!.displayName,
        'Marie Tremblay',
      );
      expect(backend.loginCalls, 0);
      expect(backend.profileCalls, 1);
    },
  );

  test('revocation after login clears the session on revalidation', () async {
    final backend = _Backend();
    final repository = _repository(backend);
    await _login(repository);
    backend.denial = 'revoked roles';
    await expectLater(
      repository.restoreSession(),
      throwsA(_failure(AuthFailureKind.accessDenied)),
    );
    expect(repository.hasSession, isFalse);
  });

  test('expired access token refreshes before profile retrieval', () async {
    final backend = _Backend();
    final repository = _repository(backend);
    await backend.client.auth.setInitialSession(
      jsonEncode(backend.expiredSession),
    );
    expect((await repository.restoreSession())!.displayName, 'Marie Tremblay');
    expect(backend.refreshCalls, 1);
    expect(repository.hasSession, isTrue);
  });

  test(
    'rejected refresh removes content and reports session expiration',
    () async {
      final backend = _Backend()..authError = 'refresh_token_not_found';
      final repository = _repository(backend);
      await backend.client.auth.setInitialSession(
        jsonEncode(backend.expiredSession),
      );
      final controller = AuthController(repository);
      addTearDown(controller.dispose);
      await controller.restoreSession();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.status, AuthStatus.signedOut);
      expect(controller.state.message, contains('expiré'));
      expect(repository.hasSession, isFalse);
    },
  );

  test('external SDK signOut removes application content', () async {
    final backend = _Backend();
    final repository = _repository(backend);
    final controller = AuthController(repository);
    addTearDown(controller.dispose);
    await controller.signIn(email: 'marie@example.test', password: 'test');
    await backend.client.auth.signOut();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.user, isNull);
  });

  test('remote logout failure reports local removal without claiming server success', () async {
    final backend = _Backend()..logoutFails = true;
    final repository = _repository(backend);
    final controller = AuthController(repository);
    addTearDown(controller.dispose);
    await controller.signIn(email: 'marie@example.test', password: 'test');
    await controller.signOut();
    expect(repository.hasSession, isFalse);
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.message, contains('n’a pas pu être confirmée'));
  });

  test(
    'logout waits for a pending password response and removes its session',
    () async {
      final backend = _Backend()..passwordResponse = Completer<http.Response>();
      final repository = _repository(backend);
      final controller = AuthController(repository);
      addTearDown(controller.dispose);
      final login = controller.signIn(
        email: 'marie@example.test',
        password: 'test',
      );
      await backend.passwordStarted.future;
      final logout = controller.signOut();
      backend.passwordResponse!.complete(_json(backend.session));
      await Future.wait([login, logout]);
      expect(repository.hasSession, isFalse);
      expect(controller.state.status, AuthStatus.signedOut);
      expect(backend.profileCalls, 0);
    },
  );

  test('late denied lookup cannot clear a newer authorized login', () async {
    final backend = _Backend()..profileResponse = Completer<http.Response>();
    final repository = _repository(backend);
    final oldLogin = _login(repository);
    final oldExpectation = expectLater(oldLogin, throwsA(isA<AuthFailure>()));
    await backend.profileStarted.future;
    backend.profileResponse = null;
    await _login(repository);
    backend.pendingProfile!.complete(_json([]));
    await oldExpectation;
    expect(repository.hasSession, isTrue);
    expect(backend.logoutCalls, 0);
  });
}

Matcher _failure(AuthFailureKind kind) =>
    isA<AuthFailure>().having((failure) => failure.kind, 'kind', kind);

Future<Object> _login(SupabaseAuthRepository repository) =>
    repository.signIn(email: 'marie@example.test', password: 'test');

SupabaseAuthRepository _repository(_Backend backend) {
  backend.client = SupabaseClient(
    'https://fictional.example.test',
    'fictional-publishable-key',
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
    postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
  );
  addTearDown(backend.client.dispose);
  return SupabaseAuthRepository(backend.client);
}

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {
    'content-type': 'application/json',
    'x-supabase-api-version': '2024-01-01',
  },
);

class _Backend {
  late SupabaseClient client;
  String? denial;
  String? failedTable;
  int lookupStatus = 503;
  String? lookupCode;
  bool offlineLookup = false;
  String? authError;
  bool logoutFails = false;
  int profileCalls = 0;
  int roleCalls = 0;
  int logoutCalls = 0;
  int loginCalls = 0;
  int refreshCalls = 0;
  String? loginEmail;
  Completer<http.Response>? passwordResponse;
  Completer<http.Response>? profileResponse;
  Completer<http.Response>? pendingProfile;
  final passwordStarted = Completer<void>();
  final profileStarted = Completer<void>();

  Map<String, Object> get session => _session(3600);
  Map<String, Object> get expiredSession => _session(-120);

  Map<String, Object> _session(int seconds) {
    final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + seconds;
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token =
        '${encode({'alg': 'HS256'})}.${encode({'exp': expires, 'sub': 'auth-employee'})}.test';
    return {
      'access_token': token,
      'refresh_token': 'fictional-refresh-token',
      'token_type': 'bearer',
      'expires_in': seconds,
      'user': {
        'id': 'auth-employee',
        'aud': 'authenticated',
        'email': 'marie@example.test',
        'app_metadata': <String, Object>{},
        'user_metadata': <String, Object>{},
        'created_at': '2026-10-01T00:00:00Z',
      },
    };
  }

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/token')) {
      if (request.url.queryParameters['grant_type'] == 'password') {
        loginCalls++;
        loginEmail = (jsonDecode(request.body) as Map)['email'] as String;
        if (!passwordStarted.isCompleted) passwordStarted.complete();
        if (passwordResponse != null) return passwordResponse!.future;
      } else {
        refreshCalls++;
      }
      if (authError != null) {
        return _json({
          'code': authError,
          'msg': 'private backend message',
        }, authError == 'unexpected_failure' ? 503 : 400);
      }
      return _json(session);
    }
    if (path.endsWith('/logout')) {
      logoutCalls++;
      if (logoutFails) return _json({'msg': 'private logout error'}, 503);
      return _json({});
    }
    if (path.endsWith('/user_profiles')) {
      profileCalls++;
      if (!profileStarted.isCompleted) profileStarted.complete();
      if (profileResponse != null) {
        pendingProfile = profileResponse;
        return profileResponse!.future;
      }
      if (offlineLookup) throw http.ClientException('private socket error');
      if (failedTable == 'user_profiles') {
        return _json({
          'message': 'private lookup error',
          if (lookupCode != null) 'code': lookupCode,
        }, lookupStatus);
      }
      if (denial == 'missing profile') return _json([]);
      return _json([
        {
          'id': 'profile-employee',
          'company_id': 'company-jmservice',
          'display_name': 'Marie Tremblay',
          'email': 'marie@example.test',
          'status': denial == 'disabled profile' ? 'disabled' : 'active',
        },
      ]);
    }
    if (path.endsWith('/role_assignments')) {
      roleCalls++;
      if (failedTable == 'role_assignments') {
        return _json({
          'message': 'private lookup error',
          if (lookupCode != null) 'code': lookupCode,
        }, lookupStatus);
      }
      return _json(
        denial == 'revoked roles'
            ? []
            : [
                {'role': 'employee'},
              ],
      );
    }
    throw StateError('Unexpected mocked request: $path');
  }
}
