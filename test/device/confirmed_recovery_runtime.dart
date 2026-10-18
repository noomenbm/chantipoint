// Fictional native barrier checks; no network, real journal or live composition.
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_verifier.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../support/fake_attendance_operation_ports.dart';
import '../support/journal_fixtures.dart';
import 'legacy_migration_runtime.dart' show RuntimeCheck;

const _storage = AndroidJournalStorage();
const _verifier = AndroidJournalVerifier();
const _control = MethodChannel('chantipoint/journal_test_control');
final _binding = journalBinding(environment: 'runtime-c34-confirmed');
final _original = JournalRecord.absent(_binding)
    .prepare(journalCommand())
    .markMayHaveSent()
    .confirm(journalConfirmation(journalCommand()));
final _bytes = JournalCodec.encode(_original);
void _require(bool value) {
  if (!value) throw StateError('Confirmed recovery runtime assertion failed.');
}

Future<Object?> _fixture(
  String method, [
  Map<String, Object?> extra = const {},
]) => _control.invokeMethod<Object?>(method, {
  'binding': _binding.toJson(),
  ...extra,
});
Future<void> _restore() async =>
    _fixture('replaceMain', {'record': Uint8List.fromList(_bytes)});
Future<void> _unchanged(JournalIssue issue) async {
  final before = await _fixture('fingerprint');
  _require(await _verifier.verify(_binding, _bytes) == issue);
  _require(await _fixture('fingerprint') == before);
}

Future<void> _coordinatorCheck() async {
  final events = <String>[];
  final transport = FictionalAttendanceTransport(events);
  final canonical = FictionalCanonicalReader(events);
  final issuer = FictionalAttendanceIssuer(_binding);
  final coordinator = AttendanceOperationCoordinator(
    storage: _storage,
    transport: transport,
    canonical: canonical,
    verifier: _verifier,
  );
  final result = await coordinator.recoverConfirmed(issuer.context());
  _require(result.outcome == AttendanceOperationOutcome.confirmed);
  _require(listEquals(JournalCodec.encode(result.snapshot!.record), _bytes));
  _require(transport.calls.isEmpty && canonical.calls.length == 1);
  _require(listEquals((await _storage.read(_binding)).bytes, _bytes));
}

Future<void> confirmedRecoveryFreshChecks(RuntimeCheck run) async {
  await run(
    'general barrier missing target fails without creating record',
    () async {
      await _unchanged(JournalIssue.commandConflict);
    },
  );
  await run(
    'general barrier verifies original complete confirmed v2 bytes',
    () async {
      final prepared = _original.command!;
      const journal = CommandJournal(_storage);
      _require(
        (await journal.prepare(
              _binding,
              prepared,
              expectedRevision: 0,
              expectedKey: null,
            )).issue ==
            null,
      );
      _require(
        (await journal.markMayHaveSent(
              _binding,
              expectedRevision: 1,
              expectedKey: prepared.key,
            )).issue ==
            null,
      );
      _require(
        (await journal.confirm(
              _binding,
              _original.confirmation!,
              expectedRevision: 2,
              expectedKey: prepared.key,
            )).issue ==
            null,
      );
      _require(await _verifier.verify(_binding, _bytes) == null);
    },
  );
  await run('general barrier refuses complete-record mismatch', () async {
    final changed = JournalRecord.fromJson({
      ..._original.toJson(),
      'revision': 4,
    });
    final before = await _fixture('fingerprint');
    _require(
      await _verifier.verify(_binding, JournalCodec.encode(changed)) ==
          JournalIssue.revisionConflict,
    );
    _require(await _fixture('fingerprint') == before);
  });
  for (final stage in [
    'record_file_sync',
    'record_directory_sync',
    'record_readback',
  ]) {
    await run('general barrier $stage failure preserves artifacts', () async {
      await _fixture('verificationFault', {'stage': stage});
      await _unchanged(JournalIssue.synchronizationFailure);
      _require(await _verifier.verify(_binding, _bytes) == null);
    });
  }
  await run('general barrier rejects target altered before readback', () async {
    final before = await _fixture('fingerprint');
    await _fixture('verificationFault', {'stage': 'change_readback'});
    _require(
      await _verifier.verify(_binding, _bytes) ==
          JournalIssue.authenticationFailed,
    );
    _require(await _fixture('fingerprint') != before);
    await _unchanged(JournalIssue.authenticationFailed);
    await _restore();
  });
  await run(
    'general barrier retains ambiguous sidecar without normalization',
    () async {
      await _fixture('sidecar', {
        'kind': 'new',
        'record': Uint8List.fromList(_bytes),
      });
      await _unchanged(JournalIssue.unreadable);
      // Explicit fixture cleanup ONLY; the verifier must never do this.
      await _fixture('removeFixtureSidecar', {'kind': 'new'});
    },
  );
  await run(
    'general barrier rejects authenticated wrong-binding record',
    () async {
      final wrong = JournalRecord.fromJson({
        ..._original.toJson(),
        'binding': journalBinding(environment: 'runtime-wrong-c34').toJson(),
      });
      await _fixture('replaceMain', {
        'record': Uint8List.fromList(JournalCodec.encode(wrong)),
      });
      await _unchanged(JournalIssue.identityMismatch);
      await _restore();
    },
  );
  await run(
    'general barrier rejects authenticated corrupt record without cleanup',
    () async {
      await _fixture('replaceMain', {
        'record': Uint8List.fromList([123]),
      });
      await _unchanged(JournalIssue.corrupt);
      await _restore();
    },
  );
  await run(
    'native verified coordinator replacement refreshes without dispatch',
    _coordinatorCheck,
  );
}

Future<void> confirmedRecoveryRestartChecks(RuntimeCheck run) async {
  await run(
    'general barrier verifies entire original receipt after force stop',
    () async {
      _require(listEquals((await _storage.read(_binding)).bytes, _bytes));
      _require(await _verifier.verify(_binding, _bytes) == null);
    },
  );
  await run(
    'restarted coordinator uses native barrier without attendance dispatch',
    _coordinatorCheck,
  );
}
