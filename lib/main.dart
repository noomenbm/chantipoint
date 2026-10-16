import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
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
  runApp(ChantiPointApp(authController: AuthController(authRepository)));
}
