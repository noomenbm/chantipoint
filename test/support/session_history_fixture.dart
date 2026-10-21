// Fictional history records and mocked HTTP only. No singleton or hosted client.
import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/history/session_history.dart';
import 'package:chantipoint/src/attendance/history/supabase_session_history_repository.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const historyEmployee = AuthorizedUser(
  profileId: '10000000-0000-4000-8000-000000000001',
  companyId: '20000000-0000-4000-8000-000000000001',
  displayName: 'Camille Exemple',
  email: 'camille@example.test',
  roles: {AuthorizedRole.employee},
);
const historyAuthId = '30000000-0000-4000-8000-000000000001';
final historyNow = DateTime.utc(2026, 10, 21, 16);
String historyId(int value) =>
    '40000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';
Map<String, dynamic> historyRow(
  int id, {
  String start = '2026-10-15T14:00:00.123456+00:00',
}) => {
  'id': historyId(id),
  'employee_profile_id': historyEmployee.profileId,
  'company_id': historyEmployee.companyId,
  'location_context': 'external_worksite',
  'lifecycle_status': 'closed_manual',
  'started_at': start,
  'ended_at': '2026-10-16T01:00:00+00:00',
  'site_description': 'Atelier exemple',
};
Map<String, dynamic> historyProfile(List<Map<String, dynamic>> rows) => {
  'id': historyEmployee.profileId,
  'auth_user_id': historyAuthId,
  'company_id': historyEmployee.companyId,
  'status': 'active',
  'employee_role': [
    {
      'role': 'employee',
      'status': 'active',
      'user_profile_id': historyEmployee.profileId,
      'company_id': historyEmployee.companyId,
    },
  ],
  'sessions': rows,
};

class HistoryHttpFixture {
  HistoryHttpFixture() {
    client = SupabaseClient(
      'https://fictional.example.test',
      'fictional-public-key',
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
  }
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (handler != null) return handler!(request);
    final q = request.url.queryParameters;
    final before = q['sessions.or'];
    var selected = rows.where((row) {
      final start = DateTime.parse(row['started_at'] as String).toUtc();
      final since = request.url.queryParametersAll['sessions.started_at']!
          .firstWhere((value) => value.startsWith('gte.'))
          .substring(4);
      if (start.isBefore(DateTime.parse(since))) return false;
      // Duplicate filter keys are preserved by PostgREST (gte and lt).
      final until = request.url.queryParametersAll['sessions.started_at']!
          .firstWhere((value) => value.startsWith('lt.'))
          .substring(3);
      if (!start.isBefore(DateTime.parse(until))) return false;
      if (before == null) return true;
      final time = DateTime.parse(
        RegExp(r'started_at.lt.([^,]+)').firstMatch(before)!.group(1)!,
      );
      final id = RegExp(r'id.lt.([^)]+)').firstMatch(before)!.group(1)!;
      return start.isBefore(time) ||
          (start == time && (row['id'] as String).compareTo(id) < 0);
    }).toList();
    selected.sort((a, b) {
      final time = DateTime.parse(b['started_at'] as String)
          .compareTo(DateTime.parse(a['started_at'] as String));
      return time != 0
          ? time
          : (b['id'] as String).compareTo(a['id'] as String);
    });
    selected = selected.take(int.parse(q['sessions.limit']!)).toList();
    return json([historyProfile(selected)]);
  }

  late final SupabaseClient client;
  final requests = <http.Request>[];
  final rows = <Map<String, dynamic>>[];
  Future<http.Response> Function(http.Request)? handler;
  bool current = true;
  static http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Future<void> login({
    String authId = historyAuthId,
    int generation = 1,
  }) async {
    String tokenPart(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    await client.auth.setInitialSession(
      jsonEncode({
        'access_token':
            '${tokenPart({'alg': 'HS256'})}.${tokenPart({'sub': authId, 'exp': expiry, 'session_id': historyId(generation)})}.c2lnbmF0dXJl',
        'refresh_token': 'fictional-refresh',
        'token_type': 'bearer',
        'user': {
          'id': authId,
          'aud': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }),
    );
  }

  SupabaseSessionHistoryRepository repository({
    HistoryCapabilities capabilities = const HistoryCapabilities(),
  }) => SupabaseSessionHistoryRepository(
    client,
    historyEmployee,
    () => current,
    capabilities: capabilities,
  );
}

class FakeHistoryRepository implements SessionHistoryRepository {
  FakeHistoryRepository({this.capabilities = const HistoryCapabilities()});
  @override
  final HistoryCapabilities capabilities;
  bool current = true;
  bool Function()? guard;
  @override
  bool get isCurrent => current && (guard?.call() ?? true);
  final cursors = <HistoryCursor?>[];
  final windows = <HistoryWindow>[];
  Future<HistoryPage> Function(HistoryCursor?)? handler;
  @override
  Future<HistoryPage> load(HistoryWindow window, {HistoryCursor? before}) {
    windows.add(window);
    cursors.add(before);
    return handler?.call(before) ?? Future.value(HistoryPage([], null));
  }
}

WorkSession historySession(int id, {String? note, String? review}) =>
    WorkSession.fromJson({
      ...historyRow(id),
      'employee_note': note,
      'review_status': review,
    });
