import 'authorized_user.dart';

enum AuthSessionEvent {
  signedIn,
  signedOut,
  sessionExpired,
  accessDenied,
  tokenRefreshed,
  userUpdated,
}

abstract class AuthRepository {
  bool get hasSession;

  Stream<AuthSessionEvent> get sessionChanges;

  Future<AuthorizedUser?> restoreSession();

  Future<AuthorizedUser> signIn({
    required String email,
    required String password,
  });

  Future<void> signOut();
}
