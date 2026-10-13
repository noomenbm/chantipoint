import 'dart:convert';

import 'package:native_geofence/native_geofence.dart' as native;
import 'package:shared_preferences/shared_preferences.dart';

import 'geofence_state_machine.dart';

class GeofenceDiagnosticEvent {
  const GeofenceDiagnosticEvent({
    required this.id,
    required this.type,
    required this.geofenceId,
    required this.sessionId,
    required this.callbackReceivedAtUtc,
    required this.stateAfter,
    required this.acceptedByStateMachine,
    required this.message,
    this.deviceEventAtUtc,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.processingError,
  });

  final String id;
  final String type;
  final String? geofenceId;
  final String? sessionId;
  final DateTime? deviceEventAtUtc;
  final DateTime callbackReceivedAtUtc;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final String stateAfter;
  final bool acceptedByStateMachine;
  final String message;
  final String? processingError;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'type': type,
      'geofenceId': geofenceId,
      'sessionId': sessionId,
      'deviceEventAtUtc': deviceEventAtUtc?.toIso8601String(),
      'callbackReceivedAtUtc': callbackReceivedAtUtc.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'accuracyMeters': accuracyMeters,
      'stateAfter': stateAfter,
      'acceptedByStateMachine': acceptedByStateMachine,
      'message': message,
      'processingError': processingError,
    };
  }

  static GeofenceDiagnosticEvent fromJson(Map<String, Object?> json) {
    return GeofenceDiagnosticEvent(
      id: json['id'] as String? ?? 'unknown',
      type: json['type'] as String? ?? 'unknown',
      geofenceId: json['geofenceId'] as String?,
      sessionId: json['sessionId'] as String?,
      deviceEventAtUtc: _parseUtc(json['deviceEventAtUtc']),
      callbackReceivedAtUtc:
          _parseUtc(json['callbackReceivedAtUtc']) ?? DateTime.now().toUtc(),
      latitude: _toDouble(json['latitude']),
      longitude: _toDouble(json['longitude']),
      accuracyMeters: _toDouble(json['accuracyMeters']),
      stateAfter: json['stateAfter'] as String? ?? 'unknown',
      acceptedByStateMachine: json['acceptedByStateMachine'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      processingError: json['processingError'] as String?,
    );
  }
}

class GeofenceSpikeStore {
  GeofenceSpikeStore({
    SharedPreferencesAsync? preferences,
    GeofenceSpikeStateMachine? stateMachine,
  }) : _preferences = preferences ?? SharedPreferencesAsync(),
       _stateMachine = stateMachine ?? const GeofenceSpikeStateMachine();

  static const int _maxEvents = 100;
  static const String _snapshotKey = 'geofence_spike.snapshot.v1';
  static const String _eventsKey = 'geofence_spike.events.v1';

  final SharedPreferencesAsync _preferences;
  final GeofenceSpikeStateMachine _stateMachine;

