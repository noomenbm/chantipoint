import 'dart:async';

import 'package:chantipoint/src/app.dart';
import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/auth_failure.dart';
import 'package:chantipoint/src/auth/auth_repository.dart';
import 'package:chantipoint/src/config/supabase_environment_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_repository.dart';
import 'support/test_users.dart';

void main() {
  for (final reason in ['disabled profile', 'revoked roles']) {
    testWidgets('removes authenticated content for $reason on app resume', (
      tester,
    ) async {
      final repository = FakeAuthRepository(restoredUser: testEmployee);
      await _pumpApp(tester, repository);
      expect(find.text('Bonjour, Marie Tremblay'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      repository.restoreFailure = const AuthFailure(
        AuthFailureKind.accessDenied,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(repository.restoreCount, 2);
      expect(find.text('Bonjour, Marie Tremblay'), findsNothing);
      expect(find.textContaining("n'est pas autorisé"), findsOneWidget);
    });
  }

  testWidgets(
    'temporary resume failure offers retry without exposing content',
    (tester) async {
      final repository = FakeAuthRepository(restoredUser: testEmployee);
      await _pumpApp(tester, repository);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      repository.restoreFailure = const AuthFailure(AuthFailureKind.network);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Bonjour, Marie Tremblay'), findsNothing);
      expect(find.text('Réessayer'), findsOneWidget);
      expect(repository.hasSession, isTrue);
      repository.restoreFailure = null;
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(find.text('Bonjour, Marie Tremblay'), findsOneWidget);
    },
  );

  testWidgets(
    'Supabase session expiration immediately removes the home screen',
    (tester) async {
      final repository = FakeAuthRepository(restoredUser: testEmployee);
      await _pumpApp(tester, repository);
      repository.terminate(AuthSessionEvent.sessionExpired);
      await tester.pumpAndSettle();
      expect(find.text('Espace authentifié'), findsNothing);
      expect(find.textContaining('expiré'), findsOneWidget);
    },
  );

  testWidgets('logout processing removes actions and failure permits retry', (
    tester,
  ) async {
    final pending = Completer<void>();
    final repository = FakeAuthRepository(restoredUser: testEmployee);
    repository.onSignOut = () => pending.future;
    await _pumpApp(tester, repository);
    await tester.tap(find.byTooltip('Se déconnecter'));
    await tester.pump();
    expect(find.text('Déconnexion en cours…'), findsOneWidget);
    expect(find.byTooltip('Se déconnecter'), findsNothing);
    pending.completeError(StateError('private error'));
    await tester.pumpAndSettle();
    expect(find.textContaining('toujours ouverte'), findsOneWidget);
    expect(find.text('Espace authentifié'), findsNothing);
    repository.onSignOut = null;
    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();
    expect(find.text('Se connecter'), findsOneWidget);
  });

  testWidgets('disposing the app cancels session and lifecycle listeners', (
    tester,
  ) async {
    final repository = FakeAuthRepository(restoredUser: testEmployee);
    await _pumpApp(tester, repository);
    expect(repository.events.hasListener, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(repository.events.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(repository.restoreCount, 1);
  });

  testWidgets('shows the French login form without public registration', (
    tester,
  ) async {
    final repository = FakeAuthRepository();
    await _pumpApp(tester, repository);

    expect(find.text('Adresse courriel'), findsOneWidget);
    expect(find.text('Mot de passe'), findsOneWidget);
    expect(find.text('Se connecter'), findsOneWidget);
    expect(find.textContaining('Créer un compte'), findsNothing);
  });

  testWidgets('validates required login fields', (tester) async {
    final repository = FakeAuthRepository();
    await _pumpApp(tester, repository);

    await tester.tap(find.text('Se connecter'));
    await tester.pump();

    expect(find.text('Entrez une adresse courriel.'), findsOneWidget);
    expect(find.text('Entrez un mot de passe.'), findsOneWidget);
    expect(repository.signInCount, 0);
  });

  testWidgets('logs in and shows the authenticated placeholder', (
    tester,
  ) async {
    final repository = FakeAuthRepository(signInUser: testEmployee);
    await _pumpApp(tester, repository);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Adresse courriel'),
      ' marie@example.test ',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mot de passe'),
      'not-a-real-password',
    );
    await tester.tap(find.text('Se connecter'));
    await tester.pumpAndSettle();

    expect(repository.lastEmail, 'marie@example.test');
    expect(repository.lastPassword, 'not-a-real-password');
    expect(find.text('Bonjour, Marie Tremblay'), findsOneWidget);
    expect(find.text('Employé'), findsOneWidget);

    await tester.tap(find.byTooltip('Se déconnecter'));
    await tester.pumpAndSettle();

    expect(repository.signOutCalled, isTrue);
    expect(find.text('Se connecter'), findsOneWidget);
  });

  testWidgets('shows sanitized authentication failures', (tester) async {
    final repository = FakeAuthRepository(
      signInFailure: const AuthFailure(AuthFailureKind.invalidCredentials),
    );
    await _pumpApp(tester, repository);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Adresse courriel'),
      'marie@example.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mot de passe'),
      'bad-password',
    );
    await tester.tap(find.text('Se connecter'));
    await tester.pumpAndSettle();

    final errorFinder = find.text('Adresse courriel ou mot de passe invalide.');
    expect(errorFinder, findsOneWidget);
    expect(
      tester.widget<Text>(errorFinder).data,
      isNot(contains('bad-password')),
    );
  });

  testWidgets('shows missing Supabase configuration clearly', (tester) async {
    await tester.pumpWidget(
      const ConfigurationRequiredApp(
        config: SupabaseEnvironmentConfig(
          url: '',
          publishableKey: '',
          missingValues: ['SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY'],
          keySource: 'SUPABASE_PUBLISHABLE_KEY',
        ),
      ),
    );

    expect(find.text('Configuration requise'), findsOneWidget);
    expect(
      find.text('Variables manquantes: SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY'),
      findsOneWidget,
    );
  });
}

Future<void> _pumpApp(
  WidgetTester tester,
  FakeAuthRepository repository,
) async {
  final controller = AuthController(repository);
  await tester.pumpWidget(ChantiPointApp(authController: controller));
  await tester.pumpAndSettle();
}
