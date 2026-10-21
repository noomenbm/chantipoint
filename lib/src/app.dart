import 'package:flutter/material.dart';

import 'auth/auth_controller.dart';
import 'attendance/attendance_controller.dart';
import 'attendance/history/session_history.dart';
import 'config/supabase_environment_config.dart';
import 'ui/auth_gate.dart';

class ChantiPointApp extends StatelessWidget {
  const ChantiPointApp({
    super.key,
    required this.authController,
    this.attendanceControllerFactory,
    this.historyRepositoryFactory,
  });

  final AuthController authController;
  final AttendanceControllerFactory? attendanceControllerFactory;
  final SessionHistoryRepositoryFactory? historyRepositoryFactory;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChantiPoint',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: AuthGate(
        authController: authController,
        attendanceControllerFactory: attendanceControllerFactory,
        historyRepositoryFactory: historyRepositoryFactory,
      ),
    );
  }

  ThemeData _buildTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF126E82),
      brightness: Brightness.light,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }
}

class ConfigurationRequiredApp extends StatelessWidget {
  const ConfigurationRequiredApp({super.key, required this.config});

  final SupabaseEnvironmentConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChantiPoint',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF126E82)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Configuration requise',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Variables manquantes: ${config.missingValues.join(', ')}',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
