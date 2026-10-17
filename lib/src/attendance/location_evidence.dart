enum LocationPermissionState {
  precise('precise'),
  approximate('approximate'),
  denied('denied'),
  unknown('unknown');

  const LocationPermissionState(this.sqlValue);
  final String sqlValue;
}

enum LocationAcquisitionResult {
  fix('fix'),
  permissionDenied('permission_denied'),
  locationServicesDisabled('location_services_disabled'),
  timeout('timeout'),
  providerError('provider_error'),
  unavailable('unavailable'),
  unknown('unknown');

  const LocationAcquisitionResult(this.sqlValue);
  final String sqlValue;
}

enum LocationProvider {
  gps('gps'),
  network('network'),
  fused('fused'),
  emulator('emulator'),
  unknown('unknown');

  const LocationProvider(this.sqlValue);
  final String sqlValue;
}

/// Submitted device claims, not a local classification or proof of presence.
/// NULL diagnostics are supported by SQL and normalize to unknown there.
class LocationEvidence {
  const LocationEvidence({
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.observedAt,
    this.permission = LocationPermissionState.unknown,
    this.servicesEnabled,
    this.result = LocationAcquisitionResult.unknown,
    this.provider = LocationProvider.unknown,
  });

  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final DateTime? observedAt;
  final LocationPermissionState? permission;
  final bool? servicesEnabled;
  final LocationAcquisitionResult? result;
  final LocationProvider? provider;

  Map<String, dynamic> toRpcParameters() {
    // JSON cannot represent NaN/infinity. Finite low-quality or partial claims
    // remain intact: quality evaluation/sanitization belongs to the backend.
    if ([
      latitude,
      longitude,
      accuracyMeters,
    ].any((value) => value != null && !value.isFinite)) {
      throw const FormatException('Non-finite location claim');
    }
    return Map.unmodifiable({
      'p_latitude': latitude,
      'p_longitude': longitude,
      'p_accuracy_meters': accuracyMeters,
      'p_location_observed_at': observedAt?.toUtc().toIso8601String(),
      'p_permission': permission?.sqlValue,
      'p_services_enabled': servicesEnabled,
      'p_location_result': result?.sqlValue,
      'p_provider': provider?.sqlValue,
    });
  }
}
