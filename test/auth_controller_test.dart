import 'dart:async';

import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/auth_failure.dart';
import 'package:chantipoint/src/auth/auth_repository.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_repository.dart';
import 'support/test_users.dart';

void main() {
  test(
    'a terminated SDK session is checked before its event is delivered',
    () async {
      final repository = FakeAuthRepository();
      repository.onSignIn = () async => testEmployee;
      final controller = _controller(repository);
      await controller.signIn(email: 'marie@example.test', password: 'test');
      expect(controller.state.status, AuthStatus.signedOut);
      expect(controller.state.user, isNull);
      expect(controller.state.message, contains('expiré'));
    },
  );

  test('resume supersedes a lookup started before backgrounding', () async {
    final pending = Completer<AuthorizedUser?>();
    final repository = FakeAuthRepository(hasSession: true);
    repository.onRestore = () => pending.future;
    final controller = _controller(repository);
    final oldLookup = controller.restoreSession();
    repository.onRestore = null;
    repository.restoreFailure = const AuthFailure(AuthFailureKind.accessDenied);
    await controller.revalidateOnResume();
    pending.complete(testEmployee);
    await oldLookup;
    expect(repository.restoreCount, 2);
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.user, isNull);
  });

  test('user updates supersede pending authorization', () async {
    final pending = Completer<AuthorizedUser?>();
    final repository = FakeAuthRepository(hasSession: true);
    repository.onRestore = () => pending.future;
    final controller = _controller(repository);
    final oldLookup = controller.restoreSession();
    repository.onRestore = null;
    repository.restoreFailure = const AuthFailure(AuthFailureKind.accessDenied);
    repository.events.add(AuthSessionEvent.userUpdated);
    await Future<void>.delayed(Duration.zero);
    pending.complete(testEmployee);
    await oldLookup;
    expect(controller.state.status, AuthStatus.signedOut);
  });

  test('restoreSession authenticates a valid persisted session', () async {
    final repository = FakeAuthRepository(restoredUser: testAdministrator);
    final controller = _controller(repository);

    await controller.restoreSession();

    expect(controller.state.status, AuthStatus.authenticated);
    expect(controller.state.user, testAdministrator);
    expect(controller.state.user!.roles.length, 2);
  });

  test('restoreSession rejects an unauthorized persisted session', () async {
    final repository = FakeAuthRepository(
      restoreFailure: const AuthFailure(AuthFailureKind.accessDenied),
    );
    final controller = _controller(repository);

    await controller.restoreSession();

    expect(controller.state.status, AuthStatus.signedOut);
    expect(
      controller.state.message,
      "Ce compte n'est pas autorisé à accéder à ChantiPoint.",
    );
  });

  test('signIn exposes a sanitized message for credential failures', () async {
    final repository = FakeAuthRepository(
      signInFailure: const AuthFailure(AuthFailureKind.invalidCredentials),
    );
    final controller = _controller(repository);

    await controller.signIn(
      email: 'marie@example.test',
      password: 'wrong-password',
    );

    expect(controller.state.status, AuthStatus.signedOut);
    expect(
      controller.state.message,
      'Adresse courriel ou mot de passe invalide.',
    );
    expect(controller.state.message, isNot(contains('wrong-password')));
  });

  test('successful login authorizes the employee', () async {
    final repository = FakeAuthRepository(signInUser: testEmployee);
    final controller = _controller(repository);
    await controller.signIn(email: 'marie@example.test', password: 'test');
    expect(controller.state.status, AuthStatus.authenticated);
    expect(controller.state.user, testEmployee);
  });

  test('application authorization denial never displays content', () async {
    final repository = FakeAuthRepository(
      signInFailure: const AuthFailure(AuthFailureKind.accessDenied),
    );
    final controller = _controller(repository);
    await controller.signIn(email: 'marie@example.test', password: 'test');
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.user, isNull);
    expect(controller.state.message, contains("n'est pas autorisé"));
  });

  test(
    'temporary post-login failure preserves the session for retry',
    () async {
      final repository = FakeAuthRepository(
        hasSession: true,
        signInFailure: const AuthFailure(AuthFailureKind.network),
      );
      final controller = _controller(repository);
      await controller.signIn(email: 'marie@example.test', password: 'test');
      expect(controller.state.status, AuthStatus.accessBlocked);
      expect(controller.state.user, isNull);
      expect(repository.hasSession, isTrue);
      expect(repository.signOutCount, 0);

      repository.restoredUser = testEmployee;
      await controller.restoreSession();
      expect(controller.state.status, AuthStatus.authenticated);
    },
  );

  test(
    'temporary restoration failure hides content without logging out',
    () async {
      final repository = FakeAuthRepository(
        hasSession: true,
        restoreFailure: const AuthFailure(AuthFailureKind.serviceUnavailable),
      );
      final controller = _controller(repository);
      await controller.restoreSession();
      expect(controller.state.status, AuthStatus.accessBlocked);
      expect(controller.state.user, isNull);
      expect(repository.hasSession, isTrue);
      expect(repository.signOutCount, 0);
    },
  );

  test('a revoked profile loses access on revalidation', () async {
    final repository = FakeAuthRepository(restoredUser: testEmployee);
    final controller = _controller(repository);
    await controller.restoreSession();
    repository.restoreFailure = const AuthFailure(AuthFailureKind.accessDenied);
    await controller.restoreSession();
    expect(controller.state.status, AuthStatus.signedOut);
    expect(controller.state.user, isNull);
  });

  for (final event in [
    AuthSessionEvent.signedOut,
    AuthSessionEvent.sessionExpired,
    AuthSessionEvent.accessDenied,
  ]) {
    test(
      '$event immediately removes access and invalidates a pending lookup',
      () async {
        final pending = Completer<AuthorizedUser?>();
        final repository = FakeAuthRepository(restoredUser: testEmployee);
        final controller = _controller(repository);
        await controller.restoreSession();
        repository.onRestore = () => pending.future;
        final restoration = controller.restoreSession();
        repository.terminate(event);
        expect(controller.state.status, AuthStatus.signedOut);
        pending.complete(testEmployee);
        await restoration;
        expect(controller.state.status, AuthStatus.signedOut);
        expect(controller.state.user, isNull);
        if (event == AuthSessionEvent.sessionExpired) {
          expect(controller.state.message, contains('expiré'));
        }
      },
    );
  }

  test('logout success waits and prevents repeated actions', () async {
    final pending = Completer<void>();
    final repository = FakeAuthRepository(restoredUser: testEmployee);
    repository.onSignOut = () async {
      await pending.future;
      repository.terminate();
    };
    final controller = _controller(repository);
    await controller.restoreSession();
    final logout = controller.signOut();
    await controller.signOut();
    await controller.signIn(email: 'ignored', password: 'ignored');
    expect(controller.state.status, AuthStatus.signingOut);
    expect(repository.signOutCount, 1);
    expect(repository.signInCount, 0);
    pending.complete();
    await logout;
    expect(controller.state.status, AuthStatus.signedOut);
  });

  test(
    'logout failure with an active session remains visibly blocked',
    () async {
      final repository = FakeAuthRepository(
        restoredUser: testEmployee,
        signOutFailure: StateError('private backend information'),
      );
      final controller = _controller(repository);
      await controller.restoreSession();
      await controller.signOut();
      expect(controller.state.status, AuthStatus.accessBlocked);
      expect(controller.state.user, isNull);
      expect(controller.state.message, contains('toujours ouverte'));
      expect(controller.state.message, isNot(contains('private')));
      expect(repository.hasSession, isTrue);
      repository.signOutFailure = null;
      await controller.signOut();
      expect(controller.state.status, AuthStatus.signedOut);
    },
  );

  test(
    'logout failure after local removal reports unconfirmed server logout',
    () async {
      final repository = FakeAuthRepository(restoredUser: testEmployee);
      repository.onSignOut = () async {
        repository.terminate();
        throw const AuthFailure(AuthFailureKind.network);
      };
      final controller = _controller(repository);
      await controller.restoreSession();
      await controller.signOut();
      expect(controller.state.status, AuthStatus.signedOut);
      expect(controller.state.message, contains('n’a pas pu être confirmée'));
    },
  );

  test('successful signOut that leaves a session is not accepted', () async {
    final repository = FakeAuthRepository(restoredUser: testEmployee);
    repository.onSignOut = () async {};
    final controller = _controller(repository);
    await controller.restoreSession();
    await controller.signOut();
    expect(controller.state.status, AuthStatus.accessBlocked);
  });

  test('late login response cannot undo a newer logout', () async {
    final pending = Completer<AuthorizedUser>();
    final repository = FakeAuthRepository();
    repository.onSignIn = () => pending.future;
    final controller = _controller(repository);
    final login = controller.signIn(
      email: 'marie@example.test',
      password: 'test',
    );
    await controller.signOut();
    pending.complete(testEmployee);
    await login;
    expect(controller.state.status, AuthStatus.signedOut);
  });

  test('older restoration cannot overwrite a newer login', () async {
    final pending = Completer<AuthorizedUser?>();
    final repository = FakeAuthRepository(signInUser: testEmployee);
    repository.onRestore = () => pending.future;
    final controller = _controller(repository);
    final restoration = controller.restoreSession();
    await controller.signIn(email: 'marie@example.test', password: 'test');
    pending.complete(testAdministrator);
    await restoration;
    expect(controller.state.user, testEmployee);
  });

  test(
    'overlapping validations share a query and refresh does not poll',
    () async {
      final pending = Completer<AuthorizedUser?>();
      final repository = FakeAuthRepository(hasSession: true);
      repository.onRestore = () => pending.future;
      final controller = _controller(repository);
      final first = controller.restoreSession();
      final second = controller.restoreSession();
      expect(repository.restoreCount, 1);
      pending.complete(testEmployee);
      await Future.wait([first, second]);
      repository.events.add(AuthSessionEvent.tokenRefreshed);
      expect(repository.restoreCount, 1);
    },
  );

  test(
    'stream network errors are handled and invalidate pending content',
    () async {
      final pending = Completer<AuthorizedUser?>();
      final repository = FakeAuthRepository(hasSession: true);
      repository.onRestore = () => pending.future;
      final controller = _controller(repository);
      final restoration = controller.restoreSession();
      repository.events.addError(const AuthFailure(AuthFailureKind.network));
      expect(controller.state.status, AuthStatus.accessBlocked);
      pending.complete(testEmployee);
      await restoration;
      expect(controller.state.status, AuthStatus.accessBlocked);
      expect(repository.hasSession, isTrue);
    },
  );

  test('disposal cancels the listener and ignores late responses', () async {
    final pending = Completer<AuthorizedUser?>();
    final repository = FakeAuthRepository();
    repository.onRestore = () => pending.future;
    final controller = AuthController(repository);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final restoration = controller.restoreSession();
    expect(repository.events.hasListener, isTrue);
    controller.dispose();
    expect(repository.events.hasListener, isFalse);
    pending.complete(testEmployee);
    await restoration;
    expect(notifications, 1);
    await repository.events.close();
  });
}

AuthController _controller(FakeAuthRepository repository) {
  final controller = AuthController(repository);
  addTearDown(() async {
    controller.dispose();
    await repository.events.close();
  });
  return controller;
}
