import 'package:chantipoint/src/attendance/history/session_history.dart';
import 'package:chantipoint/src/config/supabase_environment_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_history_fixture.dart';

const reviewed = SupabaseEnvironmentConfig(
  url: 'https://fictional.example.test',
  publishableKey: 'fictional-public-key',
  missingValues: [],
  keySource: 'test',
  historyNotesEnabled: true,
  historyReviewEnabled: true,
);

void main() {
  test('unprovisioned deployment keeps conservative History selection', () {
    const config = SupabaseEnvironmentConfig(
      url: '',
      publishableKey: '',
      missingValues: [],
      keySource: 'test',
    );
    expect(config.historyCapabilities.notes, isFalse);
    expect(config.historyCapabilities.review, isFalse);
    expect(reviewed.historyCapabilities.notes, isTrue);
    expect(reviewed.historyCapabilities.review, isTrue);
  });

  late HistoryHttpFixture fixture;
  setUp(() async {
    fixture = HistoryHttpFixture();
    await fixture.login();
  });
  tearDown(() => fixture.client.dispose());

  test(
    'reviewed deployment selects canonical notes and review flags',
    () async {
      fixture.rows.add({
        ...historyRow(1),
        'employee_note': '  Réparation terminée  ',
        'review_status': 'anomaly_open',
      });
      final page = await fixture
          .repository(capabilities: reviewed.historyCapabilities)
          .load(HistoryWindow.sixMonths(historyNow));
      expect(page.sessions.single.employeeNote, '  Réparation terminée  ');
      expect(page.sessions.single.reviewStatus, 'anomaly_open');
      final select = fixture.requests.single.url.queryParameters['select']!;
      expect(select, contains('employee_note,review_status'));
    },
  );

  for (final error in [
    'missing note',
    'missing review',
    'foreign owner',
    'missing role',
    'backend error',
  ]) {
    test(
      'enriched History $error remains an error with no weaker retry',
      () async {
        final row = {
          ...historyRow(1),
          'employee_note': 'Private fixture note',
          'review_status': 'anomaly_open',
        };
        final profile = historyProfile([row]);
        switch (error) {
          case 'missing note':
            row.remove('employee_note');
          case 'missing review':
            row.remove('review_status');
          case 'foreign owner':
            row['employee_profile_id'] = historyId(99);
          case 'missing role':
            profile['employee_role'] = [];
        }
        fixture.handler = (_) async => HistoryHttpFixture.json(
          error == 'backend error'
              ? {'message': 'private fixture failure', 'code': '42501'}
              : [profile],
          error == 'backend error' ? 403 : 200,
        );
        await expectLater(
          fixture
              .repository(capabilities: reviewed.historyCapabilities)
              .load(HistoryWindow.sixMonths(historyNow)),
          throwsA(isA<HistoryFailure>()),
        );
        expect(fixture.requests, hasLength(1));
        expect(
          fixture.requests.single.url.queryParameters['select'],
          contains('employee_note,review_status'),
        );
      },
    );
  }
}
