// Fictional PostgREST SELECT envelope over the existing composite foreign keys.
import 'package:chantipoint/src/attendance/journal/journal_command.dart';

import 'journal_fixtures.dart';

Map<String, dynamic> activeSessionRow({JournalBinding? owner, String? id}) {
  final binding = owner ?? journalBinding();
  return {
    'id': id ?? journalSessionId,
    'company_id': binding.companyId,
    'employee_profile_id': binding.profileId,
    'location_context': 'location_unverified',
    'lifecycle_status': 'active',
    'started_at': '2026-10-17T10:00:00-04:00',
    'ended_at': null,
    'site_description': 'Lieu de test',
    'employee_note': 'Note canonique fictive',
    'review_status': 'anomaly_open',
  };
}

List<Map<String, dynamic>> activeSelection({
  JournalBinding? owner,
  List<Map<String, dynamic>>? sessions,
}) {
  final binding = owner ?? journalBinding();
  return [
    {
      'id': binding.profileId,
      'auth_user_id': binding.authUserId,
      'company_id': binding.companyId,
      'status': 'active',
      'employee_role': <Map<String, dynamic>>[
        {
          'role': 'employee',
          'status': 'active',
          'user_profile_id': binding.profileId,
          'company_id': binding.companyId,
        },
      ],
      'sessions': sessions ?? [activeSessionRow(owner: binding)],
    },
  ];
}
