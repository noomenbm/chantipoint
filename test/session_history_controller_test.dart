import 'dart:async';

import 'package:chantipoint/src/attendance/history/session_history.dart';
import 'package:chantipoint/src/attendance/history/session_history_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_history_fixture.dart';

void main() {
  for (final (now, expected) in [
    ('2026-10-21T16:00:00Z', '2026-04-21T04:00:00Z'),
    ('2026-08-31T16:00:00Z', '2026-02-28T05:00:00Z'),
    ('2024-08-31T16:00:00Z', '2024-02-29T05:00:00Z'),
    ('2026-01-31T16:00:00Z', '2025-07-31T04:00:00Z'),
    ('2026-05-01T02:00:00Z', '2025-10-30T04:00:00Z'),
    ('2026-09-08T16:00:00Z', '2026-03-08T05:00:00Z'),
    ('2027-05-01T16:00:00Z', '2026-11-01T04:00:00Z'),
  ]) {
    test('Montréal calendar boundary $now including DST/day clamping', () {
      final window = HistoryWindow.sixMonths(DateTime.parse(now));
      expect(window.fromUtc, DateTime.parse(expected));
      expect(window.untilUtc, DateTime.parse(now));
      expect(window.contains(window.fromUtc), isTrue);
      expect(window.contains(window.untilUtc), isFalse);
    });
  }
  test('serial pagination, retry same cursor/window, no duplicate concurrent loads', () async {
    final repo = FakeHistoryRepository();
    final controller = SessionHistoryController(repo, now: () => historyNow);
    addTearDown(controller.dispose);
    final reply = Completer<HistoryPage>();
    repo.handler = (_) => reply.future;
    final loading = controller.loadMore();
    await controller.loadMore();
    expect(repo.cursors.length, 1);
    expect(controller.loading, isTrue);
    final session = historySession(2);
    reply.complete(HistoryPage([session], HistoryCursor.of(session)));
    await loading;
    repo.handler = (_) async => throw const HistoryFailure();
    await controller.loadMore();
    expect(controller.sessions.length, 1);
    expect(controller.failure, isNotNull);
    repo.handler = (_) async => HistoryPage([historySession(1)], null);
    await controller.loadMore();
    await controller.loadMore();
    expect(controller.sessions.length, 2);
    expect(controller.hasMore, isFalse);
    expect(repo.cursors[1], same(repo.cursors[2]));
    expect(repo.windows.every((w) => identical(w, controller.window)), isTrue);
  });
  for (final dispose in [false, true]) {
    test(
      'late result suppressed after ${dispose ? 'disposal' : 'identity invalidation'}',
      () async {
        final repo = FakeHistoryRepository();
        final reply = Completer<HistoryPage>();
        repo.handler = (_) => reply.future;
        final controller = SessionHistoryController(
          repo,
          now: () => historyNow,
        );
        final loading = controller.loadMore();
        if (dispose) {
          controller.dispose();
        } else {
          repo.current = false;
        }
        reply.complete(HistoryPage([historySession(1)], null));
        await loading;
        expect(controller.sessions, isEmpty);
        expect(controller.loaded, isFalse);
        if (!dispose) controller.dispose();
      },
    );
  }
  test('first read failure is distinct from a loaded empty history', () async {
    final repo = FakeHistoryRepository()
      ..handler = (_) async => throw const HistoryFailure();
    final controller = SessionHistoryController(repo, now: () => historyNow);
    addTearDown(controller.dispose);
    await controller.loadMore();
    expect(controller.loaded, isFalse);
    expect(controller.failure, isNotNull);
    repo.handler = (_) async => HistoryPage([], null);
    await controller.loadMore();
    expect(controller.loaded, isTrue);
    expect(controller.failure, isNull);
  });
}
