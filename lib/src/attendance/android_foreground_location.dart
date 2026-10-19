import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'foreground_location.dart';
import 'location_evidence.dart';

/// Opt-in Android channel. No live attendance composition or dependency on auth.
final class AndroidForegroundLocation implements ForegroundLocationPlatform {
  const AndroidForegroundLocation({
    this._channel = const MethodChannel(channelName),
  });
  static const channelName = 'chantipoint/foreground_location';
  final MethodChannel _channel;

  Future<Object?> _call(
    String method, [
    Map<String, Object?> extra = const {},
  ]) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.unavailable,
      );
    }
    try {
      return await _channel.invokeMethod<Object?>(method, {
        'api_version': 1,
        ...extra,
      });
    } on ForegroundLocationFailure {
      rethrow;
    } on MissingPluginException {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.unavailable,
      );
    } on PlatformException catch (error) {
      throw ForegroundLocationFailure(
        error.code == 'location_unavailable'
            ? LocationAcquisitionResult.unavailable
            : LocationAcquisitionResult.providerError,
      );
    } catch (_) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
  }

  @override
  Future<bool> servicesEnabled() async {
    final result = await _call('servicesV1');
    if (result is! bool) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    return result;
  }

  Future<ForegroundPermission> _permission(String method) async =>
      switch (await _call(method)) {
        'precise' => ForegroundPermission.precise,
        'approximate' => ForegroundPermission.approximate,
        'denied' => ForegroundPermission.denied,
        'denied_forever' => ForegroundPermission.deniedForever,
        'unknown' => ForegroundPermission.unknown,
        _ => throw const ForegroundLocationFailure(
          LocationAcquisitionResult.providerError,
        ),
      };
  @override
  Future<ForegroundPermission> permission() => _permission('permissionV1');
  @override
  Future<ForegroundPermission> requestPermission() =>
      _permission('requestPermissionV1');

  @override
  Future<ForegroundFix?> currentFix(Duration limit) async {
    try {
      return await _currentFix(limit);
    } on ForegroundLocationFailure {
      rethrow;
    } catch (_) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
  }

  Future<ForegroundFix?> _currentFix(Duration limit) async {
    if (limit <= Duration.zero || limit > ForegroundLocationService.fixLimit) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    final result = await _call('fixV1', {'limit_ms': limit.inMilliseconds});
    if (result is! Map || result['result'] is! String) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    final status = LocationAcquisitionResult.values
        .where((e) => e.sqlValue == result['result'])
        .firstOrNull;
    if (status == null) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    if (status != LocationAcquisitionResult.fix) {
      if (result.length != 1) {
        throw const ForegroundLocationFailure(
          LocationAcquisitionResult.providerError,
        );
      }
      throw ForegroundLocationFailure(status);
    }
    if (result.length != 6 ||
        !result.keys.toSet().containsAll({
          'result',
          'latitude',
          'longitude',
          'accuracy_meters',
          'observed_at_millis',
          'provider',
        })) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    double? number(Object? value) {
      if (value == null) return null;
      if (value is! num) {
        throw const ForegroundLocationFailure(
          LocationAcquisitionResult.providerError,
        );
      }
      return value.toDouble();
    }

    final time = result['observed_at_millis'];
    if (time != null && time is! int) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    final provider = LocationProvider.values
        .where((e) => e.sqlValue == result['provider'])
        .firstOrNull;
    if (provider == null) {
      throw const ForegroundLocationFailure(
        LocationAcquisitionResult.providerError,
      );
    }
    return ForegroundFix(
      latitude: number(result['latitude']),
      longitude: number(result['longitude']),
      accuracyMeters: number(result['accuracy_meters']),
      observedAt: time == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(time as int, isUtc: true),
      provider: provider,
    );
  }
}
