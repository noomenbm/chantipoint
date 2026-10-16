import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/config/business_time_config.dart';
import 'package:chantipoint/src/time/business_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  test(
    'configured Montreal alias resolves in the initialized IANA database',
    () {
      expect(businessTimeZoneId, 'America/Montreal');
      expect(businessTimeLocation().name, 'America/Montreal');
      expect(tz.getLocation('America/Montreal').name, 'America/Montreal');
    },
  );

  test('spring-forward skips the missing local hour using IANA rules', () {
    expect(
      formatBusinessTime(DateTime.utc(2026, 3, 8, 6, 59)),
      '08/03/2026 à 01:59 (heure de Montréal, UTC−05:00)',
    );
    expect(
      formatBusinessTime(DateTime.utc(2026, 3, 8, 7)),
      '08/03/2026 à 03:00 (heure de Montréal, UTC−04:00)',
    );
  });

  test('fall-back changes the offset at the repeated hour boundary', () {
    expect(
      formatBusinessTime(DateTime.utc(2026, 11, 1, 5, 59)),
      '01/11/2026 à 01:59 (heure de Montréal, UTC−04:00)',
    );
    expect(
      formatBusinessTime(DateTime.utc(2026, 11, 1, 6)),
      '01/11/2026 à 01:00 (heure de Montréal, UTC−05:00)',
    );
  });

  test('UTC and Montreal dates can differ without changing the instant', () {
    final instant = DateTime.utc(2026, 10, 16, 3, 45);
    final local = toBusinessTime(instant);
    expect(local.year, 2026);
    expect(local.month, 10);
    expect(local.day, 15);
    expect(local.toUtc(), instant);
    expect(
      formatBusinessTime(instant),
      '15/10/2026 à 23:45 (heure de Montréal, UTC−04:00)',
    );
    expect(instant.toIso8601String(), '2026-10-16T03:45:00.000Z');
  });

  test(
    'Vancouver uses the same conversion and formatting with an explicit ID',
    () {
      final winter = DateTime.utc(2026, 1, 15, 15);
      final summer = DateTime.utc(2026, 7, 15, 15);
      expect(toBusinessTime(winter, timeZoneId: 'America/Vancouver').hour, 7);
      expect(
        toBusinessTime(summer, timeZoneId: 'America/Vancouver').timeZoneOffset,
        const Duration(hours: -7),
      );
      expect(
        formatBusinessTime(winter, timeZoneId: 'America/Vancouver'),
        '15/01/2026 à 07:00 (America/Vancouver, UTC−08:00)',
      );
      expect(
        formatBusinessTime(
          summer,
          timeZoneId: 'America/Vancouver',
          displayLabel: 'heure de Vancouver',
        ),
        '15/07/2026 à 08:00 (heure de Vancouver, UTC−07:00)',
      );
      // An explicit alternate zone never changes the company's default.
      expect(businessTimeLocation().name, 'America/Montreal');
    },
  );

  test('display labels do not select timezone calculation rules', () {
    final instant = DateTime.utc(2026, 1, 15, 15);
    expect(
      formatBusinessTime(instant, displayLabel: 'heure de l’entreprise'),
      '15/01/2026 à 10:00 (heure de l’entreprise, UTC−05:00)',
    );
  });

  test('invalid timezone identifiers fail without a silent fallback', () {
    expect(
      () => formatBusinessTime(
        DateTime.utc(2026, 1, 15),
        timeZoneId: 'Invalid/Region',
      ),
      throwsA(isA<tz.LocationNotFoundException>()),
    );
  });

  test(
    'display preserves UTC session timestamps and elapsed time across DST',
    () {
      final session = WorkSession.fromJson({
        'id': 'session-dst',
        'location_context': 'factory',
        'lifecycle_status': 'closed_manual',
        'started_at': '2026-11-01T05:45:00+00:00',
        'ended_at': '2026-11-01T06:15:00+00:00',
      });
      expect(
        formatBusinessTime(session.startedAt),
        '01/11/2026 à 01:45 (heure de Montréal, UTC−04:00)',
      );
      expect(
        formatBusinessTime(session.endedAt!),
        '01/11/2026 à 01:15 (heure de Montréal, UTC−05:00)',
      );
      expect(session.startedAt.isUtc, isTrue);
      expect(session.endedAt!.isUtc, isTrue);
      expect(session.startedAt.toIso8601String(), '2026-11-01T05:45:00.000Z');
      expect(session.endedAt!.toIso8601String(), '2026-11-01T06:15:00.000Z');
      expect(
        session.endedAt!.difference(session.startedAt),
        const Duration(minutes: 30),
      );
    },
  );
}
