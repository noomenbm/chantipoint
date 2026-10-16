import 'dart:convert';
import 'dart:math';

enum AttendanceFailureKind {
  network,
  backend,
  unauthorized,
  sessionExpired,
  duplicateActive,
  idempotencyConflict,
  sessionNotActive,
  storage,
  externalSession,
}

class AttendanceFailure implements Exception {
  const AttendanceFailure(this.kind);
  final AttendanceFailureKind kind;

  String get message => switch (kind) {
    AttendanceFailureKind.network =>
      'Connexion impossible. Le pointage reste à vérifier. Réessayez.',
    AttendanceFailureKind.backend => 'Service temporairement indisponible. Vérifiez le pointage avant de continuer.',
    AttendanceFailureKind.unauthorized =>
      'Votre compte ne permet pas ce pointage. Votre accès doit être vérifié.',
    AttendanceFailureKind.sessionExpired =>
      'Votre session a expiré. Veuillez vous reconnecter.',
    AttendanceFailureKind.duplicateActive =>
      'Une session est déjà active. Vérifiez le pointage en cours.',
    AttendanceFailureKind.idempotencyConflict =>
      'Ce pointage présente un conflit. Contactez votre administrateur.',
    AttendanceFailureKind.sessionNotActive =>
      'Cette session a déjà été fermée ou ne peut plus être modifiée.',
    AttendanceFailureKind.storage => 'Impossible de sécuriser le pointage sur cet appareil. Réessayez avant de continuer.',
    AttendanceFailureKind.externalSession => 'Une session sur chantier extérieur est active. Ce parcours prend uniquement en charge l’usine.',
  };
}

class WorkSession {
  const WorkSession({
    required this.id,
    required this.locationContext,
    required this.lifecycleStatus,
    required this.startedAt,
    this.endedAt,
  });
  final String id;
  final String locationContext;
  final String lifecycleStatus;
  final DateTime startedAt;
  final DateTime? endedAt;
  bool get isActive => lifecycleStatus == 'active';
  bool get isFactory => locationContext == 'factory';

  factory WorkSession.fromJson(Map<String, dynamic> row) {
    DateTime timestamp(Object? value) {
      if (value is! String ||
          !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
        throw const FormatException('Missing server timestamp');
      }
      return DateTime.parse(value).toUtc();
    }

    final id = row['id'] ?? row['session_id'];
    final context = row['location_context'];
    final lifecycle = row['lifecycle_status'];
    final start = timestamp(row['started_at']);
    final end = row['ended_at'] == null ? null : timestamp(row['ended_at']);
    if (id is! String ||
        id.isEmpty ||
        !const ['factory', 'external_worksite'].contains(context) ||
        !const [
          'active',
          'closed_manual',
          'closed_automatic',
          'closed_admin',
          'voided',
        ].contains(lifecycle) ||
        (lifecycle == 'active') != (end == null) ||
        (end != null && end.isBefore(start))) {
      throw const FormatException('Invalid server session');
    }
    return WorkSession(
      id: id,
      locationContext: context as String,
      lifecycleStatus: lifecycle as String,
      startedAt: start,
      endedAt: end,
    );
  }
}

enum AttendanceCommandKind { checkIn, checkOut }

class AttendanceCommand {
  AttendanceCommand._(this.kind, Map<String, dynamic> payload)
    : payload = Map.unmodifiable(payload);
  final AttendanceCommandKind kind;
  final Map<String, dynamic> payload;
  String get key => payload['p_idempotency_key'] as String;
  String get rpc =>
      kind == AttendanceCommandKind.checkIn ? 'check_in' : 'check_out';

  factory AttendanceCommand.factoryCheckIn({
    String? key,
    DateTime? observedAt,
  }) => AttendanceCommand._(AttendanceCommandKind.checkIn, {
    'p_location_context': 'factory',
    'p_site_description': null,
    'p_device_observed_at': (observedAt ?? DateTime.now())
        .toUtc()
        .toIso8601String(),
    'p_idempotency_key': key ?? _newKey(),
  });

  factory AttendanceCommand.checkOut(
    WorkSession session, {
    String? key,
    DateTime? observedAt,
  }) {
    if (!session.isFactory) {
      throw const AttendanceFailure(AttendanceFailureKind.externalSession);
    }
    if (!session.isActive) {
      throw const AttendanceFailure(AttendanceFailureKind.sessionNotActive);
    }
    return AttendanceCommand._(AttendanceCommandKind.checkOut, {
      'p_work_session_id': session.id,
      'p_idempotency_key': key ?? _newKey(),
      'p_device_observed_at': (observedAt ?? DateTime.now())
          .toUtc()
          .toIso8601String(),
    });
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'payload': payload,
  };

  factory AttendanceCommand.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unknown journal version');
    }
    final kind = AttendanceCommandKind.values.byName(json['kind'] as String);
    final payload = Map<String, dynamic>.from(json['payload'] as Map);
    final allowed = kind == AttendanceCommandKind.checkIn
        ? {
            'p_location_context',
            'p_site_description',
            'p_device_observed_at',
            'p_idempotency_key',
          }
        : {'p_work_session_id', 'p_idempotency_key', 'p_device_observed_at'};
    final key = payload['p_idempotency_key'];
    final observed = payload['p_device_observed_at'];
    if (payload.length != allowed.length ||
        !allowed.containsAll(payload.keys) ||
        key is! String ||
        key.trim() != key ||
        key.length < 8 ||
        key.length > 160 ||
        observed is! String ||
        !observed.endsWith('Z') ||
        DateTime.tryParse(observed) == null ||
        (kind == AttendanceCommandKind.checkIn &&
            (payload['p_location_context'] != 'factory' ||
                payload['p_site_description'] != null)) ||
        (kind == AttendanceCommandKind.checkOut &&
            (payload['p_work_session_id'] is! String ||
                (payload['p_work_session_id'] as String).isEmpty))) {
      throw const FormatException('Invalid journal command');
    }
    return AttendanceCommand._(kind, payload);
  }

  static String _newKey() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }
}