  Future<GeofenceSpikeSnapshot> loadSnapshot() async {
    final raw = await _preferences.getString(_snapshotKey);
    if (raw == null || raw.isEmpty) {
      return GeofenceSpikeSnapshot.inactive();
    }
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      return GeofenceSpikeSnapshot.fromJson(json);
    } catch (_) {
      return GeofenceSpikeSnapshot.inactive();
    }
  }

  Future<List<GeofenceDiagnosticEvent>> loadEvents() async {
    final raw = await _preferences.getString(_eventsKey);
    if (raw == null || raw.isEmpty) {
      return <GeofenceDiagnosticEvent>[];
    }
    try {
      final rows = jsonDecode(raw) as List<Object?>;
      return rows
          .whereType<Map<Object?, Object?>>()
          .map(
            (row) =>
                GeofenceDiagnosticEvent.fromJson(row.cast<String, Object?>()),
          )
          .toList()
        ..sort(
          (left, right) =>
              left.callbackReceivedAtUtc.compareTo(right.callbackReceivedAtUtc),
        );
    } catch (_) {
      return <GeofenceDiagnosticEvent>[];
    }
  }

  Future<GeofenceMachineResult> startSession({
    required String sessionId,
    required String geofenceId,
    required DateTime nowUtc,
  }) async {
    final result = _stateMachine.start(
      sessionId: sessionId,
      geofenceId: geofenceId,
      nowUtc: nowUtc.toUtc(),
    );
    await _saveSnapshot(result.snapshot);
    await appendEvent(
      GeofenceDiagnosticEvent(
        id: 'system-start-${nowUtc.toUtc().microsecondsSinceEpoch}',
        type: 'system_start',
        geofenceId: geofenceId,
        sessionId: sessionId,
        callbackReceivedAtUtc: nowUtc.toUtc(),
        stateAfter: result.snapshot.state.name,
        acceptedByStateMachine: result.accepted,
        message: result.message,
      ),
    );
    return result;
  }

  Future<GeofenceMachineResult> stopSession({
    required DateTime nowUtc,
    required String reason,
  }) async {
    final current = await loadSnapshot();
    final result = _stateMachine.stop(
      current,
      nowUtc: nowUtc.toUtc(),
      reason: reason,
    );
    await _saveSnapshot(result.snapshot);
    await appendEvent(
      GeofenceDiagnosticEvent(
        id: 'system-stop-${nowUtc.toUtc().microsecondsSinceEpoch}',
        type: 'system_stop',
        geofenceId: current.geofenceId,
        sessionId: current.sessionId,
        callbackReceivedAtUtc: nowUtc.toUtc(),
        stateAfter: result.snapshot.state.name,
        acceptedByStateMachine: result.accepted,
        message: result.message,
      ),
    );
    return result;
  }

  Future<GeofenceMachineResult> markMonitoringUnavailable({
    required DateTime nowUtc,
    required String reason,
  }) async {
    final current = await loadSnapshot();
    final result = _stateMachine.monitoringUnavailable(
      current,
      nowUtc: nowUtc.toUtc(),
      reason: reason,
    );
    await _saveSnapshot(result.snapshot);
    await appendEvent(
      GeofenceDiagnosticEvent(
        id: 'monitoring-unavailable-${nowUtc.toUtc().microsecondsSinceEpoch}',
        type: 'monitoring_unavailable',
        geofenceId: current.geofenceId,
        sessionId: current.sessionId,
        callbackReceivedAtUtc: nowUtc.toUtc(),
        stateAfter: result.snapshot.state.name,
        acceptedByStateMachine: result.accepted,
        message: result.message,
      ),
    );
    return result;
  }

  Future<GeofenceMachineResult> evaluateGracePeriod(DateTime nowUtc) async {
    final current = await loadSnapshot();
    final result = _stateMachine.evaluate(current, nowUtc.toUtc());
    if (result.accepted) {
      await _saveSnapshot(result.snapshot);
      await appendEvent(
        GeofenceDiagnosticEvent(
          id: 'state-eval-${nowUtc.toUtc().microsecondsSinceEpoch}',
          type: 'state_evaluation',
          geofenceId: current.geofenceId,
          sessionId: current.sessionId,
          callbackReceivedAtUtc: nowUtc.toUtc(),
          stateAfter: result.snapshot.state.name,
          acceptedByStateMachine: true,
          message: result.message,
        ),
      );
    }
    return result;
  }

  Future<void> recordNativeCallback(
    native.GeofenceCallbackParams params, {
    required DateTime callbackReceivedAtUtc,
  }) async {
    final current = await loadSnapshot();
    final activeGeofenceId = current.geofenceId;
    final activeSessionId = current.sessionId;
    final callbackAt = callbackReceivedAtUtc.toUtc();
    final triggeredIds = params.geofences
        .map((geofence) => geofence.id)
        .toSet();

    if (!current.hasActiveSession ||
        activeGeofenceId == null ||
        activeSessionId == null ||
        !triggeredIds.contains(activeGeofenceId)) {
      return;
    }

    final eventType = switch (params.event) {
      native.GeofenceEvent.enter => GeofenceSpikeEventType.enter,
      native.GeofenceEvent.exit => GeofenceSpikeEventType.exit,
      native.GeofenceEvent.dwell => null,
    };

    if (eventType == null) {
      await appendEvent(
        GeofenceDiagnosticEvent(
          id: 'native-unsupported-${callbackAt.microsecondsSinceEpoch}',
          type: params.event.name,
          geofenceId: activeGeofenceId,
          sessionId: activeSessionId,
          callbackReceivedAtUtc: callbackAt,
          stateAfter: current.state.name,
          acceptedByStateMachine: false,
          message: 'Unsupported native transition ignored.',
          processingError:
              'Transition ${params.event.name} is not used by this spike.',
        ),
      );
      return;
    }

    final transition = GeofenceSpikeEvent(
      id: 'native-$activeGeofenceId-${params.event.name}-${callbackAt.microsecondsSinceEpoch}',
      sessionId: activeSessionId,
      geofenceId: activeGeofenceId,
      type: eventType,
      callbackReceivedAtUtc: callbackAt,
    );
    final result = _stateMachine.applyEvent(
      current,
      transition,
      nowUtc: callbackAt,
    );
    await _saveSnapshot(result.snapshot);

    await appendEvent(
      GeofenceDiagnosticEvent(
        id: transition.id,
        type: params.event.name,
        geofenceId: activeGeofenceId,
        sessionId: activeSessionId,
        deviceEventAtUtc: null,
        callbackReceivedAtUtc: callbackAt,
        latitude: params.location?.latitude,
        longitude: params.location?.longitude,
        accuracyMeters: null,
        stateAfter: result.snapshot.state.name,
        acceptedByStateMachine: result.accepted,
        message: result.message,
      ),
    );
  }

  Future<void> appendEvent(GeofenceDiagnosticEvent event) async {
    final events = await loadEvents();
    final trimmed = <GeofenceDiagnosticEvent>[...events, event];
    final keep = trimmed.length > _maxEvents
        ? trimmed.sublist(trimmed.length - _maxEvents)
        : trimmed;
    await _preferences.setString(
      _eventsKey,
      jsonEncode(keep.map((row) => row.toJson()).toList()),
    );
  }

  Future<void> clearEvents() async {
    await _preferences.remove(_eventsKey);
  }

  Future<void> _saveSnapshot(GeofenceSpikeSnapshot snapshot) async {
    await _preferences.setString(_snapshotKey, jsonEncode(snapshot.toJson()));
  }
}

DateTime? _parseUtc(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

double? _toDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return null;
}
