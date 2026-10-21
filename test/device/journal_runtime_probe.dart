// Dedicated non-UI Dart entrypoint for the isolated journal instrumentation APK.
// No Supabase initialization, RPC dispatch, GPS acquisition or live controller.
import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../support/journal_fixtures.dart';
import 'legacy_migration_runtime.dart';
import 'legacy_coordinator_runtime.dart';
import 'confirmed_recovery_runtime.dart';
import 'session_note_runtime.dart';

const _control = MethodChannel('chantipoint/journal_test_control');
const _native = MethodChannel(AndroidJournalStorage.channelName);
const _storage = AndroidJournalStorage();

void _require(bool condition) {
  if (!condition) throw StateError('Journal runtime assertion failed.');
}

JournalBinding _binding(String name) =>
    journalBinding(environment: 'runtime-$name');
Future<Object?> _fixture(
  String method,
  JournalBinding binding, [
  Map<String, Object?> extras = const {},
]) => _control.invokeMethod<Object?>(method, {
  'binding': binding.toJson(),
  ...extras,
});

Future<JournalRecord> _seed(
  String name, {
  bool confirmed = false,
  bool blocked = false,
}) async {
  final binding = _binding(name);
  const journal = CommandJournal(_storage);
  final prepared = await journal.prepare(
    binding,
    journalCommand(protocol: JournalProtocol.legacyV1),
    expectedRevision: 0,
    expectedKey: null,
  );
  _require(prepared.issue == null);
  var record = prepared.record!;
  if (confirmed || blocked) {
    record = (await journal.markMayHaveSent(
      binding,
      expectedRevision: record.revision,
      expectedKey: record.command!.key,
    )).record!;
    record = (await journal.confirm(
      binding,
      journalConfirmation(record.command!),
      expectedRevision: record.revision,
      expectedKey: record.command!.key,
    )).record!;
  }
  if (blocked) {
    record = (await journal.block(
      binding,
      JournalBlockReason.manualReview,
      expectedRevision: record.revision,
      expectedKey: record.command!.key,
    )).record!;
  }
  return record;
}

Future<void> _unchangedFailure(
  JournalBinding binding,
  JournalIssue issue,
) async {
  final before = await _fixture('fingerprint', binding);
  final read = await _storage.read(binding);
  _require(read.issue == issue && read.bytes == null);
  _require(await _fixture('fingerprint', binding) == before);
}

