import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../attendance_models.dart';
import '../journal/android_journal_storage.dart';

/// Supported old adapters in this APK only. Cannot cancel submitted work,
/// fence old APKs, establish provenance, or certify server maintenance/drain.
Future<void> requireLegacyWriterAllowed() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final value = await const MethodChannel(AndroidJournalStorage.channelName)
        .invokeMethod<Object?>('requireOldWriterAllowedV1', {'api_version': 1});
    if (value is! Map || value.length != 1 || value['status'] != 'allowed') {
      throw const FormatException();
    }
  } catch (_) {
    throw const AttendanceFailure(AttendanceFailureKind.contractUnavailable);
  }
}
