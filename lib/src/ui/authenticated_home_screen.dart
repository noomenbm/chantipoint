import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../attendance/attendance_controller.dart';
import '../auth/authorized_user.dart';
import 'factory_attendance_screen.dart';

class AuthenticatedHomeScreen extends StatefulWidget {
  const AuthenticatedHomeScreen({
    super.key,
    required this.user,
    required this.onSignOut,
    this.attendanceControllerFactory,
  });
  final AuthorizedUser user;
  final Future<void> Function() onSignOut;
  final AttendanceControllerFactory? attendanceControllerFactory;

  @override
  State<AuthenticatedHomeScreen> createState() =>
      _AuthenticatedHomeScreenState();
}

class _AuthenticatedHomeScreenState extends State<AuthenticatedHomeScreen> {
  AttendanceController? _attendance;

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
    return Scaffold(
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
        child: SingleChildScrollView(
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
      ),
    );
  }
}
