import 'package:chantipoint/src/attendance/foreground_location.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';

// Fictional fixes and RAM-only platform. No device location, services or RPCs.
class FakeForegroundPlatform implements ForegroundLocationPlatform {
  final calls = <String>[];
  bool services = true;
  ForegroundPermission granted = ForegroundPermission.precise;
  ForegroundPermission requested = ForegroundPermission.precise;
  Future<ForegroundPermission> Function()? onRequest;
  Future<ForegroundFix?> Function()? onFix;
  ForegroundFix? fix = ForegroundFix(
    latitude: 45.123456789,
    longitude: -73.234567891,
    accuracyMeters: 12.345,
    observedAt: DateTime.utc(2026, 10, 18, 12, 0, 2),
  );
  @override
  Future<bool> servicesEnabled() async {
    calls.add('services');
    return services;
  }

  @override
  Future<ForegroundPermission> permission() async {
    calls.add('permission');
    return granted;
  }

  @override
  Future<ForegroundPermission> requestPermission() async {
    calls.add('request');
    return onRequest == null ? requested : await onRequest!();
  }

  @override
  Future<ForegroundFix?> currentFix(Duration limit) async {
    calls.add('fix:${limit.inMilliseconds}');
    return onFix == null ? fix : await onFix!();
  }
}

class FakeLocationAcquisition implements ForegroundLocationAcquisition {
  int calls = 0;
  LocationEvidence evidence = const LocationEvidence(
    result: LocationAcquisitionResult.timeout,
  );
  Future<LocationEvidence> Function()? onAcquire;
  @override
  Future<LocationEvidence> acquire({bool Function()? isCurrent}) async {
    calls++;
    return onAcquire == null ? evidence : await onAcquire!();
  }
}
