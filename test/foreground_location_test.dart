import 'dart:async';

import 'package:chantipoint/src/attendance/foreground_location.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_foreground_location.dart';

void main() {
  late FakeForegroundPlatform platform;
  late ForegroundLocationService service;
  setUp(() {
    platform = FakeForegroundPlatform();
    service = ForegroundLocationService(platform);
  });
  for (final permission in [
    ForegroundPermission.precise,
    ForegroundPermission.approximate,
    ForegroundPermission.unknown,
  ]) {
    test('$permission comes from platform, never fix quality', () async {
      platform.granted = permission;
      final evidence = await service.acquire();
      expect(evidence.permission?.sqlValue, permission.name);
      expect(evidence.result, LocationAcquisitionResult.fix);
      expect(evidence.latitude, platform.fix!.latitude);
      expect(evidence.longitude, platform.fix!.longitude);
      expect(evidence.accuracyMeters, platform.fix!.accuracyMeters);
      expect(evidence.observedAt, platform.fix!.observedAt);
      expect(evidence.provider, LocationProvider.unknown);
      expect(platform.calls, ['services', 'permission', 'fix:15000']);
    });
  }
  for (final result in ForegroundPermission.values) {
    test('permission request produces $result before fix deadline', () async {
      final permission = Completer<ForegroundPermission>();
      platform.granted = ForegroundPermission.denied;
      platform.onRequest = () => permission.future;
      final future = service.acquire();
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls, ['services', 'permission', 'request']);
      permission.complete(result);
      final evidence = await future;
      final denied = [
        ForegroundPermission.denied,
        ForegroundPermission.deniedForever,
      ].contains(result);
      expect(
        evidence.result,
        denied
            ? LocationAcquisitionResult.permissionDenied
            : LocationAcquisitionResult.fix,
      );
      expect(
        platform.calls.where((c) => c.startsWith('fix:')).length,
        denied ? 0 : 1,
      );
    });
  }
  test('denied forever does not prompt or acquire', () async {
    platform.granted = ForegroundPermission.deniedForever;
    final result = await service.acquire();
    expect(result.permission, LocationPermissionState.denied);
    expect(result.result, LocationAcquisitionResult.permissionDenied);
    expect(result.latitude, isNull);
    expect(result.observedAt, isNull);
    expect(platform.calls, ['services', 'permission']);
  });
  test(
    'disabled services observed with permission, without prompting/fix',
    () async {
      platform.services = false;
      platform.granted = ForegroundPermission.denied;
      final result = await service.acquire();
      expect(result.servicesEnabled, isFalse);
      expect(result.result, LocationAcquisitionResult.locationServicesDisabled);
      expect(result.latitude, isNull);
      expect(platform.calls, ['services', 'permission']);
    },
  );
  for (final result in [
    LocationAcquisitionResult.timeout,
    LocationAcquisitionResult.providerError,
    LocationAcquisitionResult.unavailable,
    LocationAcquisitionResult.permissionDenied,
    LocationAcquisitionResult.locationServicesDisabled,
  ]) {
    test('$result is evidence, no invented fix/time', () async {
      platform.onFix = () async => throw ForegroundLocationFailure(result);
      final evidence = await service.acquire();
      expect(evidence.result, result);
      expect(evidence.latitude, isNull);
      expect(evidence.longitude, isNull);
      expect(evidence.observedAt, isNull);
      expect(evidence.accuracyMeters, isNull);
      if (result == LocationAcquisitionResult.permissionDenied) {
        expect(evidence.permission, LocationPermissionState.denied);
      }
      if (result == LocationAcquisitionResult.locationServicesDisabled) {
        expect(evidence.servicesEnabled, isFalse);
      }
    });
  }
  test(
    'null fix and private provider exception return safe evidence',
    () async {
      platform.fix = null;
      expect(
        (await service.acquire()).result,
        LocationAcquisitionResult.unavailable,
      );
      platform.onFix = () async => throw StateError('private provider detail');
      expect(
        (await service.acquire()).result,
        LocationAcquisitionResult.providerError,
      );
    },
  );
  for (final accuracy in [0.0, -1.0, 99999.123456]) {
    test('finite low quality $accuracy preserved for server', () async {
      final oldTime = DateTime.utc(2000);
      platform.fix = ForegroundFix(
        latitude: 100,
        longitude: -190,
        accuracyMeters: accuracy,
        observedAt: oldTime,
      );
      final result = await service.acquire();
      expect(result.latitude, 100);
      expect(result.longitude, -190);
      expect(result.accuracyMeters, accuracy);
      expect(result.observedAt, oldTime);
      expect(result.toRpcParameters()['p_location_result'], 'fix');
    });
  }
  test('nonfinite fields become null; other finite claims survive', () async {
    platform.fix = const ForegroundFix(
      latitude: double.nan,
      longitude: -73.25,
      accuracyMeters: double.infinity,
    );
    final result = await service.acquire();
    expect(result.latitude, isNull);
    expect(result.longitude, -73.25);
    expect(result.accuracyMeters, isNull);
    expect(result.observedAt, isNull);
    expect(() => result.toRpcParameters(), returnsNormally);
  });
  for (final provider in LocationProvider.values) {
    test('provider $provider only from platform claim', () async {
      platform.fix = ForegroundFix(
        latitude: 1,
        longitude: 2,
        provider: provider,
      );
      expect((await service.acquire()).provider, provider);
    });
  }
  test(
    'delayed native settlement is awaited; duplicate acquire starts no fix',
    () async {
      final native = Completer<ForegroundFix?>();
      platform.onFix = () => native.future;
      var completed = false;
      final first = service.acquire().then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        (await service.acquire()).result,
        LocationAcquisitionResult.unavailable,
      );
      expect(completed, isFalse);
      expect(platform.calls.where((c) => c.startsWith('fix:')).length, 1);
      native.completeError(
        const ForegroundLocationFailure(LocationAcquisitionResult.timeout),
      );
      expect((await first).result, LocationAcquisitionResult.timeout);
      platform.onFix = null;
      expect((await service.acquire()).result, LocationAcquisitionResult.fix);
    },
  );
  test(
    'auth invalidation while permission pending never initiates a fix',
    () async {
      final permission = Completer<ForegroundPermission>();
      platform.granted = ForegroundPermission.denied;
      platform.onRequest = () => permission.future;
      var current = true;
      final future = service.acquire(isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      permission.complete(ForegroundPermission.precise);
      expect((await future).result, LocationAcquisitionResult.unavailable);
      expect(platform.calls, ['services', 'permission', 'request']);
    },
  );
  test(
    'invalidated late fix is discarded after actual platform settlement',
    () async {
      final native = Completer<ForegroundFix?>();
      platform.onFix = () => native.future;
      var current = true;
      final future = service.acquire(isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      native.complete(platform.fix);
      final result = await future;
      expect(result.result, LocationAcquisitionResult.unavailable);
      expect(result.latitude, isNull);
      expect(result.observedAt, isNull);
    },
  );
}
