class SupabaseEnvironmentConfig {
  const SupabaseEnvironmentConfig({
    required this.url,
    required this.publishableKey,
    required this.missingValues,
    required this.keySource,
  });

  factory SupabaseEnvironmentConfig.fromEnvironment() {
    const url = String.fromEnvironment('SUPABASE_URL');
    const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const legacyAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

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
    );
  }

  final String url;
  final String publishableKey;
  final List<String> missingValues;
  final String keySource;

  bool get isConfigured => missingValues.isEmpty;
}
