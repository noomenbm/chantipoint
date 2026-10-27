// Explicit read-only integration check. Private inputs stay outside the repo.
import 'dart:convert';
import 'dart:io';

import 'package:chantipoint/src/attendance/history/session_history.dart';
import 'package:chantipoint/src/attendance/history/supabase_session_history_repository.dart';
import 'package:chantipoint/src/auth/supabase_auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const configPath = String.fromEnvironment('BETA_PRIVATE_CONFIG');
  const sessionPath = String.fromEnvironment('BETA_PRIVATE_SESSION');
  test(
    'reviewed hosted History through the real repository, read only',
    () async {
      final config = jsonDecode(File(configPath).readAsStringSync()) as Map;
      final session = File(sessionPath).readAsStringSync();
      final client = SupabaseClient(
        config['SUPABASE_URL'] as String,
        config['SUPABASE_PUBLISHABLE_KEY'] as String,
        httpClient: _ReadOnlyHistoryClient(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
      );
      addTearDown(client.dispose);
      // Never use setSession/refreshSession: the phone owns its refresh token.
      await client.auth.setInitialSession(session);
      expect(client.auth.currentSession!.isExpired, isFalse);
      final auth = SupabaseAuthRepository(client);
      final user = await auth.restoreSession();
      expect(user, isNotNull);
      final repository = SupabaseSessionHistoryRepository(
        client,
        user!,
        () => true,
        capabilities: const HistoryCapabilities(notes: true, review: true),
      );
      final page = await repository.load(
        HistoryWindow.sixMonths(DateTime.now()),
      );
      // Known existing developer fixture; no records or notes are printed.
      expect(page.sessions, hasLength(3));
      expect(page.next, isNull);
      expect(
        page.sessions.any((s) => (s.employeeNote ?? '').isNotEmpty),
        isTrue,
      );
      expect(page.sessions.every((s) => s.reviewStatus != null), isTrue);
      expect(repository.isCurrent, isTrue);
    },
    skip: configPath.isEmpty || sessionPath.isEmpty,
  );
}

// Enforce read-only transport even if the SDK wants to refresh an expiring token
// or clean up a denied session. Such a run must fail, never alter phone login.
final class _ReadOnlyHistoryClient extends http.BaseClient {
  final _inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET' || !request.url.path.startsWith('/rest/v1/')) {
      throw StateError('Read-only History transport refused this request.');
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
