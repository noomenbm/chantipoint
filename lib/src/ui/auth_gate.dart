import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../attendance/attendance_controller.dart';
import '../attendance/history/session_history.dart';
import '../attendance/integration/normal_attendance_composition.dart';
import 'access_check_screen.dart';
import 'authenticated_home_screen.dart';
import 'login_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authController,
    this.attendanceControllerFactory,
    this.historyRepositoryFactory,
    this.employeeWorkflowFactory,
    this.onDispose,
  });

  final AuthController authController;
  final AttendanceControllerFactory? attendanceControllerFactory;
  final SessionHistoryRepositoryFactory? historyRepositoryFactory;
  final EmployeeAttendanceWorkflowFactory? employeeWorkflowFactory;
  final VoidCallback? onDispose;

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
      if (oldWidget.onDispose != null) {
        oldWidget.onDispose!();
      } else {
        oldWidget.authController.dispose();
      }
      unawaited(widget.authController.restoreSession());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The application gate owns the controller supplied to ChantiPointApp.
    if (widget.onDispose != null) {
      widget.onDispose!();
    } else {
      widget.authController.dispose();
    }
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
            employeeWorkflowFactory: widget.employeeWorkflowFactory,
            historyRepositoryFactory: widget.historyRepositoryFactory == null
                ? null
                : (user, isMounted) => widget.historyRepositoryFactory!(
                    user,
                    () =>
                        isMounted() &&
                        !widget.authController.isDisposed &&
                        identical(widget.authController.state, state) &&
                        state.status == AuthStatus.authenticated,
                  ),
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
