enum GeofenceSpikeState {
  inactive,
  monitoring,
  exitDetected,
  gracePeriod,
  returnDetected,
  automaticCheckoutCandidate,
  monitoringUnavailable,
  stopped,
}

enum GeofenceSpikeEventType { enter, exit, monitoringUnavailable }

class GeofenceSpikeEvent {
  const GeofenceSpikeEvent({
    required this.id,
    required this.sessionId,
    required this.geofenceId,
    required this.type,
    required this.callbackReceivedAtUtc,
    this.reason,
  });

  final String id;
  final String sessionId;
  final String geofenceId;
  final GeofenceSpikeEventType type;
  final DateTime? callbackReceivedAtUtc;
  final String? reason;
}

class GeofenceSpikeRecord {
  const GeofenceSpikeRecord({
    required this.type,
    required this.occurredAtUtc,
    required this.message,
  });

  final String type;
  final DateTime occurredAtUtc;
  final String message;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'type': type,
      'occurredAtUtc': occurredAtUtc.toIso8601String(),
      'message': message,
    };
  }

  static GeofenceSpikeRecord fromJson(Map<String, Object?> json) {
    return GeofenceSpikeRecord(
      type: json['type'] as String? ?? 'unknown',
      occurredAtUtc: _parseUtc(json['occurredAtUtc']) ?? DateTime.now().toUtc(),
      message: json['message'] as String? ?? '',
    );
  }
}

class GeofenceSpikeSnapshot {
  const GeofenceSpikeSnapshot({
    required this.state,
    required this.sessionId,
    required this.geofenceId,
    required this.monitoringStartedAtUtc,
    required this.graceStartedAtUtc,
    required this.graceExpiresAtUtc,
    required this.lastAcceptedEventAtUtc,
    required this.processedEventIds,
    required this.records,
  });

  factory GeofenceSpikeSnapshot.inactive() {
    return const GeofenceSpikeSnapshot(
      state: GeofenceSpikeState.inactive,
      sessionId: null,
      geofenceId: null,
      monitoringStartedAtUtc: null,
      graceStartedAtUtc: null,
      graceExpiresAtUtc: null,
      lastAcceptedEventAtUtc: null,
      processedEventIds: <String>{},
      records: <GeofenceSpikeRecord>[],
    );
  }

  final GeofenceSpikeState state;
  final String? sessionId;
  final String? geofenceId;
  final DateTime? monitoringStartedAtUtc;
  final DateTime? graceStartedAtUtc;
  final DateTime? graceExpiresAtUtc;
  final DateTime? lastAcceptedEventAtUtc;
  final Set<String> processedEventIds;
  final List<GeofenceSpikeRecord> records;

  bool get hasActiveSession {
    return sessionId != null &&
        geofenceId != null &&
        state != GeofenceSpikeState.inactive &&
        state != GeofenceSpikeState.stopped;
  }

