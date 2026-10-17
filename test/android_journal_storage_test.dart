import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';
import 'support/memory_journal_storage.dart';

// Independent wire expectations. No Android encryption/filesystem is simulated
// as verified here: MemoryJournalStorage is ONLY a channel contract test double.
const nativeErrors = {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chantipoint/secure_command_journal');
  const adapter = AndroidJournalStorage(channel: channel);
  final binding = journalBinding();
  final prepared = recordAt(JournalPhase.prepared);
  late List<MethodCall> calls;
  late MemoryJournalDisk disk;
  late Future<Object?> Function(MethodCall) handler;

  Future<Object?> memoryNative(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final owner = JournalBinding.fromJson(
      Map<String, dynamic>.from(args['binding'] as Map),
    );
    final backend = MemoryJournalStorage(disk);
    if (call.method == 'read') {
      final read = await backend.read(owner);
      if (read.issue != null) {
        throw PlatformException(
          code: nativeErrors.entries
              .firstWhere((e) => e.value == read.issue)
              .key,
        );
      }
      return read.bytes == null
          ? {'status': 'absent'}
          : {'status': 'stored', 'record': Uint8List.fromList(read.bytes!)};
    }
    expect(call.method, 'compareAndSwap');
    final issue = await backend.compareAndSwap(
      binding: owner,
      expectedRevision: args['expected_revision'] as int,
      expectedKey: args['expected_key'] as String?,
      replacement: args['replacement'] as Uint8List,
    );
    if (issue != null) {
      throw PlatformException(
        code: nativeErrors.entries.firstWhere((e) => e.value == issue).key,
      );
    }
    return {
      'status': 'written',
      'revision': (args['expected_revision'] as int) + 1,
    };
  }

  Future<JournalIssue?> writePrepared() => adapter.compareAndSwap(
    binding: binding,
    expectedRevision: 0,
    expectedKey: null,
    replacement: JournalCodec.encode(prepared),
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    disk = MemoryJournalDisk();
    handler = memoryNative;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'explicit native absence uses the exact versioned read contract',
    () async {
      final result = await adapter.read(binding);
      expect(result.bytes, isNull);
      expect(result.issue, isNull);
      expect(calls.single.method, 'read');
      expect(calls.single.arguments, {
        'api_version': 1,
        'binding': binding.toJson(),
      });
    },
  );
  test(
    'CAS is one native call with exact binding/revision/key and binary bytes',
    () async {
      expect(await writePrepared(), isNull);
      expect(calls.single.method, 'compareAndSwap');
      final args = calls.single.arguments as Map;
      expect(args.keys.toSet(), {
        'api_version',
        'binding',
        'expected_revision',
        'expected_key',
        'replacement',
      });
      expect(args['api_version'], 1);
      expect(args['binding'], binding.toJson());
      expect(args['expected_revision'], 0);
      expect(args['expected_key'], isNull);
      expect(args['replacement'], isA<Uint8List>());
      expect(args['replacement'], JournalCodec.encode(prepared));
      expect(disk.snapshot(binding), JournalCodec.encode(prepared));
    },
  );
  test('read returns the exact original frozen record without writable byte aliasing', () async {
    final bytes = Uint8List.fromList(JournalCodec.encode(prepared));
    handler = (_) async => {'status': 'stored', 'record': bytes};
    final result = await adapter.read(binding);
    final first = result.bytes!.first;
    bytes[0] = 0;
    expect(result.bytes!.first, first);
    expect(() => result.bytes![0] = 0, throwsUnsupportedError);
    expect(
      JournalCodec.decode(
        result.bytes!,
        binding,
      ).record!.command!.parametersJson,
      prepared.command!.parametersJson,
    );
  });
  test(
    'write snapshots caller bytes before awaiting native completion',
    () async {
      final completer = Completer<Object?>();
      handler = (_) => completer.future;
      final bytes = List<int>.of(JournalCodec.encode(prepared));
      final expected = List<int>.of(bytes);
      final pending = adapter.compareAndSwap(
        binding: binding,
        expectedRevision: 0,
        expectedKey: null,
        replacement: bytes,
      );
      await Future<void>.delayed(Duration.zero);
      bytes[0] = 0;
      expect((calls.single.arguments as Map)['replacement'], expected);
      completer.complete({'status': 'written', 'revision': prepared.revision});
      expect(await pending, isNull);
    },
  );
  test(
    'CommandJournal uses the adapter without changing request or receipt data',
    () async {
      final journal = CommandJournal(adapter);
      final saved = await journal.prepare(
        binding,
        prepared.command!,
        expectedRevision: 0,
        expectedKey: null,
      );
      final sending = await journal.markMayHaveSent(
        binding,
        expectedRevision: saved.record!.revision,
        expectedKey: journalKey,
      );
      final confirmed = await journal.confirm(
        binding,
        journalConfirmation(prepared.command!),
        expectedRevision: sending.record!.revision,
        expectedKey: journalKey,
      );
      final restored = await CommandJournal(
        const AndroidJournalStorage(channel: channel),
      ).read(binding);
      expect(restored.record!.toJson(), confirmed.record!.toJson());
      expect(
        restored.record!.command!.parametersJson,
        prepared.command!.parametersJson,
      );
      expect(
        restored.record!.confirmation!.dataJson,
        confirmed.record!.confirmation!.dataJson,
      );
      final snapshots = calls
          .where((c) => c.method == 'compareAndSwap')
          .map(
            (c) => JournalCodec.decode(
              (c.arguments as Map)['replacement'] as Uint8List,
              binding,
            ).record!,
          );
      expect(snapshots.map((r) => r.command!.parametersJson).toSet(), {
        prepared.command!.parametersJson,
      });
    },
  );
  for (final entry in nativeErrors.entries) {
    for (final write in [false, true]) {
      test(
        '${entry.key} during ${write ? 'CAS' : 'read'} stays blocked and preserves stored bytes',
        () async {
          disk.inject(binding, JournalCodec.encode(prepared));
          final original = disk.snapshot(binding);
          handler = (_) async => throw PlatformException(
            code: entry.key,
            message: 'fictional private backend detail',
            details: {'employee_note': 'fictional text'},
          );
          if (write) {
            expect(
              await adapter.compareAndSwap(
                binding: binding,
                expectedRevision: prepared.revision,
                expectedKey: journalKey,
                replacement: JournalCodec.encode(prepared.markMayHaveSent()),
              ),
              entry.value,
            );
          } else {
            final result = await CommandJournal(adapter).read(binding);
            expect(result.issue, entry.value);
            expect(result.isAbsent, isFalse);
            expect(result.record, isNull);
          }
          expect(calls.length, 1);
          expect(calls.single.method, write ? 'compareAndSwap' : 'read');
          expect(disk.snapshot(binding), original);
        },
      );
    }
  }
  for (final write in [false, true]) {
    test(
      'unknown native error during ${write ? 'CAS' : 'read'} has no fallback/reset',
      () async {
        handler = (_) async => throw PlatformException(
          code: 'new_unrecognized_code',
          message: 'private detail',
        );
        if (write) {
          expect(await writePrepared(), JournalIssue.nativeFailure);
        } else {
          expect(
            (await adapter.read(binding)).issue,
            JournalIssue.nativeFailure,
          );
        }
        expect(calls.length, 1);
        expect(disk.writes, 0);
      },
    );
    test(
      'missing native implementation during ${write ? 'CAS' : 'read'} is explicit',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        if (write) {
          expect(await writePrepared(), JournalIssue.unsupportedPlatform);
        } else {
          expect(
            (await adapter.read(binding)).issue,
            JournalIssue.unsupportedPlatform,
          );
        }
        expect(disk.writes, 0);
      },
    );
  }
  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.android,
  )) {
    test(
      '$platform never invokes native storage or a plaintext alternative',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          (await adapter.read(binding)).issue,
          JournalIssue.unsupportedPlatform,
        );
        expect(await writePrepared(), JournalIssue.unsupportedPlatform);
        expect(calls, isEmpty);
        expect(disk.snapshot(binding), isNull);
      },
    );
  }
  for (final response in <Object?>[
    null,
    false,
    {},
    {'status': 'absent', 'record': null},
    {'status': 'stored'},
    {
      'status': 'stored',
      'record': [1, 2, 3],
    },
    {'status': 'written'},
    {'status': 'stored', 'record': Uint8List(0)},
    {'status': 'stored', 'record': Uint8List.fromList(utf8.encode('{}'))},
  ]) {
    test(
      'malformed read response variant ${response.runtimeType}/$response is never absence',
      () async {
        handler = (_) async => response;
        final read = await CommandJournal(adapter).read(binding);
        expect(read.isAbsent, isFalse);
        expect(read.isBlocked, isTrue);
        expect(read.record, isNull);
      },
    );
  }
  for (final response in <Object?>[
    null,
    true,
    {},
    {'status': 'absent'},
    {'status': 'written', 'revision': 2},
    {'status': 'written', 'revision': 1.0},
    {'status': 'written', 'revision': 1, 'extra': true},
  ]) {
    test(
      'malformed CAS acknowledgement $response cannot report success',
      () async {
        handler = (_) async => response;
        expect(await writePrepared(), JournalIssue.nativeFailure);
        expect(calls.length, 1);
      },
    );
  }
  test('wrong-owner plaintext returned by a broken transport is blocked without exposure', () async {
    handler = (_) async => {
      'status': 'stored',
      'record': Uint8List.fromList(JournalCodec.encode(prepared)),
    };
    final other = journalBinding(auth: journalOtherId);
    final read = await adapter.read(other);
    expect(read.issue, JournalIssue.identityMismatch);
    expect(read.bytes, isNull);
  });
  test('invalid bytes cannot be truncated into a valid replacement', () async {
    final bytes = List<int>.of(JournalCodec.encode(prepared));
    bytes[0] += 256;
    expect(
      await adapter.compareAndSwap(
        binding: binding,
        expectedRevision: 0,
        expectedKey: null,
        replacement: bytes,
      ),
      JournalIssue.corrupt,
    );
    expect(calls, isEmpty);
  });
  test('invalid replacement/revision/key/identity are rejected before native invocation', () async {
    final bytes = JournalCodec.encode(prepared);
    expect(
      await adapter.compareAndSwap(
        binding: binding,
        expectedRevision: 0,
        expectedKey: null,
        replacement: [],
      ),
      JournalIssue.corrupt,
    );
    expect(
      await adapter.compareAndSwap(
        binding: binding,
        expectedRevision: 4,
        expectedKey: null,
        replacement: bytes,
      ),
      JournalIssue.revisionConflict,
    );
    expect(
      await adapter.compareAndSwap(
        binding: binding,
        expectedRevision: -1,
        expectedKey: null,
        replacement: bytes,
      ),
      JournalIssue.corrupt,
    );
    expect(
      await adapter.compareAndSwap(
        binding: binding,
        expectedRevision: 0,
        expectedKey: 'different-key',
        replacement: bytes,
      ),
      JournalIssue.commandConflict,
    );
    expect(
      await adapter.compareAndSwap(
        binding: journalBinding(environment: 'other'),
        expectedRevision: 0,
        expectedKey: null,
        replacement: bytes,
      ),
      JournalIssue.identityMismatch,
    );
    expect(calls, isEmpty);
  });
  test(
    'channel CAS conflict is propagated between independent adapter instances',
    () async {
      disk.inject(binding, JournalCodec.encode(prepared));
      final second = const AndroidJournalStorage(channel: channel);
      final next = JournalCodec.encode(prepared.markMayHaveSent());
      final results = await Future.wait([
        adapter.compareAndSwap(
          binding: binding,
          expectedRevision: prepared.revision,
          expectedKey: journalKey,
          replacement: next,
        ),
        second.compareAndSwap(
          binding: binding,
          expectedRevision: prepared.revision,
          expectedKey: journalKey,
          replacement: next,
        ),
      ]);
      expect(results.where((r) => r == null).length, 1);
      expect(
        results.where((r) => r == JournalIssue.revisionConflict).length,
        1,
      );
      expect(calls.map((c) => c.method), ['compareAndSwap', 'compareAndSwap']);
      expect(
        JournalCodec.decode(
          disk.snapshot(binding)!,
          binding,
        ).record!.command!.parametersJson,
        prepared.command!.parametersJson,
      );
    },
  );
  test(
    'conflicting prepared command is retained and never sent to native CAS',
    () async {
      disk.inject(binding, JournalCodec.encode(prepared));
      final original = disk.snapshot(binding);
      final result = await CommandJournal(adapter).prepare(
        binding,
        journalCommand(key: 'fictional-different-key'),
        expectedRevision: prepared.revision,
        expectedKey: journalKey,
      );
      expect(result.issue, JournalIssue.commandConflict);
      expect(calls.map((c) => c.method), ['read']);
      expect(disk.snapshot(binding), original);
    },
  );
  for (final fault in [
    JournalFault.beforeWrite,
    JournalFault.afterWrite,
    JournalFault.readback,
  ]) {
    test('simulated $fault never assumes native rollback', () async {
      disk.inject(binding, JournalCodec.encode(prepared));
      disk.failNext(fault);
      final result = await CommandJournal(adapter).markMayHaveSent(
        binding,
        expectedRevision: prepared.revision,
        expectedKey: journalKey,
      );
      expect(result.issue, JournalIssue.storageFailure);
      final restored = await CommandJournal(
        const AndroidJournalStorage(channel: channel),
      ).read(binding);
      expect(
        restored.record!.phase,
        fault == JournalFault.beforeWrite
            ? JournalPhase.prepared
            : JournalPhase.mayHaveSent,
      );
      expect(
        restored.record!.command!.parametersJson,
        prepared.command!.parametersJson,
      );
    });
  }
  test('simulated synchronization failure after commit keeps the complete new revision', () async {
    disk.inject(binding, JournalCodec.encode(prepared));
    handler = (call) async {
      final response = await memoryNative(call);
      if (call.method == 'compareAndSwap') {
        throw PlatformException(code: 'journal_sync_failure');
      }
      return response;
    };
    final journal = CommandJournal(adapter);
    expect(
      (await journal.markMayHaveSent(
        binding,
        expectedRevision: prepared.revision,
        expectedKey: journalKey,
      )).issue,
      JournalIssue.synchronizationFailure,
    );
    final record = (await journal.read(binding)).record!;
    expect(record.revision, prepared.revision + 1);
    expect(record.command!.key, journalKey);
    expect(record.command!.parametersJson, prepared.command!.parametersJson);
    expect(
      (await journal.prepare(
        binding,
        journalCommand(key: 'fictional-new-key'),
        expectedRevision: record.revision,
        expectedKey: journalKey,
      )).issue,
      JournalIssue.commandConflict,
    );
    expect(
      calls.every((c) => c.method == 'read' || c.method == 'compareAndSwap'),
      isTrue,
    );
  });
}
