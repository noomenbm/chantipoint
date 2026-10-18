import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'android_journal_storage.dart';
import 'command_journal.dart';
import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_record.dart';
import 'journal_recovery.dart';
import 'legacy_journal_import.dart';
import 'legacy_journal_migration.dart';

/// Immutable observation, not provenance, writer fencing or a cleanup permit.
final class AndroidLegacySourceInspection {
  const AndroidLegacySourceInspection._(
    this.binding,
    this.source,
    this.identity,
  );
  final JournalBinding binding;
  final LegacySourceSnapshot source;
  final String identity;
}

/// Isolated mechanical primitives. Native cleanup rejects the normal app package.
/// No approval issuance, coordinator, journal transition or startup integration.
class AndroidLegacyMigration {
  const AndroidLegacyMigration({
    this.channel = const MethodChannel(AndroidJournalStorage.channelName),
  });
  final MethodChannel channel;

  Future<T> _guard<T>(Future<T> Function() operation) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const JournalException(JournalIssue.unsupportedPlatform);
    }
    try {
      return await operation();
    } on JournalException {
      rethrow;
    } on MissingPluginException {
      throw const JournalException(JournalIssue.unsupportedPlatform);
    } on PlatformException catch (error) {
      throw JournalException(
        AndroidJournalStorage.errorCodes[error.code] ??
            JournalIssue.nativeFailure,
      );
    } catch (_) {
      throw const JournalException(JournalIssue.nativeFailure);
    }
  }

  static String _basename(JournalBinding binding) {
    final owner = '${binding.companyId}:${binding.profileId}';
    return 'attendance_${base64Url.encode(utf8.encode(owner)).replaceAll('=', '')}.json';
  }

  static Never _malformed() =>
      throw const JournalException(JournalIssue.nativeFailure);

  /// Strict parsing is validation only; no historical project is inferred.
  Future<AndroidLegacySourceInspection> inspect(JournalBinding binding) =>
      _guard(() async {
        final response = await channel.invokeMethod<Object?>(
          'inspectLegacySourceV1',
          {'api_version': 1, 'binding': binding.toJson()},
        );
        if (response is! Map ||
            response.length != 6 ||
            response['inspection_version'] is! int ||
            response['inspection_version'] != 1 ||
            response['binding'] is! Map ||
            response['snapshot'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$')
                .hasMatch(response['snapshot'] as String) ||
            response['basename'] != _basename(binding) ||
            !response.containsKey('source') ||
            (response['source'] != null && response['source'] is! Uint8List) ||
            response['artifacts'] is! List) {
          _malformed();
        }
        final actualBinding = JournalBinding.fromJson(
          Map<String, dynamic>.from(response['binding'] as Map),
        );
        if (!actualBinding.matches(binding)) {
          throw const JournalException(JournalIssue.identityMismatch);
        }
        final artifacts = response['artifacts'] as List;
        if (artifacts.length > 8) _malformed();
        var total = (response['source'] as Uint8List?)?.length ?? 0;
        final kinds = <LegacySourceArtifact>{};
        String? previous;
        for (final artifact in artifacts) {
          if (artifact is! Map ||
              artifact.length != 2 ||
              artifact['suffix'] is! String ||
              artifact['bytes'] is! Uint8List) {
            _malformed();
          }
          final suffix = artifact['suffix'] as String;
          journalText(suffix, max: 64);
          if (!suffix.startsWith('.') ||
              suffix.contains('/') ||
              suffix.contains('\\') ||
              (previous != null && previous.compareTo(suffix) >= 0)) {
            _malformed();
          }
          previous = suffix;
          total += (artifact['bytes'] as Uint8List).length;
          kinds.add(
            suffix == '.tmp'
                ? LegacySourceArtifact.temporary
                : LegacySourceArtifact.unexpected,
          );
        }
        if (total > JournalJson.recordLimit) {
          throw const JournalException(JournalIssue.corrupt);
        }
        final bytes = response['source'] as Uint8List?;
        final source = bytes == null
            ? LegacySourceSnapshot.absent(artifacts: kinds)
            : LegacySourceSnapshot.file(
                basename: _basename(binding),
                bytes: bytes,
                artifacts: kinds,
              );
        if (source.bytes != null) {
          final parsed = LegacyJournalImport.prepare(source.bytes!);
          if (parsed.issue != JournalIssue.bindingRequired) {
            throw JournalException(parsed.issue ?? JournalIssue.corrupt);
          }
          // The strict parser checks shape, not membership in this binding.
          final owner = journalObject(
            JournalJson.decode(source.bytes!),
          )['owner'];
          if (owner != '${binding.companyId}:${binding.profileId}') {
            throw const JournalException(JournalIssue.identityMismatch);
          }
        }
        return AndroidLegacySourceInspection._(
          binding,
          source,
          response['snapshot'] as String,
        );
      });

  Future<void> verifyTarget(JournalBinding binding, List<int> expectedRecord) =>
      _targetOperation('verifyMigrationTargetV1', binding, expectedRecord);

  /// Returns only mechanical durable-absence success. It does not mark journal
  /// cleanup complete. A failure can occur after unlink: inspect again on retry.
  Future<void> cleanup(
    JournalBinding binding,
    List<int> expectedRecord,
    AndroidLegacySourceInspection source,
  ) => _targetOperation(
    'cleanupLegacySourceV1',
    binding,
    expectedRecord,
    source,
  );

  Future<void> _targetOperation(
    String method,
    JournalBinding binding,
    List<int> expectedRecord, [
    AndroidLegacySourceInspection? source,
  ]) => _guard(() async {
    if (expectedRecord.length > JournalJson.recordLimit) {
      throw const JournalException(JournalIssue.corrupt);
    }
    final frozen = List<int>.unmodifiable(expectedRecord);
    final checked = JournalCodec.decode(frozen, binding);
    if (checked.issue != null) throw JournalException(checked.issue!);
    final record = checked.record!;
    final migration = record.migration;
    if (!const {
          JournalPhase.uncertain,
          JournalPhase.confirmed,
        }.contains(record.phase) ||
        record.command?.protocol != JournalProtocol.legacyV1 ||
        migration == null ||
        migration.plaintextCleanupComplete) {
      throw const JournalException(JournalIssue.illegalTransition);
    }
    if (migration.sourceBasename != _basename(binding)) {
      throw const JournalException(JournalIssue.identityMismatch);
    }
    if (source != null) {
      if (!source.binding.matches(binding)) {
        throw const JournalException(JournalIssue.identityMismatch);
      }
      if (source.source.artifacts.isNotEmpty) {
        throw const JournalException(JournalIssue.unreadable);
      }
    }
    final args = <String, Object?>{
      'api_version': 1,
      'binding': binding.toJson(),
      'expected_record': Uint8List.fromList(frozen),
      if (source != null) 'source_snapshot': source.identity,
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      final response = await channel.invokeMethod<Object?>(method, args);
      if (response is Map &&
          response.length == 1 &&
          response['status'] == 'recovery_required') {
        if (attempt != 0) throw const JournalException(JournalIssue.unreadable);
        // Existing C2b.1 policy owns ALL normalization decisions. Native rechecks
        // after this call; neither target changes nor a second race is accepted.
        final recovered = await AndroidJournalStorage(channel: channel)
            .read(binding);
        if (recovered.issue != null) throw JournalException(recovered.issue!);
        if (recovered.bytes == null ||
            !JournalRecoveryPlan.sameRecordBytes(recovered.bytes!, frozen)) {
          throw const JournalException(JournalIssue.revisionConflict);
        }
        continue;
      }
      if (response is! Map ||
          response.length != 2 ||
          response['status'] !=
              (source == null ? 'target_verified' : 'source_absent') ||
          response['record'] is! Uint8List) {
        _malformed();
      }
      final verified = response['record'] as Uint8List;
      final validated = JournalCodec.decode(verified, binding);
      if (validated.issue != null) throw JournalException(validated.issue!);
      if (!JournalRecoveryPlan.sameRecordBytes(verified, frozen)) _malformed();
      return;
    }
  });
}
