import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'android_journal_storage.dart';
import 'command_journal.dart';
import 'journal_command.dart';
import 'journal_json.dart';
import 'journal_recovery.dart';
import 'journal_verifier.dart';

/// Opt-in; never composed into live attendance. Dart owns full schema validation,
/// native storage owns authentication, exact bytes, locks and the fresh barrier.
final class AndroidJournalVerifier implements JournalVerifier {
  const AndroidJournalVerifier({
    this._channel = const MethodChannel(AndroidJournalStorage.channelName),
  });
  final MethodChannel _channel;

  @override
  Future<JournalIssue?> verify(
    JournalBinding binding,
    List<int> expectedRecord,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return JournalIssue.unsupportedPlatform;
    }
    try {
      if (expectedRecord.length > JournalJson.recordLimit) {
        return JournalIssue.corrupt;
      }
      final frozen = List<int>.unmodifiable(expectedRecord);
      final checked = JournalCodec.decode(frozen, binding);
      if (checked.issue != null) return checked.issue;
      final response = await _channel.invokeMethod<Object?>('verifyRecordV1', {
        'api_version': 1,
        'binding': binding.toJson(),
        'expected_record': Uint8List.fromList(frozen),
      });
      if (response is! Map ||
          response.length != 2 ||
          response['status'] != 'record_verified' ||
          response['record'] is! Uint8List) {
        return JournalIssue.nativeFailure;
      }
      final actual = response['record'] as Uint8List;
      final readback = JournalCodec.decode(actual, binding);
      if (readback.issue != null) return readback.issue;
      return JournalRecoveryPlan.sameRecordBytes(frozen, actual)
          ? null
          : JournalIssue.revisionConflict;
    } on MissingPluginException {
      return JournalIssue.unsupportedPlatform;
    } on PlatformException catch (error) {
      return AndroidJournalStorage.errorCodes[error.code] ??
          JournalIssue.nativeFailure;
    } catch (_) {
      return JournalIssue.nativeFailure;
    }
  }
}
