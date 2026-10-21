import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/auth_session_evidence.dart';
import '../../auth/authorized_user.dart';
import '../attendance_models.dart';
import '../journal/journal_command.dart' show journalTimestamp;
import 'session_history.dart';

/// Legacy-compatible read only. One authorized parent snapshot per page avoids
/// treating an RLS-hidden employee/role as an empty work-session collection.
final class SupabaseSessionHistoryRepository
    implements SessionHistoryRepository {
  SupabaseSessionHistoryRepository(
    this.client,
    this.user,
    this._isCurrent, {
    this.capabilities = const HistoryCapabilities(),
  }) : _session = client.auth.currentSession == null
           ? null
           : AuthSessionEvidence(client.auth.currentSession!);
  final SupabaseClient client;
  final AuthorizedUser user;
  final bool Function() _isCurrent;
  final AuthSessionEvidence? _session;
  @override
  final HistoryCapabilities capabilities;
  static const pageSize = 20;
  static final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

  @override
  bool get isCurrent {
    final current = client.auth.currentSession;
    if (!_isCurrent() ||
        current == null ||
        _session == null ||
        !user.roles.contains(AuthorizedRole.employee)) {
      return false;
    }
    final evidence = AuthSessionEvidence(current);
    return (_session.sameSession(evidence) || _session.sameLogin(evidence)) &&
        (current.expiresAt == null ||
            current.expiresAt! * 1000 > DateTime.now().millisecondsSinceEpoch);
  }

  void _check() {
    if (!isCurrent) throw const HistoryFailure();
  }

  @override
  Future<HistoryPage> load(
    HistoryWindow window, {
    HistoryCursor? before,
  }) async {
    try {
      _check();
      if (!_uuid.hasMatch(user.profileId) ||
          !_uuid.hasMatch(user.companyId) ||
          (before != null &&
              (!_uuid.hasMatch(before.id) ||
                  !window.contains(before.startedAt)))) {
        throw const HistoryFailure();
      }
      final columns = [
        'id',
        'employee_profile_id',
        'company_id',
        'location_context',
        'lifecycle_status',
        'started_at',
        'ended_at',
        'site_description',
        if (capabilities.notes) 'employee_note',
        if (capabilities.review) 'review_status',
      ];
      var query = client
          .from('user_profiles')
          .select(
            'id,auth_user_id,company_id,status,'
            'employee_role:role_assignments!role_assignments_profile_company_fk'
            '(role,status,user_profile_id,company_id),'
            'sessions:work_sessions!work_sessions_employee_company_fk(${columns.join(',')})',
          )
          .eq('id', user.profileId)
          .eq('company_id', user.companyId)
          .eq('auth_user_id', _session!.authUserId)
          .eq('status', 'active')
          .eq('employee_role.role', 'employee')
          .eq('employee_role.status', 'active')
          .eq('employee_role.user_profile_id', user.profileId)
          .eq('employee_role.company_id', user.companyId)
          .eq('sessions.employee_profile_id', user.profileId)
          .eq('sessions.company_id', user.companyId)
          .gte('sessions.started_at', window.fromUtc.toIso8601String())
          .lt('sessions.started_at', window.untilUtc.toIso8601String());
      if (before != null) {
        final time = before.startedAt.toUtc().toIso8601String();
        query = query.or(
          'started_at.lt.$time,and(started_at.eq.$time,id.lt.${before.id})',
          referencedTable: 'sessions',
        );
      }
      _check();
      final rows = await query
          .order('started_at', ascending: false, referencedTable: 'sessions')
          .order('id', ascending: false, referencedTable: 'sessions')
          .limit(pageSize + 1, referencedTable: 'sessions')
          .limit(2, referencedTable: 'employee_role')
          .limit(2);
      _check();
      if (rows.length != 1) throw const HistoryFailure();
      final profile = rows.single;
      if (profile['id'] != user.profileId ||
          profile['company_id'] != user.companyId ||
          profile['auth_user_id'] != _session.authUserId ||
          profile['status'] != 'active') {
        throw const HistoryFailure();
      }
      final roles = profile['employee_role'];
      if (roles is! List || roles.length != 1) throw const HistoryFailure();
      final role = roles.single;
      if (role is! Map ||
          role['role'] != 'employee' ||
          role['status'] != 'active' ||
          role['user_profile_id'] != user.profileId ||
          role['company_id'] != user.companyId) {
        throw const HistoryFailure();
      }
      final data = profile['sessions'];
      if (data is! List || data.length > pageSize + 1) {
        throw const HistoryFailure();
      }
      final sessions = <WorkSession>[];
      var previous = before;
      for (final row in data) {
        if (row is! Map ||
            row.keys.toSet().difference(columns.toSet()).isNotEmpty ||
            columns.toSet().difference(row.keys.toSet()).isNotEmpty ||
            row['employee_profile_id'] != user.profileId ||
            row['company_id'] != user.companyId ||
            row['id'] is! String ||
            !_uuid.hasMatch(row['id'] as String) ||
            (capabilities.review && row['review_status'] == null)) {
          throw const HistoryFailure();
        }
        journalTimestamp(row['started_at']);
        if (row['ended_at'] != null) journalTimestamp(row['ended_at']);
        final session = WorkSession.fromJson(Map<String, dynamic>.from(row));
        final cursor = HistoryCursor.of(session);
        if (!window.contains(session.startedAt) ||
            (previous != null && !previous.precedes(cursor))) {
          throw const HistoryFailure();
        }
        previous = cursor;
        sessions.add(session);
      }
      final more = sessions.length > pageSize;
      final visible = sessions.take(pageSize).toList();
      return HistoryPage(visible, more ? HistoryCursor.of(visible.last) : null);
    } catch (_) {
      // No provider messages, employee data, tokens or URLs in public errors.
      throw const HistoryFailure();
    }
  }
}
