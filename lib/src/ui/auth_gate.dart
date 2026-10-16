import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../attendance/attendance_controller.dart';
import 'access_check_screen.dart';
import 'authenticated_home_screen.dart';
import 'login_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authController,
    this.attendanceControllerFactory,
  });

  final AuthController authController;
  final AttendanceControllerFactory? attendanceControllerFactory;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  AppLifecycleState? _lastLifecycleState;
  int _attendanceRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastLifecycleState = WidgetsBinding.instance.lifecycleState;
    unawaited(widget.authController.restoreSession());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _lastLifecycleState;
    _lastLifecycleState = state;
    if (state == AppLifecycleState.resumed && previous != state) {
      // Recreate attendance after resume even if fast auth states coalesce
      // before the next frame and the old home screen would otherwise survive.
      ++_attendanceRevision;
      unawaited(widget.authController.revalidateOnResume());
    }
  }

  @override
  void didUpdateWidget(covariant AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authController != widget.authController) {
      oldWidget.authController.dispose();
      unawaited(widget.authController.restoreSession());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The application gate owns the controller supplied to ChantiPointApp.
    widget.authController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.authController,
      builder: (context, _) {
        final state = widget.authController.state;

        return switch (state.status) {
          AuthStatus.checkingSession => const _LoadingScreen(),
          AuthStatus.signingOut => const Scaffold(
            body: Center(child: Text('Déconnexion en cours…')),
          ),
          AuthStatus.accessBlocked => AccessCheckScreen(
            message:
                state.message ?? 'Votre accès doit être vérifié. Réessayez.',
            onRetry: widget.authController.restoreSession,
            onSignOut: widget.authController.signOut,
          ),
          AuthStatus.signedOut => LoginScreen(
            message: state.message,
            isLoading: false,
            onSignIn: widget.authController.signIn,
          ),
          AuthStatus.authenticating => LoginScreen(
            isLoading: true,
            onSignIn: widget.authController.signIn,
          ),
          AuthStatus.authenticated => AuthenticatedHomeScreen(
            key: ValueKey(
              '${state.user!.companyId}:${state.user!.profileId}:$_attendanceRevision',
            ),
            user: state.user!,
            onSignOut: widget.authController.signOut,
            attendanceControllerFactory: widget.attendanceControllerFactory,
          ),
        };
      },
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox.square(
          dimension: 40,
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}
