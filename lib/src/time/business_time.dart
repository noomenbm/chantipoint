import 'package:timezone/data/latest_all.dart' as data;
import 'package:timezone/timezone.dart' as tz;

import '../config/business_time_config.dart';

bool _initialized = false;

/// Resolve IANA rules for display and future business calendar boundaries.
tz.Location businessTimeLocation({String timeZoneId = businessTimeZoneId}) {
  if (!_initialized) {
    // The default database omits backward-compatible aliases such as Montreal.
    data.initializeTimeZones();
    _initialized = true;
  }
  return tz.getLocation(timeZoneId);
}

/// Return a business-time view of an instant without changing its UTC value.
tz.TZDateTime toBusinessTime(
  DateTime instant, {
  String timeZoneId = businessTimeZoneId,
}) => tz.TZDateTime.from(
  instant.toUtc(),
  businessTimeLocation(timeZoneId: timeZoneId),
);

String formatBusinessTime(
  DateTime instant, {
  String timeZoneId = businessTimeZoneId,
  String? displayLabel,
}) {
  final time = toBusinessTime(instant, timeZoneId: timeZoneId);
  final label =
      displayLabel ??
      (timeZoneId == businessTimeZoneId ? businessTimeZoneLabel : timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '−' : '+';
  final hours = offset.inHours.abs().toString().padLeft(2, '0');
  final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
  return '${two(time.day)}/${two(time.month)}/${time.year} à ${two(time.hour)}:${two(time.minute)} ($label, UTC$sign$hours:$minutes)';
}
