// Fictional fixture operations only, inside the isolated instrumentation app.
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/android_legacy_migration.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../support/journal_fixtures.dart';
import '../support/legacy_migration_fixtures.dart';

typedef RuntimeCheck = Future<void> Function(String, Future<void> Function());
const _control = MethodChannel('chantipoint/journal_test_control');
const _native = MethodChannel(AndroidJournalStorage.channelName);
const _migration = AndroidLegacyMigration();
const _storage = AndroidJournalStorage();
void _require(bool condition) {
  if (!condition) throw StateError('Migration runtime assertion failed.');
}

Future<Object?> _fixture(
  String method,
  JournalBinding binding, [
  Map<String, Object?> extra = const {},
]) => _control.invokeMethod<Object?>(method, {
  'binding': binding.toJson(),
  ...extra,
});
Future<void> _write(
  JournalBinding binding,
  List<int> bytes, {
  String suffix = '',
}) async {
  await _fixture('legacyFixture', binding, {
    'operation': 'write',
    'suffix': suffix,
    'bytes': Uint8List.fromList(bytes),
  });
}

Future<void> _remove(JournalBinding binding, {String suffix = ''}) async {
  await _fixture('legacyFixture', binding, {
    'operation': 'delete',
    'suffix': suffix,
  });
}

Future<Map> _rawInspection(JournalBinding binding) async =>
    await _native.invokeMethod<Object?>('inspectLegacySourceV1', {
      'api_version': 1,
      'binding': binding.toJson(),
    }) as Map;
Future<void> _issue(
  Future<void> Function() operation,
  JournalIssue issue,
) async {
  try {
    await operation();
  } on JournalException catch (error) {
    _require(error.issue == issue);
    return;
  }
  throw StateError('Expected migration failure.');
}

Future<void> _nativeIssue(
  String method,
  JournalBinding binding,
  Map<String, Object?> extra,
  String code,
) async {
  try {
    await _native.invokeMethod<Object?>(method, {
      'api_version': 1,
      'binding': binding.toJson(),
      ...extra,
    });
  } on PlatformException catch (error) {
    _require(error.code == code);
    return;
  }
  throw StateError('Expected native migration failure.');
}

Future<void> _unchangedRecord(JournalRecord expected) async {
  final actual = await _storage.read(expected.binding);
  _require(
    actual.issue == null &&
        listEquals(actual.bytes, JournalCodec.encode(expected)),
  );
}

Future<void> _sourceDescriptorsClosed(JournalBinding binding) async {
  final counts = await _fixture('sourceDescriptorCounts', binding) as Map;
  _require(
    counts.length == 2 && counts['source'] == 0 && counts['artifacts'] == 0,
  );
}

Future<JournalRecord> _seed(
  int slot, {
  bool confirmed = true,
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
}) async {
  final binding = migrationBinding(slot);
  final record = migrationRecord(
    binding,
    confirmed: confirmed,
    operation: operation,
  );
  // Fixtures may persist a complete later revision directly via their native
  // replace helper; seed revision one through real CAS first.
  final first = migrationRecord(binding, operation: operation);
  _require(
    await _storage.compareAndSwap(
          binding: binding,
          expectedRevision: 0,
          expectedKey: null,
          replacement: JournalCodec.encode(first),
        ) ==
        null,
  );
  if (confirmed) {
    _require(
      await _storage.compareAndSwap(
            binding: binding,
            expectedRevision: first.revision,
            expectedKey: first.command!.key,
            replacement: JournalCodec.encode(record),
          ) ==
          null,
    );
  }
  await _write(
    binding,
    migrationApproval(binding, operation: operation).approvedSource,
  );
  return record;
}

