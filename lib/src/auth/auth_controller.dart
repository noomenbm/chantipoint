import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_failure.dart';
import 'auth_repository.dart';
import 'authorized_user.dart';

enum AuthStatus {
  checkingSession,
  signedOut,
  authenticating,
  authenticated,
  accessBlocked,
  signingOut,
}

class AuthViewState {
  const AuthViewState({required this.status, this.user, this.message});

  const AuthViewState.checkingSession()
    : this(status: AuthStatus.checkingSession);
  const AuthViewState.signedOut({String? message})
    : this(status: AuthStatus.signedOut, message: message);
  const AuthViewState.authenticating()
    : this(status: AuthStatus.authenticating);
  const AuthViewState.authenticated(AuthorizedUser user)
    : this(status: AuthStatus.authenticated, user: user);

  final AuthStatus status;
  final AuthorizedUser? user;
  final String? message;
}

class AuthController extends ChangeNotifier {
  AuthController(this._repository) {
    _subscription = _repository.sessionChanges.listen(
      _onSessionEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (_disposed || _signingOut) return;
        ++_operation;
        _validation = null;
        _showFailure(error);
      },
    );
  }

  final AuthRepository _repository;
  late final StreamSubscription<AuthSessionEvent> _subscription;
  AuthViewState _state = const AuthViewState.checkingSession();
  AuthViewState get state => _state;
  // Read-only lifecycle observations for application-owned attendance authority.
  bool get isDisposed => _disposed;
  bool usesRepository(AuthRepository repository) =>
      identical(_repository, repository);

  int _operation = 0;
  bool _disposed = false;
  bool _signingOut = false;
  Future<void>? _validation;

  Future<void> revalidateOnResume() {
    if (_disposed || _signingOut) return Future.value();
    // A lookup started before backgrounding may contain pre-revocation data.
    // Resume must supersede it, including a pending post-login lookup.
    ++_operation;
    _validation = null;
    _setState(const AuthViewState.checkingSession());
    return restoreSession();
  }

  // Resume and refresh events can overlap. Share a current authorization lookup.
  Future<void> restoreSession() {
    if (_disposed ||
        _signingOut ||
        _state.status == AuthStatus.authenticating) {
      return Future.value();
    }
    if (_validation != null) return _validation!;

    final operation = ++_operation;
    _setState(const AuthViewState.checkingSession());
    late final Future<void> validation;
    validation = _restoreSession(operation).whenComplete(() {
      if (identical(_validation, validation)) _validation = null;
    });
    _validation = validation;
    return validation;
  }

  Future<void> _restoreSession(int operation) async {
    try {
      final user = await _repository.restoreSession();
      if (!_isCurrent(operation)) return;
      if (user != null && !_repository.hasSession) {
        _showFailure(const AuthFailure(AuthFailureKind.sessionExpired));
        return;
      }
      _setState(
        user == null
            ? const AuthViewState.signedOut()
            : AuthViewState.authenticated(user),
      );
    } catch (error) {
      if (_isCurrent(operation)) _showFailure(error);
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    if (_disposed ||
        _signingOut ||
        _state.status == AuthStatus.authenticating) {
      return;
    }

    final operation = ++_operation;
    _validation = null;
    _setState(const AuthViewState.authenticating());
    try {
      final user = await _repository.signIn(email: email, password: password);
      if (_isCurrent(operation)) {
        if (_repository.hasSession) {
          _setState(AuthViewState.authenticated(user));
        } else {
          _showFailure(const AuthFailure(AuthFailureKind.sessionExpired));
        }
      }
    } catch (error) {
      if (_isCurrent(operation)) _showFailure(error);
    }
  }

  Future<void> signOut() async {
    if (_disposed || _signingOut) return;
    final operation = ++_operation;
    _validation = null;
    _signingOut = true;
    _setState(const AuthViewState(status: AuthStatus.signingOut));
    try {
      await _repository.signOut();
      if (!_isCurrent(operation)) return;
      if (_repository.hasSession) {
        _showLogoutFailure();
      } else {
        _setState(const AuthViewState.signedOut());
      }
    } catch (_) {
      if (!_isCurrent(operation)) return;
      if (_repository.hasSession) {
        _showLogoutFailure();
      } else {
        _setState(
          const AuthViewState.signedOut(
            message:
                'Vous êtes déconnecté de cet appareil. '
                'La déconnexion du serveur n’a pas pu être confirmée.',
          ),
        );
      }
    } finally {
      _signingOut = false;
    }
  }

  void _showLogoutFailure() {
    _setState(
      const AuthViewState(
        status: AuthStatus.accessBlocked,
        message:
            'Déconnexion impossible. Votre session est toujours ouverte. '
            'Réessayez.',
      ),
    );
  }

  void _onSessionEvent(AuthSessionEvent event) {
    if (_disposed || _signingOut) return;
    switch (event) {
      case AuthSessionEvent.signedOut:
      case AuthSessionEvent.sessionExpired:
      case AuthSessionEvent.accessDenied:
        ++_operation;
        _validation = null;
        final message = switch (event) {
          AuthSessionEvent.sessionExpired => const AuthFailure(
            AuthFailureKind.sessionExpired,
          ).userMessage,
          AuthSessionEvent.accessDenied => const AuthFailure(
            AuthFailureKind.accessDenied,
          ).userMessage,
          _ => null,
        };
        _setState(
          AuthViewState(
            status: _repository.hasSession
                ? AuthStatus.accessBlocked
                : AuthStatus.signedOut,
            message: message,
          ),
        );
      case AuthSessionEvent.signedIn:
        if (_state.status == AuthStatus.authenticating) return;
        unawaited(revalidateOnResume());
      case AuthSessionEvent.userUpdated:
        unawaited(revalidateOnResume());
      case AuthSessionEvent.tokenRefreshed:
        // A refresh alone does not change roles. Retry a blocked lookup only.
        if (_state.status == AuthStatus.accessBlocked) {
          unawaited(restoreSession());
        }
    }
  }

  void _showFailure(Object error) {
    final failure = error is AuthFailure
        ? error
        : const AuthFailure(AuthFailureKind.unknown);
    _setState(
      AuthViewState(
        status: _repository.hasSession
            ? AuthStatus.accessBlocked
            : AuthStatus.signedOut,
        message: failure.userMessage,
      ),
    );
  }

  bool _isCurrent(int operation) => !_disposed && operation == _operation;

  void _setState(AuthViewState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_operation;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
