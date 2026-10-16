import 'package:chantipoint/src/app.dart';
import 'package:chantipoint/src/attendance/attendance_controller.dart';
import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance.dart';
import 'support/fake_auth_repository.dart';
import 'support/test_users.dart';

void main() {
  testWidgets(
    'employee sees factory check-in, server time, and checkout confirmation',
    (tester) async {
      final repository = FakeAttendanceRepository();
      final store = MemoryCommandStore();
      final auth = FakeAuthRepository(restoredUser: testEmployee);
      await tester.pumpWidget(
        ChantiPointApp(
          authController: AuthController(auth),
          attendanceControllerFactory: (user) =>
              AttendanceController(repository, store, user),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Aucune session active.'), findsOneWidget);
      final checkIn = find.text('Pointer une entrée à l’usine');
      await tester.ensureVisible(checkIn);
      await tester.tap(checkIn);
      await tester.pumpAndSettle();
      expect(find.text('Session active — À l’usine'), findsOneWidget);
      expect(
        find.textContaining(
          '15/10/2026 à 10:00 (heure de Montréal, UTC−04:00)',
        ),
        findsOneWidget,
      );
      final checkOut = find.text('Pointer une sortie');
      await tester.ensureVisible(checkOut);
      await tester.tap(checkOut);
      await tester.pumpAndSettle();
      expect(find.text('Session terminée — À l’usine'), findsOneWidget);
      expect(
        find.textContaining('Sortie : 15/10/2026 à 18:00'),
        findsOneWidget,
      );
      expect(find.text('Aucune session active.'), findsOneWidget);
    },
  );

  testWidgets(
    'admin-only account never receives employee controls or a controller',
    (tester) async {
      const admin = AuthorizedUser(
        profileId: 'admin',
        companyId: 'company',
        displayName: 'Admin',
        email: '',
        roles: {AuthorizedRole.administrator},
      );
      var creations = 0;
      final repository = FakeAttendanceRepository();
      final auth = FakeAuthRepository(restoredUser: admin);
      await tester.pumpWidget(
        ChantiPointApp(
          authController: AuthController(auth),
          attendanceControllerFactory: (user) {
            creations++;
            return AttendanceController(repository, MemoryCommandStore(), user);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(creations, 0);
      expect(find.text('Pointer une entrée à l’usine'), findsNothing);
      expect(find.textContaining('réservé aux comptes'), findsOneWidget);
    },
  );

  testWidgets('resume reauthorizes and reloads server session changes', (
    tester,
  ) async {
    final repository = FakeAttendanceRepository()..active = session();
    final store = MemoryCommandStore();
    final auth = FakeAuthRepository(restoredUser: testEmployee);
    var creations = 0;
    await tester.pumpWidget(
      ChantiPointApp(
        authController: AuthController(auth),
        attendanceControllerFactory: (user) {
          creations++;
          return AttendanceController(repository, store, user);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Session active — À l’usine'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    repository.active = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(creations, 2);
    expect(find.text('Session active — À l’usine'), findsNothing);
    expect(find.text('Aucune session active.'), findsOneWidget);
  });

  testWidgets('small smartphone layout scrolls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = FakeAuthRepository(restoredUser: testEmployee);
    await tester.pumpWidget(
      ChantiPointApp(
        authController: AuthController(auth),
        attendanceControllerFactory: (user) => AttendanceController(
          FakeAttendanceRepository(),
          MemoryCommandStore(),
          user,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Pointer une entrée à l’usine'));
    expect(tester.takeException(), isNull);
  });
}
