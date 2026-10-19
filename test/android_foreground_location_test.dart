import 'dart:async';

import 'package:chantipoint/src/attendance/android_foreground_location.dart';
import 'package:chantipoint/src/attendance/foreground_location.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidForegroundLocation.channelName);
  const adapter = AndroidForegroundLocation(channel: channel);
  late Future<Object?> Function(MethodCall) handler;
  final calls = <MethodCall>[];
  final fix = <String, Object?>{
    'result': 'fix',
    'latitude': 45.123456789,
    'longitude': -73.234567891,
    'accuracy_meters': 15.123456,
    'observed_at_millis': DateTime.utc(
      2026,
      10,
      18,
      12,
      0,
      2,
    ).millisecondsSinceEpoch,
    'provider': 'unknown',
  };
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    handler = (call) async => switch (call.method) {
      'servicesV1' => true,
      'permissionV1' || 'requestPermissionV1' => 'precise',
      _ => fix,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return handler(call);
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'narrow versioned methods; native bound only after permission',
    () async {
      expect(await adapter.servicesEnabled(), isTrue);
      expect(await adapter.permission(), ForegroundPermission.precise);
      expect(await adapter.requestPermission(), ForegroundPermission.precise);
      final position = (await adapter.currentFix(const Duration(seconds: 15)))!;
      expect(position.latitude, fix['latitude']);
      expect(position.longitude, fix['longitude']);
      expect(position.accuracyMeters, fix['accuracy_meters']);
      expect(
        position.observedAt!.millisecondsSinceEpoch,
        fix['observed_at_millis'],
      );
      expect(position.observedAt!.isUtc, isTrue);
      expect(position.provider, LocationProvider.unknown);
      expect(calls.map((e) => e.method), [
        'servicesV1',
        'permissionV1',
        'requestPermissionV1',
        'fixV1',
      ]);
      expect(
        calls
            .take(3)
            .every((e) => mapEquals(e.arguments as Map, {'api_version': 1})),
        isTrue,
      );
      expect(calls.last.arguments, {'api_version': 1, 'limit_ms': 15000});
    },
  );
  for (final permission in {
    'precise': ForegroundPermission.precise,
    'approximate': ForegroundPermission.approximate,
    'unknown': ForegroundPermission.unknown,
    'denied': ForegroundPermission.denied,
    'denied_forever': ForegroundPermission.deniedForever,
  }.entries) {
    test('native permission ${permission.key}', () async {
      handler = (_) async => permission.key;
      expect(await adapter.permission(), permission.value);
      expect(await adapter.requestPermission(), permission.value);
    });
  }
  for (final result in [
    LocationAcquisitionResult.timeout,
    LocationAcquisitionResult.permissionDenied,
    LocationAcquisitionResult.locationServicesDisabled,
    LocationAcquisitionResult.providerError,
    LocationAcquisitionResult.unavailable,
  ]) {
    test('settled native $result yields evidence', () async {
      handler = (call) async => switch (call.method) {
        'fixV1' => {'result': result.sqlValue},
        'permissionV1' => 'precise',
        _ => true,
      };
      final evidence = await ForegroundLocationService(adapter).acquire();
      expect(evidence.result, result);
      expect(evidence.observedAt, isNull);
      expect(evidence.latitude, isNull);
    });
  }
  for (final provider in LocationProvider.values) {
    test(
      'native provider ${provider.name} preserved without inference',
      () async {
        handler = (_) async => {...fix, 'provider': provider.sqlValue};
        expect(
          (await adapter.currentFix(const Duration(seconds: 15)))!.provider,
          provider,
        );
      },
    );
  }
  final malformed = <Object?>[
    null,
    [],
    {},
    {'result': 'unknown-protocol'},
    {...fix, 'latitude': '45'},
    {...fix, 'observed_at_millis': 'today'},
    {...fix, 'provider': 'GPS'},
    {...fix, 'observed_at_millis': 9007199254740991},
    {...fix, 'extra': 1},
    {...fix}..remove('accuracy_meters'),
    {'result': 'timeout', 'latitude': 45},
  ];
  for (var i = 0; i < malformed.length; i++) {
    test('malformed fix $i never invents evidence or exposes input', () async {
      handler = (_) async => malformed[i];
      await expectLater(
        adapter.currentFix(const Duration(seconds: 15)),
        throwsA(
          isA<ForegroundLocationFailure>().having(
            (e) => e.result,
            'safe code',
            LocationAcquisitionResult.providerError,
          ),
        ),
      );
    });
  }
  test('null optional fix fields are not filled from a local clock', () async {
    handler = (_) async => {
      ...fix,
      'latitude': null,
      'accuracy_meters': null,
      'observed_at_millis': null,
    };
    final position = (await adapter.currentFix(const Duration(seconds: 15)))!;
    expect(position.latitude, isNull);
    expect(position.accuracyMeters, isNull);
    expect(position.observedAt, isNull);
  });
  for (final duration in [
    Duration.zero,
    const Duration(seconds: -1),
    const Duration(seconds: 16),
  ]) {
    test('invalid duration $duration never starts native work', () async {
      await expectLater(
        adapter.currentFix(duration),
        throwsA(isA<ForegroundLocationFailure>()),
      );
      expect(calls, isEmpty);
    });
  }
  test(
    'no early Dart timeout before native settlement/acknowledgement',
    () async {
      final native = Completer<Object?>();
      handler = (_) => native.future;
      var complete = false;
      final pending = adapter
          .currentFix(const Duration(milliseconds: 1))
          .then((_) => complete = true, onError: (Object _) => complete = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(complete, isFalse);
      expect(calls.length, 1);
      native.complete({'result': 'timeout'});
      await pending;
      expect(complete, isTrue);
    },
  );
  test('unsupported platform and missing plugin fail safely', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await expectLater(
      adapter.permission(),
      throwsA(isA<ForegroundLocationFailure>()),
    );
    expect(calls, isEmpty);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    handler = (_) async => throw MissingPluginException('private');
    expect(
      (await ForegroundLocationService(adapter).acquire()).result,
      LocationAcquisitionResult.unavailable,
    );
  });
  for (final error in [
    PlatformException(code: 'location_unavailable', message: 'private'),
    PlatformException(code: 'unexpected', message: 'private'),
    StateError('private'),
  ]) {
    test(
      'private ${error.runtimeType}/${error.hashCode} becomes safe typed evidence',
      () async {
        handler = (_) async => throw error;
        final evidence = await ForegroundLocationService(adapter).acquire();
        expect(
          evidence.result,
          error is PlatformException && error.code == 'location_unavailable'
              ? LocationAcquisitionResult.unavailable
              : LocationAcquisitionResult.providerError,
        );
        expect(evidence.latitude, isNull);
      },
    );
  }
}