  GeofenceSpikeSnapshot copyWith({
    GeofenceSpikeState? state,
    Object? sessionId = _unchanged,
    Object? geofenceId = _unchanged,
    Object? monitoringStartedAtUtc = _unchanged,
    Object? graceStartedAtUtc = _unchanged,
    Object? graceExpiresAtUtc = _unchanged,
    Object? lastAcceptedEventAtUtc = _unchanged,
    Set<String>? processedEventIds,
    List<GeofenceSpikeRecord>? records,
  }) {
    return GeofenceSpikeSnapshot(
      state: state ?? this.state,
      sessionId: identical(sessionId, _unchanged)
          ? this.sessionId
          : sessionId as String?,
      geofenceId: identical(geofenceId, _unchanged)
          ? this.geofenceId
          : geofenceId as String?,
      monitoringStartedAtUtc: identical(monitoringStartedAtUtc, _unchanged)
          ? this.monitoringStartedAtUtc
          : monitoringStartedAtUtc as DateTime?,
      graceStartedAtUtc: identical(graceStartedAtUtc, _unchanged)
          ? this.graceStartedAtUtc
          : graceStartedAtUtc as DateTime?,
      graceExpiresAtUtc: identical(graceExpiresAtUtc, _unchanged)
          ? this.graceExpiresAtUtc
          : graceExpiresAtUtc as DateTime?,
      lastAcceptedEventAtUtc: identical(lastAcceptedEventAtUtc, _unchanged)
          ? this.lastAcceptedEventAtUtc
          : lastAcceptedEventAtUtc as DateTime?,
      processedEventIds: processedEventIds ?? this.processedEventIds,
      records: records ?? this.records,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'state': state.name,
      'sessionId': sessionId,
      'geofenceId': geofenceId,
      'monitoringStartedAtUtc': monitoringStartedAtUtc?.toIso8601String(),
      'graceStartedAtUtc': graceStartedAtUtc?.toIso8601String(),
      'graceExpiresAtUtc': graceExpiresAtUtc?.toIso8601String(),
      'lastAcceptedEventAtUtc': lastAcceptedEventAtUtc?.toIso8601String(),
      'processedEventIds': processedEventIds.toList(),
      'records': records.map((record) => record.toJson()).toList(),
    };
  }

  static GeofenceSpikeSnapshot fromJson(Map<String, Object?> json) {
    final stateName = json['state'] as String?;
    final state = GeofenceSpikeState.values.firstWhere(
      (value) => value.name == stateName,
      orElse: () => GeofenceSpikeState.inactive,
    );
    final processed =
        (json['processedEventIds'] as List<Object?>? ?? <Object?>[])
            .whereType<String>()
            .toSet();
    final rawRecords = json['records'] as List<Object?>? ?? <Object?>[];
    final records = rawRecords
        .whereType<Map<Object?, Object?>>()
        .map(
          (record) =>
              GeofenceSpikeRecord.fromJson(record.cast<String, Object?>()),
        )
        .toList();

    return GeofenceSpikeSnapshot(
      state: state,
      sessionId: json['sessionId'] as String?,
      geofenceId: json['geofenceId'] as String?,
      monitoringStartedAtUtc: _parseUtc(json['monitoringStartedAtUtc']),
      graceStartedAtUtc: _parseUtc(json['graceStartedAtUtc']),
      graceExpiresAtUtc: _parseUtc(json['graceExpiresAtUtc']),
      lastAcceptedEventAtUtc: _parseUtc(json['lastAcceptedEventAtUtc']),
      processedEventIds: processed,
      records: records,
    );
  }
}

class GeofenceMachineResult {
  const GeofenceMachineResult({
    required this.snapshot,
    required this.accepted,
    required this.message,
  });

  final GeofenceSpikeSnapshot snapshot;
  final bool accepted;
  final String message;
}

class GeofenceSpikeStateMachine {
  const GeofenceSpikeStateMachine({
    this.gracePeriod = const Duration(minutes: 10),
  });

  final Duration gracePeriod;

  GeofenceMachineResult start({
    required String sessionId,
    required String geofenceId,
    required DateTime nowUtc,
  }) {
    final record = GeofenceSpikeRecord(
      type: 'start',
      occurredAtUtc: nowUtc.toUtc(),
      message: 'Monitoring started for $geofenceId.',
    );
    return GeofenceMachineResult(
      snapshot: GeofenceSpikeSnapshot(
        state: GeofenceSpikeState.monitoring,
        sessionId: sessionId,
        geofenceId: geofenceId,
        monitoringStartedAtUtc: nowUtc.toUtc(),
        graceStartedAtUtc: null,
        graceExpiresAtUtc: null,
        lastAcceptedEventAtUtc: nowUtc.toUtc(),
        processedEventIds: const <String>{},
        records: <GeofenceSpikeRecord>[record],
      ),
      accepted: true,
      message: record.message,
    );
  }