Future<void> migrationInspectionChecks(RuntimeCheck run) async {
  final binding = migrationBinding(50);
  final bytes = migrationApproval(binding).approvedSource;
  await run(
    'migration inspection absence and unrelated files do not create keys',
    () async {
      _require((await _migration.inspect(binding)).source.bytes == null);
      final before = (await _migration.inspect(binding)).identity;
      await _fixture('legacyFixture', binding, {'operation': 'unrelated'});
      _require((await _migration.inspect(binding)).identity == before);
      _require(await _control.invokeMethod<bool>('keyExists') == false);
    },
  );
  await run(
    'migration inspection exact bytes actual hash and artifact snapshots',
    () async {
      await _write(binding, bytes);
      final first = await _migration.inspect(binding);
      _require(listEquals(first.source.bytes, bytes));
      _require(first.source.sourceSha256 == sha256.convert(bytes).toString());
      await _write(binding, bytes, suffix: '.tmp');
      final temporary = await _migration.inspect(binding);
      _require(
        temporary.identity != first.identity &&
            temporary.source.artifacts.contains(LegacySourceArtifact.temporary),
      );
      await _write(binding, [1, 2], suffix: '.tmp');
      _require(
        (await _migration.inspect(binding)).identity != temporary.identity,
      );
      await _remove(binding, suffix: '.tmp');
      await _write(binding, bytes, suffix: '.bak');
      _require(
        (await _migration.inspect(binding)).source.artifacts
            .contains(LegacySourceArtifact.unexpected),
      );
      await _remove(binding, suffix: '.bak');
      await _remove(binding);
      _require(await _control.invokeMethod<bool>('keyExists') == false);
    },
  );
  await run(
    'migration malformed oversized and unreadable sources are retained',
    () async {
      await _write(binding, utf8.encode('{'));
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.corrupt);
      _require((await _rawInspection(binding))['source'] != null);
      await _write(binding, List<int>.filled(JournalJson.recordLimit + 1, 32));
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.corrupt);
      await _write(binding, bytes);
      await _fixture('legacyFixture', binding, {'operation': 'unreadable'});
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.unreadable);
      await _fixture('legacyFixture', binding, {'operation': 'readable'});
      _require(
        listEquals((await _migration.inspect(binding)).source.bytes, bytes),
      );
      await _remove(binding);
    },
  );
  await run(
    'migration rejects symlinks nonregular sources and arbitrary-path requests',
    () async {
      await _fixture('legacyFixture', binding, {'operation': 'symlink'});
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.unreadable);
      await _remove(binding);
      await _fixture('legacyFixture', binding, {'operation': 'directory'});
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.unreadable);
      await _remove(binding);
      await _nativeIssue('inspectLegacySourceV1', binding, {
        'basename': '../escape',
      }, 'journal_corrupt');
      _require(await _control.invokeMethod<bool>('keyExists') == false);
    },
  );
  await _descriptorInspectionChecks(run);
}

Future<void> _descriptorInspectionChecks(RuntimeCheck run) async {
  final binding = migrationBinding(60);
  final bytes = migrationApproval(binding).approvedSource;
  await run(
    'repeated finalized inspections close every fixture descriptor',
    () async {
      await _write(binding, bytes);
      await _sourceDescriptorsClosed(binding);
      _require(
        await _fixture('sourceDescriptorProbe', binding, {
              'suffix': '',
              'unlink': false,
            }) ==
            true,
      );
      for (var i = 0; i < 16; i++) {
        _require(
          listEquals((await _migration.inspect(binding)).source.bytes, bytes),
        );
        await _sourceDescriptorsClosed(binding);
      }
      await _remove(binding);
    },
  );
  await run(
    'repeated source and sidecar inspections close both fixture descriptors',
    () async {
      await _write(binding, bytes);
      await _write(binding, bytes, suffix: '.tmp');
      _require(
        await _fixture('sourceDescriptorProbe', binding, {
              'suffix': '.tmp',
              'unlink': false,
            }) ==
            true,
      );
      // Positive control proves unlinked-but-open sidecars are counted too.
      _require(
        await _fixture('sourceDescriptorProbe', binding, {
              'suffix': '.tmp',
              'unlink': true,
            }) ==
            true,
      );
      await _sourceDescriptorsClosed(binding);
      await _write(binding, bytes, suffix: '.tmp');
      for (var i = 0; i < 16; i++) {
        final source = await _migration.inspect(binding);
        _require(
          source.source.artifacts.contains(LegacySourceArtifact.temporary),
        );
        await _sourceDescriptorsClosed(binding);
      }
      await _remove(binding, suffix: '.tmp');
      await _remove(binding);
    },
  );
  await run('oversized source and artifact failures after open close fixture descriptors', () async {
    final oversized = List<int>.filled(JournalJson.recordLimit + 1, 32);
    await _write(binding, oversized);
    for (var i = 0; i < 16; i++) {
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.corrupt);
      await _sourceDescriptorsClosed(binding);
    }
    await _write(binding, bytes);
    await _write(binding, oversized, suffix: '.tmp');
    for (var i = 0; i < 16; i++) {
      await _issue(() async {
        await _migration.inspect(binding);
      }, JournalIssue.corrupt);
      await _sourceDescriptorsClosed(binding);
    }
    await _remove(binding, suffix: '.tmp');
    await _remove(binding);
    _require(await _control.invokeMethod<bool>('keyExists') == false);
  });
}

