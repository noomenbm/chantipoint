import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'attendance_models.dart';
import 'attendance_operation_transport.dart';
import 'attendance_request_authority.dart';
import 'journal/journal_command.dart';
import 'journal/journal_json.dart';

enum AttendanceHttpFailureKind {
  contextInvalidated,
  authorityUnavailable,
  scopeMismatch,
  invalidRequest,
  network,
  http,
  responseTooLarge,
  malformedResponse,
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
    implements AttendanceOperationTransport, AttendanceCanonicalReader {
  SupabaseAttendanceOperationTransport({
    required this.authority,
    required this.client,
  });
  final AttendanceRequestAuthority authority;
  final http.Client client;
  static const responseLimit = JournalJson.payloadLimit;
  static const _columns = {
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
          !WorkSession.reviewStatuses.contains(row['review_status'])) {
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
