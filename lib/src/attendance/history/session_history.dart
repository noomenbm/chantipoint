import 'package:timezone/timezone.dart' as tz;

import '../../auth/authorized_user.dart';
import '../../time/business_time.dart';
import '../attendance_models.dart';

/// Deployment-approved SELECT capabilities, never inferred from failed queries.
/// Both optional fields stay off in the hosted legacy composition until verified.
final class HistoryCapabilities {
  const HistoryCapabilities({this.notes = false, this.review = false});
  final bool notes;
  final bool review;
}

final class HistoryFailure implements Exception {
  const HistoryFailure();
  String get message =>
      'Impossible de charger l’historique. Vérifiez votre connexion ou votre accès, puis réessayez.';
  @override
  String toString() => 'HistoryFailure';
}

/// Frozen, half-open UTC interval derived from the configured business calendar.
final class HistoryWindow {
  HistoryWindow.sixMonths(DateTime now) {
    final local = toBusinessTime(now);
    final first = tz.TZDateTime(local.location, local.year, local.month - 6);
    final lastDay = tz.TZDateTime(
      first.location,
      first.year,
      first.month + 1,
      0,
    ).day;
    fromUtc = tz.TZDateTime(
      first.location,
      first.year,
      first.month,
      local.day > lastDay ? lastDay : local.day,
    ).toUtc();
    untilUtc = now.toUtc();
  }
  late final DateTime fromUtc;
  late final DateTime untilUtc;
  bool contains(DateTime start) =>
      !start.isBefore(fromUtc) && start.isBefore(untilUtc);
}

final class HistoryCursor {
  const HistoryCursor(this.startedAt, this.id);
  final DateTime startedAt;
  final String id;
  factory HistoryCursor.of(WorkSession session) =>
      HistoryCursor(session.startedAt, session.id);
  bool precedes(HistoryCursor next) =>
      next.startedAt.isBefore(startedAt) ||
      (next.startedAt == startedAt && next.id.compareTo(id) < 0);
}

final class HistoryPage {
  HistoryPage(List<WorkSession> sessions, this.next)
    : sessions = List.unmodifiable(sessions);
  final List<WorkSession> sessions;
  final HistoryCursor? next;
}

abstract interface class SessionHistoryRepository {
  HistoryCapabilities get capabilities;
  bool get isCurrent;
  Future<HistoryPage> load(HistoryWindow window, {HistoryCursor? before});
}

typedef SessionHistoryRepositoryFactory = SessionHistoryRepository Function(
  AuthorizedUser user,
  bool Function() isCurrent,
);