Future<void> migrationFreshChecks(RuntimeCheck run) async {
  late JournalRecord main;
  await run(
    'migration target fresh barrier preserves complete confirmed record',
    () async {
      main = await _seed(0);
      await _migration.verifyTarget(main.binding, JournalCodec.encode(main));
      await _unchangedRecord(main);
      _require((await _migration.inspect(main.binding)).source.bytes != null);
    },
  );
  await run(
    'normal app namespace rejects cleanup before touching evidence',
    () async {
      final before = await _fixture('fingerprint', main.binding);
      _require(
        await _fixture('normalNamespaceRejected', main.binding, {
              'record': Uint8List.fromList(JournalCodec.encode(main)),
            }) ==
            true,
      );
      _require(await _fixture('fingerprint', main.binding) == before);
      _require((await _migration.inspect(main.binding)).source.bytes != null);
    },
  );
  await run(
    'changed source and stale snapshot are rejected without deletion',
    () async {
      final source = await _migration.inspect(main.binding);
      final changed = utf8.encode('${utf8.decode(source.source.bytes!)}\n');
      await _write(main.binding, changed);
      await _issue(
        () =>
            _migration.cleanup(main.binding, JournalCodec.encode(main), source),
        JournalIssue.revisionConflict,
      );
      final current = await _migration.inspect(main.binding);
      await _issue(
        () => _migration.cleanup(
          main.binding,
          JournalCodec.encode(main),
          current,
        ),
        JournalIssue.commandConflict,
      );
      _require(
        listEquals(
          (await _migration.inspect(main.binding)).source.bytes,
          changed,
        ),
      );
      await _write(
        main.binding,
        migrationApproval(main.binding).approvedSource,
      );
    },
  );
  await run(
    'native temporary artifact and target revision conflicts retain evidence',
    () async {
      final source = await _migration.inspect(main.binding);
      await _write(main.binding, [1], suffix: '.tmp');
      await _nativeIssue('cleanupLegacySourceV1', main.binding, {
        'expected_record': Uint8List.fromList(JournalCodec.encode(main)),
        'source_snapshot': source.identity,
      }, 'journal_revision_conflict');
      await _remove(main.binding, suffix: '.tmp');
      final newer = JournalRecord.fromJson({
        ...main.toJson(),
        'revision': main.revision + 1,
      });
      await _issue(
        () => _migration.cleanup(
          main.binding,
          JournalCodec.encode(newer),
          source,
        ),
        JournalIssue.revisionConflict,
      );
      _require((await _migration.inspect(main.binding)).source.bytes != null);
      await _unchangedRecord(main);
    },
  );
  await run('native owner digest basename and command checks reject forged relationships', () async {
    final originalBytes = migrationApproval(main.binding).approvedSource;
    Future<void> replace(JournalRecord record) async {
      await _fixture('replaceMain', main.binding, {
        'record': Uint8List.fromList(JournalCodec.encode(record)),
      });
    }

    for (final field in ['source_sha256', 'source_basename']) {
      final bad = JournalRecord.fromJson({
        ...main.toJson(),
        'migration': {
          ...main.migration!.toJson(),
          field: field == 'source_sha256' ? 'b' * 64 : 'attendance_wrong.json',
        },
      });
      await replace(bad);
      final raw = await _rawInspection(main.binding);
      await _nativeIssue(
        'cleanupLegacySourceV1',
        main.binding,
        {
          'expected_record': Uint8List.fromList(JournalCodec.encode(bad)),
          'source_snapshot': raw['snapshot'],
        },
        field == 'source_sha256'
            ? 'journal_command_conflict'
            : 'journal_identity_mismatch',
      );
      _require((await _rawInspection(main.binding))['source'] != null);
    }
    final wrongOwner = utf8.encode(
      utf8
          .decode(originalBytes)
          .replaceFirst(main.binding.profileId, journalOtherId),
    );
    await _write(main.binding, wrongOwner);
    final ownerTarget = JournalRecord.fromJson({
      ...main.toJson(),
      'migration': {
        ...main.migration!.toJson(),
        'source_sha256': sha256.convert(wrongOwner).toString(),
      },
    });
    await replace(ownerTarget);
    final raw = await _rawInspection(main.binding);
    await _nativeIssue('cleanupLegacySourceV1', main.binding, {
      'expected_record': Uint8List.fromList(JournalCodec.encode(ownerTarget)),
      'source_snapshot': raw['snapshot'],
    }, 'journal_identity_mismatch');
    await _write(main.binding, originalBytes);
    // Same digest/owner/key, different complete command timestamp.
    final badCommand = JournalRecord.fromJson({
      ...main.toJson(),
      'command': {
        ...main.command!.toJson(),
        'parameters_json': main.command!.parametersJson.replaceFirst(
          '14:30:00',
          '14:30:01',
        ),
      },
      'confirmation': null,
      'phase': 'uncertain',
    });
    await replace(badCommand);
    final source = await _migration.inspect(main.binding);
    await _issue(
      () => _migration.cleanup(
        main.binding,
        JournalCodec.encode(badCommand),
        source,
      ),
      JournalIssue.commandConflict,
    );
    await replace(main);
    await _unchangedRecord(main);
  });
  await run(
    'blocked target is rejected natively and cannot clean plaintext',
    () async {
      final blocked = main.blockRecovery(JournalBlockReason.manualReview);
      await _nativeIssue('verifyMigrationTargetV1', main.binding, {
        'expected_record': Uint8List.fromList(JournalCodec.encode(blocked)),
      }, 'journal_illegal_transition');
      _require((await _migration.inspect(main.binding)).source.bytes != null);
    },
  );
  await run(
    'eligible encrypted duplicate uses existing recovery before fresh barrier',
    () async {
      await _fixture('sidecar', main.binding, {
        'kind': 'bak',
        'record': Uint8List.fromList(JournalCodec.encode(main)),
      });
      await _migration.verifyTarget(main.binding, JournalCodec.encode(main));
      await _unchangedRecord(main);
      _require(
        (await _fixture('presence', main.binding) as Map)['bak'] == false,
      );
    },
  );
  await run(
    'ambiguous encrypted sidecar prevents cleanup and preserves all evidence',
    () async {
      final newer = JournalRecord.fromJson({
        ...main.toJson(),
        'revision': main.revision + 1,
      });
      await _fixture('sidecar', main.binding, {
        'kind': 'new',
        'record': Uint8List.fromList(JournalCodec.encode(newer)),
      });
      final before = await _fixture('fingerprint', main.binding);
      final source = await _migration.inspect(main.binding);
      await _issue(
        () =>
            _migration.cleanup(main.binding, JournalCodec.encode(main), source),
        JournalIssue.unreadable,
      );
      _require(await _fixture('fingerprint', main.binding) == before);
      _require((await _migration.inspect(main.binding)).source.bytes != null);
      await _fixture('removeFixtureSidecar', main.binding, {'kind': 'new'});
    },
  );
  for (final stage in ['target_sync', 'delete', 'source_sync']) {
    await run(
      'injected migration $stage failure preserves encrypted record and retries safely',
      () async {
        await _write(
          main.binding,
          migrationApproval(main.binding).approvedSource,
        );
        final source = await _migration.inspect(main.binding);
        final before = await _fixture('fingerprint', main.binding);
        await _fixture('migrationFault', main.binding, {'stage': stage});
        await _issue(
          () => _migration.cleanup(
            main.binding,
            JournalCodec.encode(main),
            source,
          ),
          stage == 'delete'
              ? JournalIssue.storageFailure
              : JournalIssue.synchronizationFailure,
        );
        _require(await _fixture('fingerprint', main.binding) == before);
        final after = await _migration.inspect(main.binding);
        _require((after.source.bytes == null) == (stage == 'source_sync'));
        await _migration.cleanup(
          main.binding,
          JournalCodec.encode(main),
          after,
        );
        await _unchangedRecord(main);
        _require((await _migration.inspect(main.binding)).source.bytes == null);
        _require(main.migration!.plaintextCleanupComplete == false);
      },
    );
  }
  await run('successful checkout cleanup and repeated durable absence leave receipt pending', () async {
    final checkout = await _seed(1, operation: AttendanceCommandKind.checkOut);
    await _migration.cleanup(
      checkout.binding,
      JournalCodec.encode(checkout),
      await _migration.inspect(checkout.binding),
    );
    await _migration.cleanup(
      checkout.binding,
      JournalCodec.encode(checkout),
      await _migration.inspect(checkout.binding),
    );
    await _unchangedRecord(checkout);
  });
  await run('migration restart fixtures stage source-present and already-deleted boundaries', () async {
    await _seed(2, confirmed: false);
    final deleted = await _seed(3);
    await _migration.cleanup(
      deleted.binding,
      JournalCodec.encode(deleted),
      await _migration.inspect(deleted.binding),
    );
    await _unchangedRecord(deleted);
  });
  await run('repeated cleanup failures retries and absent boundary close fixture descriptors', () async {
    final record = await _seed(4);
    final binding = record.binding;
    final bytes = migrationApproval(binding).approvedSource;
    for (final stage in ['target_sync', 'delete', 'source_sync']) {
      for (var i = 0; i < 3; i++) {
        await _write(binding, bytes);
        final source = await _migration.inspect(binding);
        await _sourceDescriptorsClosed(binding);
        await _fixture('migrationFault', binding, {'stage': stage});
        await _issue(
          () =>
              _migration.cleanup(binding, JournalCodec.encode(record), source),
          stage == 'delete'
              ? JournalIssue.storageFailure
              : JournalIssue.synchronizationFailure,
        );
        await _sourceDescriptorsClosed(binding);
        final after = await _migration.inspect(binding);
        await _migration.cleanup(binding, JournalCodec.encode(record), after);
        await _sourceDescriptorsClosed(binding);
        final absent = await _migration.inspect(binding);
        _require(absent.source.bytes == null);
        await _migration.cleanup(binding, JournalCodec.encode(record), absent);
        await _sourceDescriptorsClosed(binding);
        await _unchangedRecord(record);
      }
    }
  });
}

Future<void> migrationRestartChecks(RuntimeCheck run) async {
  for (final slot in [2, 3]) {
    await run(
      'migration force-stop restart complete record and pending cleanup at boundary $slot',
      () async {
        final original = migrationRecord(
          migrationBinding(slot),
          confirmed: slot == 3,
        );
        await _unchangedRecord(original);
        await _sourceDescriptorsClosed(original.binding);
        final source = await _migration.inspect(original.binding);
        await _sourceDescriptorsClosed(original.binding);
        _require((source.source.bytes == null) == (slot == 3));
        await _migration.cleanup(
          original.binding,
          JournalCodec.encode(original),
          source,
        );
        await _unchangedRecord(original);
        await _sourceDescriptorsClosed(original.binding);
        _require(
          (await _migration.inspect(original.binding)).source.bytes == null,
        );
        for (var i = 0; i < 8; i++) {
          final absent = await _migration.inspect(original.binding);
          await _migration.cleanup(
            original.binding,
            JournalCodec.encode(original),
            absent,
          );
          await _sourceDescriptorsClosed(original.binding);
        }
        await _unchangedRecord(original);
      },
    );
  }
}