Future<void> _requireOriginalPreparedRecord(String name) async {
  final expected = JournalRecord.absent(_binding(name))
      .prepare(journalCommand(protocol: JournalProtocol.legacyV1));
  final restored = await _storage.read(expected.binding);
  // Compare the entire original record: binding, revision, phase, idempotency
  // key, full frozen command, flags and nullable receipt/block/migration fields.
  _require(
    restored.issue == null &&
        listEquals(restored.bytes, JournalCodec.encode(expected)),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final failures = <String>[];
  var passed = 0;
  Future<void> run(String name, Future<void> Function() body) async {
    try {
      await body();
      passed++;
    } catch (error) {
      // Fixture names/types only; no payloads or raw platform messages.
      failures.add('$name (${error.runtimeType})');
    }
  }

  final phase = await _control.invokeMethod<String>('phase');
  if (phase == 'fresh') {
    await migrationInspectionChecks(run);
    await run('absence does not create a key', () async {
      _require((await _storage.read(_binding('absent'))).bytes == null);
      _require(await _control.invokeMethod<bool>('keyExists') == false);
    });
    await run('Keystore encrypt/decrypt and exact main read', () async {
      final record = await _seed('main');
      _require(await _control.invokeMethod<bool>('keyExists') == true);
      _require(
        (await _storage.read(record.binding)).bytes!.join(',') ==
            JournalCodec.encode(record).join(','),
      );
    });
    for (final kind in ['new', 'bak']) {
      await run(
        'independently encrypted identical $kind normalization',
        () async {
          final record = await _seed('duplicate-$kind');
          final differentCiphertext = await _fixture(
            'sidecar',
            record.binding,
            {
              'kind': kind,
              'record': Uint8List.fromList(JournalCodec.encode(record)),
            },
          );
          _require(differentCiphertext == true);
          final read = await _storage.read(record.binding);
          _require(
            read.issue == null &&
                read.bytes!.join(',') == JournalCodec.encode(record).join(','),
          );
          final presence = await _fixture('presence', record.binding) as Map;
          _require(presence['main'] == true && presence[kind] == false);
          _require((await _storage.read(record.binding)).issue == null);
        },
      );
      await run('orphan $kind remains blocked', () async {
        final record = await _seed('orphan-$kind');
        await _fixture('orphan', record.binding, {'kind': kind});
        await _unchangedFailure(record.binding, JournalIssue.unreadable);
      });
    }
    await run('different authenticated revision retained', () async {
      final record = await _seed('different');
      final next = record.markMayHaveSent();
      await _fixture('sidecar', record.binding, {
        'kind': 'new',
        'record': Uint8List.fromList(JournalCodec.encode(next)),
      });
      await _unchangedFailure(record.binding, JournalIssue.unreadable);
    });
    await run('full Dart validation precedes cleanup', () async {
      final record = await _seed('invalid-state');
      final invalid = Uint8List.fromList(
        utf8.encode(
          jsonEncode({...record.toJson(), 'write_may_have_started': true}),
        ),
      );
      await _fixture('replaceMain', record.binding, {'record': invalid});
      await _fixture('sidecar', record.binding, {
        'kind': 'new',
        'record': invalid,
      });
      await _unchangedFailure(record.binding, JournalIssue.corrupt);
    });
    await run('authentication tag tampering retained', () async {
      final record = await _seed('tag');
      await _fixture('tamper', record.binding);
      await _unchangedFailure(
        record.binding,
        JournalIssue.authenticationFailed,
      );
    });
    await run('wrong AAD sidecar retained', () async {
      final record = await _seed('aad');
      await _fixture('sidecar', record.binding, {
        'kind': 'new',
        'record': Uint8List.fromList(JournalCodec.encode(record)),
        'wrong_aad': true,
      });
      await _unchangedFailure(
        record.binding,
        JournalIssue.authenticationFailed,
      );
    });
    await run('actual unfinished AtomicFile write retained', () async {
      final record = await _seed('partial');
      await _fixture('partialWrite', record.binding);
      await _unchangedFailure(record.binding, JournalIssue.corrupt);
    });
    await run('ciphertext snapshot changed with identical plaintext', () async {
      final record = await _seed('snapshot');
      final bytes = Uint8List.fromList(JournalCodec.encode(record));
      await _fixture('sidecar', record.binding, {
        'kind': 'new',
        'record': bytes,
      });
      final inspection = await _native.invokeMapMethod<String, Object?>(
        'inspectRecoveryV1',
        {'api_version': 1, 'binding': record.binding.toJson()},
      );
      await _fixture('sidecar', record.binding, {
        'kind': 'new',
        'record': bytes,
      });
      final before = await _fixture('fingerprint', record.binding);
      try {
        await _native.invokeMethod<Object?>('normalizeRecoveryV1', {
          'api_version': 1,
          'binding': record.binding.toJson(),
          'snapshot': inspection!['snapshot'],
          'validated_record': bytes,
        });
        throw StateError('Stale snapshot accepted.');
      } on PlatformException catch (error) {
        _require(error.code == 'journal_revision_conflict');
      }
      _require(await _fixture('fingerprint', record.binding) == before);
      _require((await _storage.read(record.binding)).issue == null);
    });
    await run('real native CAS conflict', () async {
      final record = await _seed('cas');
      Future<JournalIssue?> write() => _storage.compareAndSwap(
        binding: record.binding,
        expectedRevision: record.revision,
        expectedKey: record.command!.key,
        replacement: JournalCodec.encode(record.markMayHaveSent()),
      );
      final results = await Future.wait([write(), write()]);
      _require(results.where((r) => r == null).length == 1);
      _require(
        results.where((r) => r == JournalIssue.revisionConflict).length == 1,
      );
    });
    await run('blocked record stays blocked after duplicate cleanup', () async {
      final record = await _seed('blocked', blocked: true);
      await _fixture('sidecar', record.binding, {
        'kind': 'bak',
        'record': Uint8List.fromList(JournalCodec.encode(record)),
      });
      final restored = await const CommandJournal(_storage)
          .read(record.binding);
      _require(
        restored.isBlocked && restored.record!.revision == record.revision,
      );
      _require(
        restored.record!.confirmation!.dataJson ==
            record.confirmation!.dataJson,
      );
    });
    await run(
      'restart fixtures persisted without resolving uncertain artifacts',
      () async {
        await _seed('persist');
        final duplicate = await _seed('restart-duplicate');
        await _fixture('sidecar', duplicate.binding, {
          'kind': 'bak',
          'record': Uint8List.fromList(JournalCodec.encode(duplicate)),
        });
        final partial = await _seed('restart-partial');
        await _fixture('partialWrite', partial.binding);
      },
    );
    await migrationFreshChecks(run);
    await coordinatorFreshChecks(run);
    await confirmedRecoveryFreshChecks(run);
    await noteFreshChecks(run);
  } else if (phase == 'restart') {
    await run(
      'Keystore and original prepared command survive process restart',
      () async {
        _require(await _control.invokeMethod<bool>('keyExists') == true);
        await _requireOriginalPreparedRecord('persist');
      },
    );
    await run('duplicate recovery after process restart', () async {
      await _requireOriginalPreparedRecord('restart-duplicate');
      final presence =
          await _fixture('presence', _binding('restart-duplicate')) as Map;
      _require(presence['main'] == true && presence['bak'] == false);
    });
    await run('unfinished AtomicFile remains blocked after restart', () async {
      await _unchangedFailure(
        _binding('restart-partial'),
        JournalIssue.corrupt,
      );
    });
    await migrationRestartChecks(run);
    await coordinatorRestartChecks(run);
    await confirmedRecoveryRestartChecks(run);
    await noteRestartChecks(run);
    await run('missing key never regenerates or deletes ciphertext', () async {
      final binding = _binding('persist');
      await _control.invokeMethod<void>('loseKey');
      await _unchangedFailure(binding, JournalIssue.missingKey);
      _require(await _control.invokeMethod<bool>('keyExists') == false);
    });
  } else {
    failures.add('Unknown instrumentation phase');
  }
  await _control.invokeMethod<void>('finish', {
    'passed': passed,
    'failures': failures,
  });
}
