// Temporary operator utility APK. This target is never imported by lib/main.dart.
import 'dart:async';

import 'package:chantipoint/src/auth/auth_controller.dart';
import 'package:chantipoint/src/auth/supabase_auth_repository.dart';
import 'package:chantipoint/src/config/supabase_environment_config.dart';
import 'package:chantipoint/src/development/activation_controller.dart';
import 'package:chantipoint/src/development/android_activation_ports.dart';
import 'package:chantipoint/src/ui/access_check_screen.dart';
import 'package:chantipoint/src/ui/login_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = SupabaseEnvironmentConfig.fromEnvironment();
  const maintenance = String.fromEnvironment(
    'DEVELOPMENT_ENROLLMENT_MAINTENANCE_REF',
  );
  if (!kDebugMode ||
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      !config.isConfigured ||
      maintenance.isEmpty) {
    runApp(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: Text('Activation indisponible.'))),
      ),
    );
    return;
  }
  await Supabase.initialize(
    url: config.url,
    publishableKey: config.publishableKey,
  );
  final repository = SupabaseAuthRepository(Supabase.instance.client);
  final auth = AuthController(repository);
  final ports = AndroidActivationPorts(
    auth,
    repository,
    Supabase.instance.client,
    config,
  );
  runApp(
    _ActivationApp(
      auth,
      ports,
      DevelopmentActivationController(ports, maintenanceRef: maintenance),
    ),
  );
}

class _ActivationApp extends StatefulWidget {
  const _ActivationApp(this.auth, this.ports, this.activation);
  final AuthController auth;
  final AndroidActivationPorts ports;
  final DevelopmentActivationController activation;
  @override
  State<_ActivationApp> createState() => _ActivationAppState();
}

class _ActivationAppState extends State<_ActivationApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.auth.restoreSession());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The system document picker returns while an explicit operation is pending.
    // Import only stages a signature; install separately revalidates authorization.
    if (state == AppLifecycleState.resumed && !widget.activation.busy) {
      unawaited(widget.auth.revalidateOnResume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.activation.dispose();
    widget.ports.close();
    widget.auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Activation ChantiPoint',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF126E82)),
    ),
    home: AnimatedBuilder(
      animation: Listenable.merge([widget.auth, widget.activation]),
      builder: (context, _) {
        final state = widget.auth.state;
        if (state.status == AuthStatus.signedOut ||
            state.status == AuthStatus.authenticating) {
          return LoginScreen(
            isLoading: state.status == AuthStatus.authenticating,
            message: state.message,
            onSignIn: widget.auth.signIn,
          );
        }
        if (state.status == AuthStatus.accessBlocked) {
          return AccessCheckScreen(
            message: state.message ?? 'Accès non confirmé.',
            onRetry: widget.auth.restoreSession,
            onSignOut: widget.auth.signOut,
          );
        }
        if (state.status != AuthStatus.authenticated) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final c = widget.activation;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Activation ChantiPoint'),
            actions: [
              IconButton(
                onPressed: c.busy ? null : widget.auth.signOut,
                tooltip: 'Se déconnecter',
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Outil séparé d’activation de l’appareil',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Connectez-vous avec le compte communiqué par le développeur. '
                  'Une demande ne donne aucun droit de pointage sans son approbation signée.',
                ),
                const SizedBox(height: 20),
                if (c.busy) const LinearProgressIndicator(),
                if (c.message != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(c.message!),
                  ),
                FilledButton(
                  onPressed: c.busy ? null : c.prepare,
                  child: const Text('Préparer la demande'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: c.busy || !c.requestReady ? null : c.export,
                  child: const Text('Enregistrer la demande'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: c.busy || !c.requestReady ? null : c.choose,
                  child: const Text('Choisir le fichier d’activation'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: c.busy || !c.signatureReady ? null : c.install,
                  child: const Text('Installer l’activation'),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
