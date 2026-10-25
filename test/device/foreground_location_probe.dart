// Isolated foreground activity probe. No Supabase, persistence, RPC or live UI.
import 'package:chantipoint/src/attendance/android_foreground_location.dart';
import 'package:chantipoint/src/attendance/attendance_action_capture.dart';
import 'package:chantipoint/src/attendance/foreground_location.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../support/fake_attendance_operation_ports.dart';
import '../support/journal_fixtures.dart';

const _control = MethodChannel('chantipoint/location_test_control');
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _control.setMethodCallHandler((call) async {
    if (call.method != 'run') return null;
    final scenario = call.arguments as String;
    if (scenario == 'acquire') {
      // Location only: no attendance intent, key, journal, auth or backend.
      // This scenario requires a real returned fix, unlike the allow policy test.
      final timer = Stopwatch()..start();
      final evidence = await ForegroundLocationService(
        const AndroidForegroundLocation(),
      ).acquire();
      timer.stop();
      final latitude = evidence.latitude;
      final longitude = evidence.longitude;
      final hasFix =
          evidence.result == LocationAcquisitionResult.fix &&
          latitude != null &&
          latitude.isFinite &&
          latitude >= -90 &&
          latitude <= 90 &&
          longitude != null &&
          longitude.isFinite &&
          longitude >= -180 &&
          longitude <= 180 &&
          evidence.observedAt != null;
      final accuracy = evidence.accuracyMeters;
      // Never render/log/return coordinates, fix time or raw Location objects.
      await _control.invokeMethod<void>('finish', {
        'passed': hasFix,
        'diagnostic':
            'permission=${evidence.permission?.sqlValue} '
            'services_enabled=${evidence.servicesEnabled} '
            'result=${evidence.result?.sqlValue} '
            'provider=${evidence.provider?.sqlValue} has_fix=$hasFix '
            'accuracy_available=${accuracy != null && accuracy.isFinite && accuracy >= 0} '
            'elapsed_ms=${timer.elapsedMilliseconds}',
      });
      return null;
    }
    var passed = false;
    var diagnostic = 'probe_unavailable';
    final capture = AttendanceActionCapture(
      location: ForegroundLocationService(const AndroidForegroundLocation()),
      clock: const SystemAttendanceActionClock(),
      keys: SecureAttendanceActionKeys(),
    );
    try {
      final issuer = FictionalAttendanceIssuer(
        journalBinding(environment: 'c4-runtime-fictional'),
      );
      final result = await capture.checkIn(
        context: issuer.context(),
        siteDescription: 'Fictional C4 fixture',
      );
      final action = result.action;
      final command = action?.command;
      if (command != null) {
        final p = command.parameters;
        final permission = p['p_permission'];
        final locationResult = p['p_location_result'];
        final hasFix =
            p['p_latitude'] != null &&
            p['p_longitude'] != null &&
            p['p_location_observed_at'] != null;
        final available = [
          'fix',
          'timeout',
          'unavailable',
        ].contains(locationResult);
        passed = switch (scenario) {
          'allow' =>
            ['precise', 'approximate'].contains(permission) && available,
          'approximate' => permission == 'approximate' && available,
          'deny' =>
            permission == 'denied' &&
                locationResult == 'permission_denied' &&
                !hasFix,
          'services_off' =>
            p['p_services_enabled'] == false &&
                locationResult == 'location_services_disabled' &&
                !hasFix,
          _ => false,
        };
        if (locationResult == 'fix' && !hasFix) passed = false;
        // Safe enums/booleans only. Do not log coordinates, time, key or inputs.
        diagnostic =
            'permission=$permission result=$locationResult provider=${p['p_provider']} has_fix=$hasFix';
      }
      await action?.abandon();
    } catch (_) {
      diagnostic = 'probe_failed';
    }
    await capture.close();
    await _control.invokeMethod<void>('finish', {
      'passed': passed,
      'diagnostic': diagnostic,
    });
    return null;
  });
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('C4 isolated validation')),
    ),
  );
}
