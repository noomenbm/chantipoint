import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'command_journal.dart';
import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_recovery.dart';

/// Opt-in only. Main and the legacy controller do not instantiate this adapter.
/// The channel carries plaintext in process; only native encrypted files persist.
class AndroidJournalStorage implements JournalStorage {
  const AndroidJournalStorage({
    this._channel = const MethodChannel(channelName),
  });

  static const channelName = 'chantipoint/secure_command_journal';
  static const apiVersion = 1;
  final MethodChannel _channel;

  static const errorCodes = <String, JournalIssue>{
    'journal_corrupt': JournalIssue.corrupt,
    'journal_unreadable': JournalIssue.unreadable,
    'journal_missing_key': JournalIssue.missingKey,
    'journal_invalidated_key': JournalIssue.invalidatedKey,
    'journal_authentication_failed': JournalIssue.authenticationFailed,
    'journal_unsupported_container': JournalIssue.unsupportedContainer,
    'journal_unsupported_format': JournalIssue.unsupportedFormat,
    'journal_identity_mismatch': JournalIssue.identityMismatch,
    'journal_revision_conflict': JournalIssue.revisionConflict,
    'journal_command_conflict': JournalIssue.commandConflict,
    'journal_illegal_transition': JournalIssue.illegalTransition,
    'journal_storage_failure': JournalIssue.storageFailure,
    'journal_sync_failure': JournalIssue.synchronizationFailure,
    'journal_native_failure': JournalIssue.nativeFailure,
    'journal_unsupported_platform': JournalIssue.unsupportedPlatform,
  };

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<JournalStorageRead> read(JournalBinding binding) async {
    if (!_supported) {
      return const JournalStorageRead.failure(JournalIssue.unsupportedPlatform);
    }
    try {
      final response = await _channel.invokeMethod<Object?>('read', {
        'api_version': apiVersion,
        'binding': binding.toJson(),
      });
      if (response is! Map) {
        return const JournalStorageRead.failure(JournalIssue.nativeFailure);
      }
      if (response['status'] == 'absent' && response.length == 1) {
        return const JournalStorageRead.absent();
      }
      if (response['status'] == 'recovery_required' && response.length == 1) {
        return await _recover(binding);
      }
      if (response['status'] != 'stored' ||
          response.length != 2 ||
          response['record'] is! Uint8List) {
        return const JournalStorageRead.failure(JournalIssue.nativeFailure);
      }
      final bytes = response['record'] as Uint8List;
      final checked = JournalCodec.decode(bytes, binding);
      return checked.issue == null
          ? JournalStorageRead.bytes(bytes)
          : JournalStorageRead.failure(checked.issue!);
    } on JournalException catch (error) {
      return JournalStorageRead.failure(error.issue);
    } on MissingPluginException {
      return const JournalStorageRead.failure(JournalIssue.unsupportedPlatform);
    } on PlatformException catch (error) {
      return JournalStorageRead.failure(
        errorCodes[error.code] ?? JournalIssue.nativeFailure,
      );
    } catch (_) {
      return const JournalStorageRead.failure(JournalIssue.nativeFailure);
    }
  }

  Future<JournalStorageRead> _recover(JournalBinding binding) async {
    final inspection = await _channel.invokeMethod<Object?>(
      'inspectRecoveryV1',
      {'api_version': apiVersion, 'binding': binding.toJson()},
    );
    final plan = JournalRecoveryPlan.inspect(inspection, binding);
    if (!plan.needsNormalization) return JournalStorageRead.bytes(plan.record);
    final response = await _channel.invokeMethod<Object?>(
      'normalizeRecoveryV1',
      {
        'api_version': apiVersion,
        'binding': binding.toJson(),
        'snapshot': plan.snapshot,
        'validated_record': Uint8List.fromList(plan.record),
      },
    );
    if (response is! Map ||
        response.length != 2 ||
        response['status'] != 'stored' ||
        response['record'] is! Uint8List) {
      return const JournalStorageRead.failure(JournalIssue.nativeFailure);
    }
    final bytes = response['record'] as Uint8List;
    final checked = JournalCodec.decode(bytes, binding);
    if (checked.issue != null) {
      return JournalStorageRead.failure(checked.issue!);
    }
    if (!JournalRecoveryPlan.sameRecordBytes(plan.record, bytes)) {
      return const JournalStorageRead.failure(JournalIssue.nativeFailure);
    }
    return JournalStorageRead.bytes(bytes);
  }

  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    if (!_supported) return JournalIssue.unsupportedPlatform;
    try {
      journalInteger(expectedRevision);
      if (expectedKey != null) journalText(expectedKey, max: 160);
      if (replacement.length > JournalJson.recordLimit) {
        return JournalIssue.corrupt;
      }
      // Snapshot BEFORE validation and validate BEFORE Uint8List conversion,
      // which would otherwise truncate invalid integer values.
      final frozen = List<int>.unmodifiable(replacement);
      final checked = JournalCodec.decode(frozen, binding);
      if (checked.issue != null) return checked.issue;
      final record = checked.record!;
      if (record.revision != expectedRevision + 1) {
        return JournalIssue.revisionConflict;
      }
      if (expectedKey != null &&
          record.command != null &&
          record.command!.key != expectedKey) {
        return JournalIssue.commandConflict;
      }
      final bytes = Uint8List.fromList(frozen);
      final response = await _channel.invokeMethod<Object?>('compareAndSwap', {
        'api_version': apiVersion,
        'binding': binding.toJson(),
        'expected_revision': expectedRevision,
        'expected_key': expectedKey,
        'replacement': bytes,
      });
      if (response is! Map ||
          response.length != 2 ||
          response['status'] != 'written' ||
          response['revision'] is! int ||
          response['revision'] != record.revision) {
        return JournalIssue.nativeFailure;
      }
      return null;
    } on JournalException catch (error) {
      return error.issue;
    } on MissingPluginException {
      return JournalIssue.unsupportedPlatform;
    } on PlatformException catch (error) {
      return errorCodes[error.code] ?? JournalIssue.nativeFailure;
    } catch (_) {
      return JournalIssue.nativeFailure;
    }
  }
}
