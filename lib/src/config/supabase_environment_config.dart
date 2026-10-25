class SupabaseEnvironmentConfig {
  const SupabaseEnvironmentConfig({
    required this.url,
    required this.publishableKey,
    required this.missingValues,
    required this.keySource,
    this.attendanceEnvironmentId = '',
  });

  factory SupabaseEnvironmentConfig.fromEnvironment() {
    const url = String.fromEnvironment('SUPABASE_URL');
    const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const legacyAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    const attendanceEnvironmentId = String.fromEnvironment(
      'ATTENDANCE_ENVIRONMENT_ID',
    );

    final key = publishableKey.isNotEmpty ? publishableKey : legacyAnonKey;
    final missingValues = <String>[
      if (url.isEmpty) 'SUPABASE_URL',
      if (key.isEmpty) 'SUPABASE_PUBLISHABLE_KEY',
    ];

    return SupabaseEnvironmentConfig(
      url: url,
      publishableKey: key,
      missingValues: missingValues,
      keySource: publishableKey.isNotEmpty
          ? 'SUPABASE_PUBLISHABLE_KEY'
          : 'SUPABASE_ANON_KEY',
      attendanceEnvironmentId: attendanceEnvironmentId,
    );
  }

  final String url;
  final String publishableKey;
  final List<String> missingValues;
  final String keySource;
  // Independently provisioned deployment instance/restore epoch, not a URL alias.
  // For capability/v2 dispatch this must be the server's canonical UUID, supplied
  // through reviewed configuration, never learned from attendance_capability.
  // Historical journal bindings are not rewritten to conform to this contract.
  // Missing does not disable login/History and NEVER creates an invented binding.
  final String attendanceEnvironmentId;

  bool get isConfigured => missingValues.isEmpty;
}
