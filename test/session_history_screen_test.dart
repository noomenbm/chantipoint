import 'dart:async';

import 'package:chantipoint/src/app.dart';
import 'package:chantipoint/src/attendance/attendance_controller.dart';
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/history/session_history.dart';
import 'package:chantipoint/src/attendance/history/session_history_controller.dart';
import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:chantipoint/src/ui/session_history_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance.dart';
import 'support/fake_auth_repository.dart';
import 'support/session_history_fixture.dart';

void main() {
  Future<SessionHistoryController> screen(
    WidgetTester tester,
    FakeHistoryRepository repo,
  ) async {
    final controller = SessionHistoryController(repo, now: () => historyNow);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionHistoryScreen(controller: controller, onBack: () {}),
        ),
      ),
    );
    return controller;
  }

  testWidgets('loading then legitimate empty, with honest capability notice', (
    tester,
  ) async {
    final reply = Completer<HistoryPage>();
    final repo = FakeHistoryRepository()..handler = (_) => reply.future;
    final controller = await screen(tester, repo);
    final load = controller.loadMore();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Aucune session pour cette période.'), findsNothing);
    reply.complete(HistoryPage([], null));
    await load;
    await tester.pumpAndSettle();
    expect(find.text('Aucune session pour cette période.'), findsOneWidget);
    expect(find.textContaining('ne sont pas disponibles'), findsOneWidget);
    expect(find.textContaining('aucune note enregistrée'), findsNothing);
  });
  testWidgets('French error retry never displays an empty success', (
    tester,
  ) async {
    final repo = FakeHistoryRepository()
      ..handler = (_) async => throw Exception('private body');
    final controller = await screen(tester, repo);
    await controller.loadMore();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-error')), findsOneWidget);
    expect(find.textContaining('private body'), findsNothing);
    expect(find.text('Aucune session pour cette période.'), findsNothing);
    repo.handler = (_) async => HistoryPage([], null);
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(find.text('Aucune session pour cette période.'), findsOneWidget);
  });
  testWidgets(
    'details show canonical note/review and Montréal times on a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = FakeHistoryRepository(
        capabilities: const HistoryCapabilities(notes: true, review: true),
      );
      repo.handler = (_) async => HistoryPage([
        historySession(
          1,
          note: '  Équipement réparé  ',
          review: 'anomaly_open',
        ),
      ], null);
      final controller = await screen(tester, repo);
      await controller.loadMore();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(ExpansionTile));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(find.text('Note :   Équipement réparé  '), findsOneWidget);
      expect(find.text('Révision : À examiner'), findsOneWidget);
      expect(
        find.textContaining('Entrée : 15/10/2026 à 10:00'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Sortie : 15/10/2026 à 21:00'),
        findsOneWidget,
      );
      expect(
        find.text('Description du chantier : Atelier exemple'),
        findsOneWidget,
      );
      expect(find.text('Lieu : Chantier extérieur'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('repeated fall-back clock times display different UTC offsets', (
    tester,
  ) async {
    final repo = FakeHistoryRepository();
    repo.handler = (_) async => HistoryPage([
      WorkSession(
        id: 'later',
        locationContext: 'factory',
        lifecycleStatus: 'closed_manual',
        startedAt: DateTime.parse('2026-11-01T06:30:00Z'),
        endedAt: DateTime.parse('2026-11-01T08:00:00Z'),
      ),
      WorkSession(
        id: 'earlier',
        locationContext: 'factory',
        lifecycleStatus: 'closed_manual',
        startedAt: DateTime.parse('2026-11-01T05:30:00Z'),
        endedAt: DateTime.parse('2026-11-01T06:00:00Z'),
      ),
    ], null);
    final controller = await screen(tester, repo);
    await controller.loadMore();
    await tester.pumpAndSettle();
    expect(
      find.text('01/11/2026 à 01:30 (heure de Montréal, UTC−05:00)'),
      findsOneWidget,
    );
    expect(
      find.text('01/11/2026 à 01:30 (heure de Montréal, UTC−04:00)'),
      findsOneWidget,
    );
  });
  testWidgets('load-more error preserves rows and retries same page', (
    tester,
  ) async {
    final repo = FakeHistoryRepository();
    final session = historySession(2);
    repo.handler = (_) async =>
        HistoryPage([session], HistoryCursor.of(session));
    final controller = await screen(tester, repo);
    await controller.loadMore();
    await tester.pumpAndSettle();
    repo.handler = (_) async => throw const HistoryFailure();
    await tester.ensureVisible(find.text('Charger plus'));
    await tester.tap(find.text('Charger plus'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsOneWidget);
    repo.handler = (_) async => HistoryPage([historySession(1)], null);
    await tester.ensureVisible(find.text('Réessayer'));
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpansionTile), findsNWidgets(2));
    expect(repo.cursors[1], same(repo.cursors[2]));
  });
  testWidgets(
    'normal signed-in navigation preserves attendance panel and removes history at logout initiation',
    (tester) async {
      final authRepo = FakeAuthRepository(restoredUser: historyEmployee);
      final auth = AuthController(authRepo);
      final repo = FakeHistoryRepository();
      final attendance = FakeAttendanceRepository();
      var attendanceCreations = 0;
      await tester.pumpWidget(
        ChantiPointApp(
          authController: auth,
          attendanceControllerFactory: (user) {
            attendanceCreations++;
            return AttendanceController(attendance, MemoryCommandStore(), user);
          },
          historyRepositoryFactory: (user, current) => repo..guard = current,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Historique'));
      await tester.pumpAndSettle();
      expect(find.text('Aucune session pour cette période.'), findsOneWidget);
      await tester.tap(find.text('Accueil'));
      await tester.pumpAndSettle();
      expect(find.text('Pointer une entrée à l’usine'), findsOneWidget);
      expect(attendanceCreations, 1);
      await tester.tap(find.text('Historique'));
      await tester.pumpAndSettle();
    expect(repo.cursors.length, 2); // Explicit revisit starts a fresh snapshot.
      final signOut = Completer<void>();
      authRepo.onSignOut = () => signOut.future;
      await tester.tap(find.byTooltip('Se déconnecter'));
      await tester.pump();
      expect(repo.isCurrent, isFalse);
      expect(find.text('Historique'), findsNothing);
      expect(find.text('Déconnexion en cours…'), findsOneWidget);
      authRepo.hasSession = false;
      signOut.complete();
      await tester.pumpAndSettle();
      expect(find.text('Connexion'), findsOneWidget);
      expect(attendance.submitted, isEmpty);
      await authRepo.events.close();
    },
  );
  testWidgets(
    'late history after same-user relogin cannot restore old details',
    (tester) async {
      final authRepo = FakeAuthRepository(
        restoredUser: historyEmployee,
        signInUser: historyEmployee,
      );
      final auth = AuthController(authRepo);
      final repo = FakeHistoryRepository();
      final reply = Completer<HistoryPage>();
      repo.handler = (_) => reply.future;
      await tester.pumpWidget(
        ChantiPointApp(
          authController: auth,
          historyRepositoryFactory: (user, current) => repo..guard = current,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Historique'));
      await tester.pump();
      await auth.signOut();
      await auth.signIn(email: 'fictional@example.test', password: 'fictional');
      await tester.pumpAndSettle();
      reply.complete(
        HistoryPage([historySession(1, note: 'Old private fixture')], null),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Old private fixture'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      await authRepo.events.close();
    },
  );
  testWidgets('administrator without employee role has no history entry', (
    tester,
  ) async {
    const admin = AuthorizedUser(
      profileId: 'admin',
      companyId: 'company',
      displayName: 'Admin',
      email: '',
      roles: {AuthorizedRole.administrator},
    );
    final authRepo = FakeAuthRepository(restoredUser: admin);
    var reads = 0;
    await tester.pumpWidget(
      ChantiPointApp(
        authController: AuthController(authRepo),
        historyRepositoryFactory: (user, current) {
          reads++;
          return FakeHistoryRepository();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Historique'), findsNothing);
    expect(reads, 0);
    await authRepo.events.close();
  });
}
