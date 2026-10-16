import 'dart:async';

import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/authorized_user.dart';
import 'attendance_models.dart';
import 'attendance_repository.dart';

class SupabaseAttendanceRepository implements AttendanceRepository {
  SupabaseAttendanceRepository(this._client, this.user)
    : _authUserId = _client.auth.currentUser?.id;
  final SupabaseClient _client;
  final AuthorizedUser user;
  final String? _authUserId;
  static const _columns =
      'id, location_context, lifecycle_status, started_at, ended_at, site_description, check_in_device_observed_at, check_out_device_observed_at';

  void _checkIdentity() {
    if (_authUserId == null ||
        _client.auth.currentUser?.id != _authUserId ||
        _client.auth.currentSession == null) {
      throw const AttendanceFailure(AttendanceFailureKind.sessionExpired);
    }
    if (!user.roles.contains(AuthorizedRole.employee)) {
      throw const AttendanceFailure(AttendanceFailureKind.unauthorized);
    }
  }

  Future<T> _request<T>(Future<T> Function() work, {bool rpc = false}) async {
    try {
      _checkIdentity();
      final result = await work().timeout(const Duration(seconds: 20));
      _checkIdentity();
      return result;
    } catch (error) {
      if (error is AttendanceFailure) rethrow;
      if (error is TimeoutException ||
          error is ClientException ||
          error is AuthRetryableFetchException) {
        throw const AttendanceFailure(AttendanceFailureKind.network);
      }
      if (error is AuthSessionMissingException ||
          (error is AuthException &&
              const {
                'session_expired',
                'session_not_found',
                'refresh_token_not_found',
                'refresh_token_already_used',
                'invalid_jwt',
                'bad_jwt',
              }.contains(error.code)) ||
          (error is PostgrestException &&
              const {'PGRST301', 'PGRST303', '401'}.contains(error.code))) {
        throw const AttendanceFailure(AttendanceFailureKind.sessionExpired);
      }
      if (rpc && error is PostgrestException) {
        final kind = switch (error.message) {
          'authentication_required' => AttendanceFailureKind.sessionExpired,
          'employee_role_required' || 'active_session_not_found_for_employee' =>
            AttendanceFailureKind.unauthorized,
          'active_session_exists' => AttendanceFailureKind.duplicateActive,
          'idempotency_key_conflict' =>
            AttendanceFailureKind.idempotencyConflict,
          'session_not_active' => AttendanceFailureKind.sessionNotActive,
          _ => AttendanceFailureKind.backend,
        };
        throw AttendanceFailure(kind);
      }
      // A generic permission error may be backend configuration, not revocation.
      throw const AttendanceFailure(AttendanceFailureKind.backend);
    }
  }

  @override
  Future<WorkSession?> activeSession() => _request(() async {
    final row = await _client
        .from('work_sessions')
        .select(_columns)
        .eq('employee_profile_id', user.profileId)
        .eq('company_id', user.companyId)
        .eq('lifecycle_status', 'active')
        .maybeSingle();
    return row == null ? null : WorkSession.fromJson(row);
  });

  @override
  Future<WorkSession?> findCommand(
    AttendanceCommand command,
  ) => _request(() async {
    final column = command.kind == AttendanceCommandKind.checkIn
        ? 'check_in_idempotency_key'
        : 'check_out_idempotency_key';
    final row = await _client
        .from('work_sessions')
        .select(_columns)
        .eq('employee_profile_id', user.profileId)
        .eq('company_id', user.companyId)
        .eq(column, command.key)
        .maybeSingle();
    if (row == null) return null;
    final session = WorkSession.fromJson(row);
    final observedColumn = command.kind == AttendanceCommandKind.checkIn
        ? 'check_in_device_observed_at'
        : 'check_out_device_observed_at';
    final observed = row[observedColumn];
    if (observed is! String ||
        DateTime.parse(observed).toUtc() !=
            DateTime.parse(command.payload['p_device_observed_at'] as String)
                .toUtc() ||
        (command.kind == AttendanceCommandKind.checkIn &&
            row['site_description'] != null)) {
      throw const AttendanceFailure(AttendanceFailureKind.idempotencyConflict);
    }
    if (!session.isFactory ||
        (command.kind == AttendanceCommandKind.checkOut &&
            (session.id != command.payload['p_work_session_id'] ||
                session.isActive))) {
      throw const AttendanceFailure(AttendanceFailureKind.backend);
    }
    return session;
  });

  @override
  Future<WorkSession> submit(AttendanceCommand command) => _request(() async {
    final result = await _client.rpc(command.rpc, params: command.payload);
    final row = Map<String, dynamic>.from(result as Map);
    if (!const [
      'created',
      'closed',
      'idempotent_replay',
    ].contains(row['status'])) {
      throw const FormatException('Unacknowledged command');
    }
    final session = WorkSession.fromJson(row);
    if (!session.isFactory ||
        (command.kind == AttendanceCommandKind.checkOut &&
            (session.id != command.payload['p_work_session_id'] ||
                session.isActive))) {
      throw const FormatException('Invalid command acknowledgement');
    }
    return session;
  }, rpc: true);
}
