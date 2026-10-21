import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../journal/journal_command.dart';
import '../journal/journal_json.dart';
import '../journal/android_journal_storage.dart';
import 'session_note_ports.dart';
import 'session_note_record.dart';

/// Separate no-backup native namespace/keys/schema. No attendance journal calls,
/// plaintext fallback, file deletion or implicit AtomicFile sidecar recovery.
final class AndroidSessionNoteStorage implements SessionNoteStorage {
  const AndroidSessionNoteStorage({
    this._channel = const MethodChannel(channelName),
  });
  static const channelName = 'chantipoint/secure_session_notes';
  final MethodChannel _channel;
  Future<Map<Object?, Object?>> _call(
    String method,
    Map<String, dynamic> args,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const JournalException(JournalIssue.unsupportedPlatform);
    }
    try {
      final value = await _channel.invokeMethod<Object?>(method, {
        'api_version': 1,
        ...args,
      });
      if (value is! Map) invalidJournal();
      return value.cast<Object?, Object?>();
    } on JournalException {
      rethrow;
    } on PlatformException catch (error) {
      throw JournalException(
        AndroidJournalStorage.errorCodes[error.code] ??
            JournalIssue.nativeFailure,
      );
    } on MissingPluginException {
      throw const JournalException(JournalIssue.unsupportedPlatform);
    } catch (_) {
      throw const JournalException(JournalIssue.nativeFailure);
    }
  }

  SessionNoteRecord _record(
    Map<Object?, Object?> value,
    JournalBinding binding,
    String status,
  ) {
    if (value.length != 2 ||
        value['status'] != status ||
        value['record'] is! Uint8List) {
      invalidJournal();
    }
    return SessionNoteRecord.decode(value['record'] as Uint8List, binding);
  }

  @override
  Future<SessionNoteRecord?> read(JournalBinding binding) async {
    final value = await _call('read', {'binding': binding.toJson()});
    if (value.length == 1 && value['status'] == 'absent') return null;
    if (value.length == 1 && value['status'] == 'recovery_required') {
      throw const JournalException(JournalIssue.unreadable);
    }
    return _record(value, binding, 'stored');
  }

  @override
  Future<void> compareAndSwap(
    SessionNoteRecord previous,
    SessionNoteRecord next,
  ) async {
    if (!previous.binding.matches(next.binding) ||
        next.revision != previous.revision + 1) {
      invalidJournal();
    }
    final checked = SessionNoteRecord.decode(next.bytes, previous.binding);
    final value = await _call('compareAndSwap', {
      'binding': previous.binding.toJson(),
      'expected_revision': previous.revision,
      'expected_key': previous.command?.key,
      'replacement': Uint8List.fromList(checked.bytes),
    });
    if (value.length != 2 ||
        value['status'] != 'written' ||
        value['revision'] is! int ||
        value['revision'] != next.revision) {
      invalidJournal();
    }
  }

  @override
  Future<void> verify(SessionNoteRecord record) async {
    final expected = SessionNoteRecord.decode(record.bytes, record.binding);
    final value = await _call('verifyRecordV1', {
      'binding': record.binding.toJson(),
      'expected_record': Uint8List.fromList(expected.bytes),
    });
    final actual = _record(value, record.binding, 'record_verified');
    if (!listEquals(actual.bytes, expected.bytes)) {
      throw const JournalException(JournalIssue.revisionConflict);
    }
  }
}
