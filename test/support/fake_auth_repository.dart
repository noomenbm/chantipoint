import 'dart:async';

import 'package:chantipoint/src/auth/auth_failure.dart';
import 'package:chantipoint/src/auth/auth_repository.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({
    this.restoredUser,
    this.restoreFailure,
    this.signInUser,
    this.signInFailure,
    this.signOutFailure,
    bool? hasSession,
  }) : hasSession = hasSession ?? restoredUser != null;

  AuthorizedUser? restoredUser;
  AuthFailure? restoreFailure;
  AuthorizedUser? signInUser;
  AuthFailure? signInFailure;
  Object? signOutFailure;
  Future<AuthorizedUser?> Function()? onRestore;
  Future<AuthorizedUser> Function()? onSignIn;
  Future<void> Function()? onSignOut;

  final events = StreamController<AuthSessionEvent>.broadcast(sync: true);
  @override
  bool hasSession;
  @override
  Stream<AuthSessionEvent> get sessionChanges => events.stream;

  bool get signOutCalled => signOutCount > 0;
  int signOutCount = 0;
  int restoreCount = 0;
  int signInCount = 0;
  String? lastEmail;
  String? lastPassword;

  void terminate([AuthSessionEvent event = AuthSessionEvent.signedOut]) {
    hasSession = false;
    events.add(event);
  }

  @override
  Future<AuthorizedUser?> restoreSession() async {
    restoreCount++;
    if (onRestore != null) return onRestore!();
    if (restoreFailure != null) {
      if (restoreFailure!.kind == AuthFailureKind.accessDenied ||
          restoreFailure!.kind == AuthFailureKind.sessionExpired) {
        hasSession = false;
      }
      throw restoreFailure!;
    }
    return restoredUser;
  }

  @override
  Future<AuthorizedUser> signIn({
    required String email,
    required String password,
  }) async {
    signInCount++;
    lastEmail = email;
    lastPassword = password;
    if (onSignIn != null) return onSignIn!();
    if (signInFailure != null) throw signInFailure!;
    final user = signInUser;
    if (user == null) throw const AuthFailure(AuthFailureKind.accessDenied);
    hasSession = true;
    return user;
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
    if (onSignOut != null) return onSignOut!();
    if (signOutFailure != null) throw signOutFailure!;
    terminate();
  }
}
