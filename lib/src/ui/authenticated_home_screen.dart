import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../attendance/attendance_controller.dart';
import '../attendance/history/session_history.dart';
import '../attendance/history/session_history_controller.dart';
import '../auth/authorized_user.dart';
import 'factory_attendance_screen.dart';
import 'session_history_screen.dart';

class AuthenticatedHomeScreen extends StatefulWidget {
  const AuthenticatedHomeScreen({
    super.key,
    required this.user,
    required this.onSignOut,
    this.attendanceControllerFactory,
    this.historyRepositoryFactory,
  });
  final AuthorizedUser user;
  final Future<void> Function() onSignOut;
  final AttendanceControllerFactory? attendanceControllerFactory;
  final SessionHistoryRepositoryFactory? historyRepositoryFactory;

  @override
  State<AuthenticatedHomeScreen> createState() =>
      _AuthenticatedHomeScreenState();
}

class _AuthenticatedHomeScreenState extends State<AuthenticatedHomeScreen> {
  AttendanceController? _attendance;
  SessionHistoryController? _history;
  bool _showHistory = false;

  void _openHistory() {
    _history?.dispose();
    _history = SessionHistoryController(
      widget.historyRepositoryFactory!(widget.user, () => mounted),
    );
    setState(() => _showHistory = true);
    _history!.loadMore();
  }

  @override
  void dispose() {
    _history?.dispose();
    super.dispose();
  }

  void _createAttendance() {
    _attendance = widget.user.roles.contains(AuthorizedRole.employee)
        ? widget.attendanceControllerFactory?.call(widget.user)
        : null;
  }

  @override
  void initState() {
    super.initState();
    _createAttendance();
  }

  @override
  void didUpdateWidget(covariant AuthenticatedHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.historyRepositoryFactory != widget.historyRepositoryFactory ||
        !identical(oldWidget.user, widget.user)) {
      _history?.dispose();
      _history = null;
      _showHistory = false;
    }
    if (oldWidget.user.profileId != widget.user.profileId ||
        oldWidget.user.companyId != widget.user.companyId ||
        !setEquals(oldWidget.user.roles, widget.user.roles) ||
        oldWidget.attendanceControllerFactory !=
            widget.attendanceControllerFactory) {
      // The child owns and disposes each controller; its key changes with it.
      _createAttendance();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final attendance = _attendance;
    return PopScope(
      canPop: !_showHistory,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showHistory) setState(() => _showHistory = false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ChantiPoint'),
          actions: [
            IconButton(
              tooltip: 'Se déconnecter',
              icon: const Icon(Icons.logout),
              onPressed: widget.onSignOut,
            ),
          ],
        ),
        body: SafeArea(
          child: IndexedStack(
            index: _showHistory ? 1 : 0,
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Bonjour, ${user.displayName}',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final role in user.roles)
                              Chip(label: Text(role.frenchLabel)),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Espace authentifié',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        if (user.roles.contains(AuthorizedRole.employee) &&
                            widget.historyRepositoryFactory != null)
                          OutlinedButton.icon(
                            onPressed: _openHistory,
                            icon: const Icon(Icons.history),
                            label: const Text('Historique'),
                          ),
                        if (!user.roles.contains(AuthorizedRole.employee))
                          const Text(
                            'Le pointage est réservé aux comptes ayant un rôle employé.',
                          ),
                        if (attendance != null)
                          FactoryAttendanceScreen(
                            key: ValueKey(attendance),
                            controller: attendance,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_history != null)
                SessionHistoryScreen(
                  controller: _history!,
                  onBack: () => setState(() => _showHistory = false),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
