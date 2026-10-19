import 'location_evidence.dart';

enum ForegroundPermission {
  precise,
  approximate,
  denied,
  deniedForever,
  unknown,
}

final class ForegroundFix {
  const ForegroundFix({
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.observedAt,
    this.provider = LocationProvider.unknown,
  });
  final double? latitude, longitude, accuracyMeters;
  final DateTime? observedAt;
  final LocationProvider provider;
}

final class ForegroundLocationFailure implements Exception {
  const ForegroundLocationFailure(this.result);
  final LocationAcquisitionResult result;
}

/// One foreground request only. currentFix MUST settle/cancel native work before
/// returning/throwing, including timeout. Implementations must not use a detached
/// Future.timeout. No last-known lookup, streams, tracking service or polling.
abstract interface class ForegroundLocationPlatform {
  Future<bool> servicesEnabled();
  Future<ForegroundPermission> permission();
  Future<ForegroundPermission> requestPermission();
  Future<ForegroundFix?> currentFix(Duration limit);
}

abstract interface class ForegroundLocationAcquisition {
  Future<LocationEvidence> acquire({bool Function()? isCurrent});
}

/// Evidence only, never a local attendance classification or authorization gate.
final class ForegroundLocationService implements ForegroundLocationAcquisition {
  ForegroundLocationService(this.platform);
  static const fixLimit = Duration(seconds: 15);
  final ForegroundLocationPlatform platform;
  bool _busy = false;

  @override
  Future<LocationEvidence> acquire({bool Function()? isCurrent}) async {
    bool current() {
      try {
        return isCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    if (_busy) {
      return const LocationEvidence(
        result: LocationAcquisitionResult.unavailable,
      );
    }
    _busy = true;
    var permission = LocationPermissionState.unknown;
    bool? services;
    LocationEvidence failure(LocationAcquisitionResult result) =>
        LocationEvidence(
          permission: result == LocationAcquisitionResult.permissionDenied
              ? LocationPermissionState.denied
              : permission,
          servicesEnabled:
              result == LocationAcquisitionResult.locationServicesDisabled
              ? false
              : services,
          result: result,
        );
    try {
      if (!current()) return failure(LocationAcquisitionResult.unavailable);
      services = await platform.servicesEnabled();
      if (!current()) return failure(LocationAcquisitionResult.unavailable);
      var observed = await platform.permission();
      permission = _permission(observed);
      if (!current()) return failure(LocationAcquisitionResult.unavailable);
      if (!services) {
        return failure(LocationAcquisitionResult.locationServicesDisabled);
      }
      if (observed == ForegroundPermission.denied) {
        observed = await platform.requestPermission();
        permission = _permission(observed);
        if (!current()) return failure(LocationAcquisitionResult.unavailable);
      }
      if (permission == LocationPermissionState.denied) {
        return failure(LocationAcquisitionResult.permissionDenied);
      }
      final fix = await platform.currentFix(fixLimit);
      if (!current()) return failure(LocationAcquisitionResult.unavailable);
      if (fix == null) return failure(LocationAcquisitionResult.unavailable);
      double? finite(double? value) => value?.isFinite == true ? value : null;
      return LocationEvidence(
        latitude: finite(fix.latitude),
        longitude: finite(fix.longitude),
        accuracyMeters: finite(fix.accuracyMeters),
        observedAt: fix.observedAt,
        permission: permission,
        servicesEnabled: services,
        result: LocationAcquisitionResult.fix,
        provider: fix.provider,
      );
    } on ForegroundLocationFailure catch (error) {
      return failure(error.result);
    } catch (_) {
      return failure(LocationAcquisitionResult.providerError);
    } finally {
      _busy = false;
    }
  }
}

LocationPermissionState _permission(ForegroundPermission value) =>
    switch (value) {
      ForegroundPermission.precise => LocationPermissionState.precise,
      ForegroundPermission.approximate => LocationPermissionState.approximate,
      ForegroundPermission.denied ||
      ForegroundPermission.deniedForever => LocationPermissionState.denied,
      ForegroundPermission.unknown => LocationPermissionState.unknown,
    };
