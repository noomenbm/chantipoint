import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/attendance/attendance_controller.dart';
import 'src/attendance/file_pending_command_store.dart';
import 'src/attendance/supabase_attendance_repository.dart';
import 'src/attendance/history/supabase_session_history_repository.dart';
import 'src/auth/auth_controller.dart';
import 'src/auth/supabase_auth_repository.dart';
import 'src/config/supabase_environment_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = SupabaseEnvironmentConfig.fromEnvironment();
  if (!config.isConfigured) {
    runApp(ConfigurationRequiredApp(config: config));
    return;
  }

  await Supabase.initialize(
    url: config.url,
    publishableKey: config.publishableKey,
  );

  final authRepository = SupabaseAuthRepository(Supabase.instance.client);
  final authController = AuthController(authRepository);
  final pendingCommands = FilePendingCommandStore();
  runApp(
    ChantiPointApp(
      authController: authController,
      historyRepositoryFactory: (user, isCurrent) =>
          SupabaseSessionHistoryRepository(
            Supabase.instance.client,
            user,
            isCurrent,
          ),
      attendanceControllerFactory: (user) => AttendanceController(
        SupabaseAttendanceRepository(Supabase.instance.client, user),
        pendingCommands,
        user,
        onAuthorizationFailure: authController.revalidateOnResume,
      ),
    ),
  );
}
