import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'attendance_models.dart';
import 'attendance_operation_transport.dart';
import 'attendance_request_authority.dart';
import 'journal/journal_command.dart';
import 'journal/journal_json.dart';
import 'notes/session_note_ports.dart';
import 'notes/session_note_record.dart';

enum AttendanceSessionProjection { legacy, v2 }

enum AttendanceHttpFailureKind {
  contextInvalidated,
  authorityUnavailable,
  scopeMismatch,
  invalidRequest,
  network,
  http,
  responseTooLarge,
  malformedResponse,
  authorizationUnavailable,
  staleObservation,
}

/// Safe codes only. Never attach URLs, credentials, bodies or underlying errors.
final class AttendanceHttpFailure implements Exception {
  const AttendanceHttpFailure(this.kind);
  final AttendanceHttpFailureKind kind;
  @override
  String toString() => 'AttendanceHttpFailure(${kind.name})';
}

/// Isolated PostgREST boundary: no SupabaseClient/global auth, wiring or timers.
/// Inject a non-retrying client that honors followRedirects=false and whose send
/// and response stream cover local work through settlement (no timeout wrapper).
/// It must not log request/response data or credentials.
/// Caller owns its lifetime: do not close it while operations remain outstanding.
final class SupabaseAttendanceOperationTransport
    implements
        AttendanceOperationTransport,
        AttendanceCanonicalReader,
        AttendanceActiveSessionQuery,
        SessionNoteTransport {
  SupabaseAttendanceOperationTransport({
    required this.authority,
    required this.client,
    this.projection = AttendanceSessionProjection.v2,
    this.authorizeWrite,
  });
  @override
  final AttendanceRequestAuthority authority;
  final http.Client client;
  final AttendanceSessionProjection projection;
  // Optional isolated transport hook; normal composition ALWAYS supplies it.
  // It runs after asynchronous credential resolution, immediately before send.
  final void Function(AttendanceOperationIdentity identity, String path)?
  authorizeWrite;

  /// Separate keyed-note protocol, sharing only the pinned one-attempt HTTP
  /// machinery. No attendance command/DTO/journal conversion or live wiring.
  @override
  Future<SessionNoteReceipt> saveNote(
    AttendanceOperationIdentity identity,
    SessionNoteCommand command, {
    required bool replayOnly,
  }) async {
    if (!command.identity.binding.matches(identity.binding) ||
        (!replayOnly && command.identity.generation != identity.generation)) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.scopeMismatch,
      );
    }
    final scope = await _acquire(identity);
    final text = await _send(
      identity,
      scope,
      'POST',
      '/rest/v1/rpc/save_employee_note',
      body: command.body(replayOnly: replayOnly),
    );
    // Do not discard a valid late receipt after submission/auth invalidation.
    try {
      return SessionNoteReceipt.parse(text, command);
    } catch (_) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.malformedResponse,
      );
    }
  }

  static const responseLimit = JournalJson.payloadLimit;
  static const _v2Columns = {
    'id',
    'employee_profile_id',
    'company_id',
    'location_context',
    'lifecycle_status',
    'started_at',
    'ended_at',
    'site_description',
    'employee_note',
    'review_status',
  };
  Set<String> get _columns => projection == AttendanceSessionProjection.v2
      ? _v2Columns
      : _v2Columns.difference({'employee_note', 'review_status'});

  /// One SELECT snapshot proves both visible employee authorization and the
  /// active selection. A bare work_sessions [] can also mean RLS hid a revoked
  /// employee; it cannot safely establish "no active session".
  @override
  Future<WorkSession?> readActiveSession(
    AttendanceOperationIdentity identity,
  ) async {
    final scope = await _acquire(identity);
    final binding = identity.binding;
    final text = await _send(
      identity,
      scope,
      'GET',
      '/rest/v1/user_profiles',
      query: {
        'select':
            'id,auth_user_id,company_id,status,'
            'employee_role:role_assignments!role_assignments_profile_company_fk'
            '(role,status,user_profile_id,company_id),'
            'sessions:work_sessions!work_sessions_employee_company_fk'
            '(${_columns.join(',')})',
        'id': 'eq.${binding.profileId}',
        'auth_user_id': 'eq.${binding.authUserId}',
        'company_id': 'eq.${binding.companyId}',
        'status': 'eq.active',
        'employee_role.role': 'eq.employee',
        'employee_role.status': 'eq.active',
        'employee_role.user_profile_id': 'eq.${binding.profileId}',
        'employee_role.company_id': 'eq.${binding.companyId}',
        'employee_role.limit': '2',
        'sessions.employee_profile_id': 'eq.${binding.profileId}',
        'sessions.company_id': 'eq.${binding.companyId}',
        'sessions.lifecycle_status': 'eq.active',
        'sessions.limit': '2',
        'limit': '2',
      },
    );
    _check(identity, scope);
    try {
      final profiles = JournalJson.decodeText(text, limit: responseLimit);
      if (profiles is! List || profiles.length > 1) invalidJournal();
      if (profiles.isEmpty) {
        throw const AttendanceHttpFailure(
          AttendanceHttpFailureKind.authorizationUnavailable,
        );
      }
      final profile = journalObject(profiles.single);
      journalFields(profile, {
        'id',
        'auth_user_id',
        'company_id',
        'status',
        'employee_role',
        'sessions',
      });
      if (profile['id'] != binding.profileId ||
          profile['auth_user_id'] != binding.authUserId ||
          profile['company_id'] != binding.companyId) {
        invalidJournal();
      }
      final roles = profile['employee_role'];
      if (roles is! List || roles.length > 1) invalidJournal();
      if (profile['status'] != 'active' || roles.isEmpty) {
        throw const AttendanceHttpFailure(
          AttendanceHttpFailureKind.authorizationUnavailable,
        );
      }
      final role = journalObject(roles.single);
      journalFields(role, {'role', 'status', 'user_profile_id', 'company_id'});
      if (role['role'] != 'employee' ||
          role['status'] != 'active' ||
          role['user_profile_id'] != binding.profileId ||
          role['company_id'] != binding.companyId) {
        invalidJournal();
      }
      final sessions = profile['sessions'];
      if (sessions is! List || sessions.length > 1) invalidJournal();
      if (sessions.isEmpty) return null;
      final row = journalObject(sessions.single);
      journalFields(row, _columns);
      if (row['company_id'] != binding.companyId ||
          row['employee_profile_id'] != binding.profileId ||
          row['id'] is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(row['id'] as String) ||
          row['lifecycle_status'] != 'active' ||
          row['ended_at'] != null ||
          (projection == AttendanceSessionProjection.v2 &&
              !WorkSession.reviewStatuses.contains(row['review_status']))) {
        invalidJournal();
      }
      journalTimestamp(row['started_at']);
      final session = WorkSession.fromJson(row);
      _check(identity, scope);
      return session;
    } on AttendanceHttpFailure {
      rethrow;
    } catch (_) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.malformedResponse,
      );
    }
  }

  @override
  Future<AttendanceTransportReply> dispatch(
    AttendanceOperationIdentity identity,
    JournalCommand command, {
    required bool replayOnly,
  }) async {
    if (command.protocol != JournalProtocol.attendanceV2) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.invalidRequest,
      );
    }
    // Initial body is byte-for-byte frozen UTF-8. Replay changes only the
    // operational flag's value via the existing map contract; the stored string
    // is never rewritten. No typed request/DateTime/note reconstruction occurs.
    final String body;
    try {
      body = replayOnly
          ? JournalJson.encode(
              command.rpcParameters(replayOnly: true),
              limit: JournalJson.payloadLimit,
            )
          : command.parametersJson;
    } catch (_) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.invalidRequest,
      );
    }
    final scope = await _acquire(identity);
    final text = await _send(
      identity,
      scope,
      'POST',
      '/rest/v1/rpc/${command.rpc}',
      body: body,
    );
    // Deliberately NO currency check after submission: C3.1 alone owns late
    // receipt validation/finalization. Only an exact, validated replay miss is
    // reduced to a sentinel; every other 2xx UTF-8 body remains original text.
    if (replayOnly) {
      try {
        final value = journalObject(
          JournalJson.decodeText(text, limit: responseLimit),
        );
        journalFields(value, {'contract_version', 'status'});
        if (value['contract_version'] is int &&
            value['contract_version'] == 2 &&
            value['status'] == 'not_found') {
          return const AttendanceTransportReply.replayMiss();
        }
      } catch (_) {
        // Core's strict JournalConfirmation validator handles malformed replies.
      }
    }
    return AttendanceTransportReply.acknowledged(text);
  }

  @override
  Future<WorkSession?> readSession(
    AttendanceOperationIdentity identity,
    String sessionId,
  ) async {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(sessionId)) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.invalidRequest,
      );
    }
    final scope = await _acquire(identity);
    final text = await _send(
      identity,
      scope,
      'GET',
      '/rest/v1/work_sessions',
      query: {
        'select': _columns.join(','),
        'id': 'eq.$sessionId',
        'company_id': 'eq.${identity.binding.companyId}',
        'employee_profile_id': 'eq.${identity.binding.profileId}',
        'limit': '2',
      },
    );
    _check(identity, scope);
    try {
      final rows = JournalJson.decodeText(text, limit: responseLimit);
      if (rows is! List || rows.length > 1) invalidJournal();
      if (rows.isEmpty) return null;
      final row = journalObject(rows.single);
      journalFields(row, _columns);
      if (row['id'] != sessionId ||
          row['company_id'] != identity.binding.companyId ||
          row['employee_profile_id'] != identity.binding.profileId ||
          (projection == AttendanceSessionProjection.v2 &&
              !WorkSession.reviewStatuses.contains(row['review_status']))) {
        invalidJournal();
      }
      final session = WorkSession.fromJson(row);
      _check(identity, scope);
      return session;
    } on AttendanceHttpFailure {
      rethrow;
    } catch (_) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.malformedResponse,
      );
    }
  }

  Future<AttendanceRequestScope> _acquire(
    AttendanceOperationIdentity identity,
  ) async {
    _checkCurrent(identity);
    final AttendanceRequestScope scope;
    try {
      scope = await authority.acquire(identity);
    } catch (_) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.authorityUnavailable,
      );
    }
    _check(identity, scope);
    if (!_header(scope.accessToken, 8192) ||
        !_header(scope.publishableKey, 4096)) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.scopeMismatch,
      );
    }
    return scope;
  }

  void _checkCurrent(AttendanceOperationIdentity identity) {
    try {
      if (authority.isCurrent(identity)) return;
    } catch (_) {
      // No private authority details escape this boundary.
    }
    throw const AttendanceHttpFailure(
      AttendanceHttpFailureKind.contextInvalidated,
    );
  }

  void _check(
    AttendanceOperationIdentity identity,
    AttendanceRequestScope scope,
  ) {
    _checkCurrent(identity);
    if (!scope.identity.binding.matches(identity.binding) ||
        scope.identity.generation != identity.generation ||
        scope.projectUrl.toString() != identity.binding.baseUrl) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.scopeMismatch,
      );
    }
    try {
      if (scope.isCurrent) return;
    } catch (_) {
      // Treat a broken currency observation as invalid, never as permission.
    }
    throw const AttendanceHttpFailure(
      AttendanceHttpFailureKind.contextInvalidated,
    );
  }

  static bool _header(String value, int limit) =>
      value.isNotEmpty &&
      value.length <= limit &&
      value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

  Future<String> _send(
    AttendanceOperationIdentity identity,
    AttendanceRequestScope scope,
    String method,
    String path, {
    String? body,
    Map<String, String>? query,
  }) async {
    final request =
        http.Request(
            method,
            scope.projectUrl.replace(path: path, queryParameters: query),
          )
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            'apikey': scope.publishableKey,
            'Authorization': 'Bearer ${scope.accessToken}',
            'Accept': 'application/json',
            if (method == 'POST')
              'Content-Type': 'application/json; charset=utf-8',
            if (method == 'POST') 'Content-Profile': 'public',
            if (method == 'GET') 'Accept-Profile': 'public',
          });
    if (body != null) {
      // Check UTF-16 size before encoding, then the actual UTF-8 byte count.
      if (body.length > JournalJson.payloadLimit) {
        throw const AttendanceHttpFailure(
          AttendanceHttpFailureKind.invalidRequest,
        );
      }
      final bytes = utf8.encode(body);
      if (bytes.length > JournalJson.payloadLimit) {
        throw const AttendanceHttpFailure(
          AttendanceHttpFailureKind.invalidRequest,
        );
      }
      request.bodyBytes = bytes;
    }
    _check(identity, scope); // No await between this check and submission.
    if (method == 'POST') authorizeWrite?.call(identity, path);
    try {
      final response = await client.send(request); // Exactly one send.
      return await _consume(response);
    } on AttendanceHttpFailure {
      rethrow;
    } catch (_) {
      throw const AttendanceHttpFailure(AttendanceHttpFailureKind.network);
    }
  }

  static Future<String> _consume(http.StreamedResponse response) async {
    final success = response.statusCode >= 200 && response.statusCode < 300;
    final bytes = BytesBuilder();
    var count = 0;
    var oversized = (response.contentLength ?? 0) > responseLimit;
    var failed = false;
    // Consume errors and oversize/error bodies through stream termination.
    // Retain at most responseLimit bytes, never an unbounded response.toBytes().
    // No early throw/cancel/timeout detaches continuing local response work.
    await for (final chunk in response.stream.handleError((Object _) {
      failed = true;
    })) {
      if (oversized) continue;
      if (chunk.length > responseLimit - count) {
        oversized = true;
        bytes.clear();
        continue;
      }
      count += chunk.length;
      if (success) bytes.add(chunk);
    }
    if (failed) {
      throw const AttendanceHttpFailure(AttendanceHttpFailureKind.network);
    }
    if (!success) {
      throw const AttendanceHttpFailure(AttendanceHttpFailureKind.http);
    }
    if (oversized) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.responseTooLarge,
      );
    }
    if (response.contentLength != null && response.contentLength != count) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.malformedResponse,
      );
    }
    try {
      final complete = bytes.takeBytes();
      // Dart's UTF-8 decoder strips a leading BOM. Reject it instead of silently
      // altering input into a confirmable object or replay-miss sentinel.
      if (complete.length >= 3 &&
          complete[0] == 0xef &&
          complete[1] == 0xbb &&
          complete[2] == 0xbf) {
        throw const FormatException();
      }
      return utf8.decode(complete); // Strict; preserve original text.
    } catch (_) {
      throw const AttendanceHttpFailure(
        AttendanceHttpFailureKind.malformedResponse,
      );
    }
  }
}
