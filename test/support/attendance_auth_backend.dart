// Fictional SDK auth/HTTP fixture. No initialized Supabase singleton or network.
import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_auth_owner.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/supabase_auth_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'journal_fixtures.dart';

class AttendanceAuthBackend {
  AttendanceAuthBackend() {
    client = SupabaseClient(
      'https://fixture.invalid',
      'fictional-publishable-key',
      httpClient: MockClient((request) async {
        final response = await handle(request);
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
    repository = SupabaseAuthRepository(client);
    controller = AuthController(repository);
    owner = AttendanceAuthOwner(
      auth: controller,
      repository: repository,
      deployment: deployment(),
    );
  }
  late final SupabaseClient client;
  late final SupabaseAuthRepository repository;
  late final AuthController controller;
  late final AttendanceAuthOwner owner;
  final contexts = <AttendanceOperationContext>[];
  String account = journalBinding().authUserId;
  bool disabled = false;
  bool roleRevoked = false;
  bool administratorOnly = false;
  bool offlineProfile = false;
  bool logoutFails = false;
  int serial = 0, refreshCalls = 0, logoutCalls = 0, profileCalls = 0;
  String loginId = '00000000-0000-4000-8000-000000000100';
  Completer<http.Response>? refreshResponse, passwordResponse, profileResponse;
  final refreshStarted = Completer<void>();
  final passwordStarted = Completer<void>();
  final profileStarted = Completer<void>();

  AttendanceTrustedDeployment deployment({String? url, String? environment}) =>
      AttendanceTrustedDeployment(
        environmentId: environment ?? journalBinding().environmentId,
        projectUrl: Uri.parse(url ?? 'https://fixture.invalid'),
        publishableKey: 'fictional-publishable-key',
      );

  Future<void> login() async {
    await controller.signIn(
      email: 'fictional@example.test',
      password: 'fictional',
    );
    await turn();
  }

  AttendanceOperationContext context() {
    final context = owner.issueContext();
    contexts.add(context);
    return context;
  }

  void expire() {
    client.auth.currentSession!.expiresAt =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
  }

  Map<String, dynamic> session({
    String? auth,
    int seconds = 3600,
    String? login,
  }) {
    final user = auth ?? account;
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token =
        '${encode({'alg': 'HS256'})}.${encode({'sub': user, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + seconds, 'session_id': login ?? loginId, 'fictional_serial': ++serial})}.c2lnbmF0dXJl';
    return {
      'access_token': token,
      'refresh_token': 'fictional-refresh-$serial',
      'token_type': 'bearer',
      'expires_in': seconds,
      'user': {
        'id': user,
        'aud': 'authenticated',
        'email': 'fictional@example.test',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'created_at': '2026-10-01T00:00:00Z',
      },
    };
  }

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/token')) {
      if (request.url.queryParameters['grant_type'] == 'password') {
        loginId =
            '00000000-0000-4000-8000-${(100 + serial).toString().padLeft(12, '0')}';
        if (!passwordStarted.isCompleted) passwordStarted.complete();
        return passwordResponse == null
            ? json(session())
            : passwordResponse!.future;
      }
      refreshCalls++;
      if (!refreshStarted.isCompleted) refreshStarted.complete();
      return refreshResponse == null
          ? json(session(auth: client.auth.currentUser!.id))
          : refreshResponse!.future;
    }
    if (path.endsWith('/logout')) {
      logoutCalls++;
      return logoutFails
          ? json({'msg': 'private fictional error'}, 503)
          : json({});
    }
    if (path.endsWith('/user_profiles')) {
      profileCalls++;
      if (!profileStarted.isCompleted) profileStarted.complete();
      if (profileResponse != null) return profileResponse!.future;
      if (offlineProfile) {
        throw http.ClientException('private fictional network');
      }
      final first =
          request.url.queryParameters['auth_user_id'] ==
          'eq.${journalBinding().authUserId}';
      return json([
        {
          'id': first ? journalBinding().profileId : journalOtherId,
          'company_id': journalBinding().companyId,
          'status': disabled ? 'disabled' : 'active',
          'display_name': 'Fictional employee',
          'email': 'fictional@example.test',
        },
      ]);
    }
    if (path.endsWith('/role_assignments')) {
      return json(
        roleRevoked
            ? []
            : [
                {'role': administratorOnly ? 'administrator' : 'employee'},
              ],
      );
    }
    throw StateError('Unconfigured fictional auth endpoint');
  }

  Future<void> close() async {
    for (final context in contexts) {
      await context.release();
    }
    await owner.close();
    if (!controller.isDisposed) controller.dispose();
    await client.dispose();
  }
}

http.Response json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {
    'content-type': 'application/json',
    'x-supabase-api-version': '2024-01-01',
  },
);
Future<void> turn() => Future<void>.delayed(Duration.zero);