  GeofenceMachineResult stop(
    GeofenceSpikeSnapshot current, {
    required DateTime nowUtc,
    String reason = 'Monitoring stopped.',
  }) {
    final record = GeofenceSpikeRecord(
      type: 'stop',
      occurredAtUtc: nowUtc.toUtc(),
      message: reason,
    );
    return GeofenceMachineResult(
      snapshot: current.copyWith(
        state: GeofenceSpikeState.stopped,
        sessionId: null,
        geofenceId: null,
        graceStartedAtUtc: null,
        graceExpiresAtUtc: null,
        lastAcceptedEventAtUtc: nowUtc.toUtc(),
        records: <GeofenceSpikeRecord>[...current.records, record],
      ),
      accepted: true,
      message: record.message,
    );
  }

  GeofenceMachineResult monitoringUnavailable(
    GeofenceSpikeSnapshot current, {
    required DateTime nowUtc,
    required String reason,
  }) {
    if (!current.hasActiveSession) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'No active monitoring session can be marked unavailable.',
      );
    }
    final record = GeofenceSpikeRecord(
      type: 'monitoring_unavailable',
      occurredAtUtc: nowUtc.toUtc(),
      message: reason,
    );
    return GeofenceMachineResult(
      snapshot: current.copyWith(
        state: GeofenceSpikeState.monitoringUnavailable,
        lastAcceptedEventAtUtc: nowUtc.toUtc(),
        records: <GeofenceSpikeRecord>[...current.records, record],
      ),
      accepted: true,
      message: record.message,
    );
  }

  GeofenceMachineResult applyEvent(
    GeofenceSpikeSnapshot current,
    GeofenceSpikeEvent event, {
    DateTime? nowUtc,
  }) {
    final evaluated = evaluate(current, nowUtc ?? DateTime.now().toUtc());
    current = evaluated.snapshot;

    if (!current.hasActiveSession) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'Ignored event because no active monitoring session exists.',
      );
    }
    if (current.sessionId != event.sessionId ||
        current.geofenceId != event.geofenceId) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'Ignored stale event for an old geofence session.',
      );
    }
    if (current.processedEventIds.contains(event.id)) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'Ignored duplicate event ${event.id}.',
      );
    }
    final callbackAt = event.callbackReceivedAtUtc?.toUtc();
    if (callbackAt == null) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'Ignored event without callback receipt timestamp.',
      );
    }
    final monitoringStartedAt = current.monitoringStartedAtUtc;
    if (monitoringStartedAt != null &&
        callbackAt.isBefore(monitoringStartedAt)) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'Ignored event older than the active monitoring session.',
      );
    }
    final lastAcceptedEventAt = current.lastAcceptedEventAtUtc;
    if (lastAcceptedEventAt != null &&
        callbackAt.isBefore(lastAcceptedEventAt)) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message:
            'Ignored out-of-order event older than the last accepted event.',
      );
    }

    return switch (event.type) {
      GeofenceSpikeEventType.exit => _applyExit(current, event, callbackAt),
      GeofenceSpikeEventType.enter => _applyEnter(current, event, callbackAt),
      GeofenceSpikeEventType.monitoringUnavailable => monitoringUnavailable(
        current,
        nowUtc: callbackAt,
        reason: event.reason ?? 'Monitoring unavailable.',
      ),
    };
  }

  GeofenceMachineResult evaluate(
    GeofenceSpikeSnapshot current,
    DateTime nowUtc,
  ) {
    if (current.state != GeofenceSpikeState.gracePeriod ||
        current.graceExpiresAtUtc == null) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'No grace-period expiration to evaluate.',
      );
    }
    final graceExpiresAt = current.graceExpiresAtUtc!;
    if (nowUtc.toUtc().isBefore(graceExpiresAt)) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message: 'Grace period is still active.',
      );
    }
    final record = GeofenceSpikeRecord(
      type: 'automatic_checkout_candidate',
      occurredAtUtc: nowUtc.toUtc(),
      message:
          'Test-only automatic checkout candidate flagged after grace period.',
    );
    return GeofenceMachineResult(
      snapshot: current.copyWith(
        state: GeofenceSpikeState.automaticCheckoutCandidate,
        lastAcceptedEventAtUtc: nowUtc.toUtc(),
        records: <GeofenceSpikeRecord>[...current.records, record],
      ),
      accepted: true,
      message: record.message,
    );
  }

  GeofenceMachineResult _applyExit(
    GeofenceSpikeSnapshot current,
    GeofenceSpikeEvent event,
    DateTime callbackAt,
  ) {
    if (current.state == GeofenceSpikeState.gracePeriod ||
        current.state == GeofenceSpikeState.exitDetected) {
      return GeofenceMachineResult(
        snapshot: current.copyWith(
          processedEventIds: <String>{...current.processedEventIds, event.id},
        ),
        accepted: false,
        message: 'Ignored duplicate exit while grace period is already active.',
      );
    }
    if (current.state == GeofenceSpikeState.automaticCheckoutCandidate) {
      return GeofenceMachineResult(
        snapshot: current,
        accepted: false,
        message:
            'Ignored exit after an automatic checkout candidate was flagged.',
      );
    }
    final expiresAt = callbackAt.add(gracePeriod);
    final record = GeofenceSpikeRecord(
      type: 'exit',
      occurredAtUtc: callbackAt,
      message:
          'Exit detected; grace period started until ${expiresAt.toIso8601String()}.',
    );
    return GeofenceMachineResult(
      snapshot: current.copyWith(
        state: GeofenceSpikeState.gracePeriod,
        graceStartedAtUtc: callbackAt,
        graceExpiresAtUtc: expiresAt,
        lastAcceptedEventAtUtc: callbackAt,
        processedEventIds: <String>{...current.processedEventIds, event.id},
        records: <GeofenceSpikeRecord>[...current.records, record],
      ),
      accepted: true,
      message: record.message,
    );
  }

  GeofenceMachineResult _applyEnter(
    GeofenceSpikeSnapshot current,
    GeofenceSpikeEvent event,
    DateTime callbackAt,
  ) {
    if (current.state == GeofenceSpikeState.gracePeriod &&
        current.graceExpiresAtUtc != null &&
        callbackAt.isBefore(current.graceExpiresAtUtc!)) {
      final record = GeofenceSpikeRecord(
        type: 'return',
        occurredAtUtc: callbackAt,
        message:
            'Return detected during grace period; monitoring resumed.',
      );
      return GeofenceMachineResult(
        snapshot: current.copyWith(
          state: GeofenceSpikeState.monitoring,
          graceStartedAtUtc: null,
          graceExpiresAtUtc: null,
          lastAcceptedEventAtUtc: callbackAt,
          processedEventIds: <String>{...current.processedEventIds, event.id},
          records: <GeofenceSpikeRecord>[...current.records, record],
        ),
        accepted: true,
        message: record.message,
      );
    }
    if (current.state == GeofenceSpikeState.gracePeriod &&
        current.graceExpiresAtUtc != null &&
        !callbackAt.isBefore(current.graceExpiresAtUtc!)) {
      final evaluated = evaluate(current, callbackAt);
      return GeofenceMachineResult(
        snapshot: evaluated.snapshot.copyWith(
          processedEventIds: <String>{
            ...evaluated.snapshot.processedEventIds,
            event.id,
          },
        ),
        accepted: false,
        message: 'Return arrived after the grace boundary; administrator review required.',
      );
    }
    return GeofenceMachineResult(
      snapshot: current.copyWith(
        processedEventIds: <String>{...current.processedEventIds, event.id},
      ),
      accepted: false,
      message: 'Ignored enter event because no exit grace period is active.',
    );
  }
}

const Object _unchanged = Object();

DateTime? _parseUtc(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}
