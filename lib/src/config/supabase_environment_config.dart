import '../attendance/history/session_history.dart';

class SupabaseEnvironmentConfig {
  const SupabaseEnvironmentConfig({
    required this.url,
    required this.publishableKey,
    required this.missingValues,
    required this.keySource,
    this.attendanceEnvironmentId = '',
    this.developmentAttendanceOperatorPublicKey = '',
    this.historyNotesEnabled = false,
    this.historyReviewEnabled = false,
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
      developmentAttendanceOperatorPublicKey: const String.fromEnvironment(
        'DEVELOPMENT_ATTENDANCE_OPERATOR_PUBLIC_KEY',
      ),
      historyNotesEnabled: const bool.fromEnvironment('HISTORY_NOTES_ENABLED'),
      historyReviewEnabled: const bool.fromEnvironment(
        'HISTORY_REVIEW_ENABLED',
      ),
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
  // Independent public trust anchor; never obtained from capability or journals.
  // Only DEBUG composition may select its verifier; configuration grants nothing.
  final String developmentAttendanceOperatorPublicKey;
  // Operator-reviewed deployment schema, independent of attendance approval.
  // A failed enriched query remains an error; never retry a weaker projection.
  final bool historyNotesEnabled, historyReviewEnabled;
  HistoryCapabilities get historyCapabilities => HistoryCapabilities(
    notes: historyNotesEnabled,
    review: historyReviewEnabled,
  );

  bool get isConfigured => missingValues.isEmpty;
}
