import 'dart:convert';

import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';
import 'support/memory_journal_storage.dart';

class _ThrowingStorage implements JournalStorage {
  _ThrowingStorage({required this.throwRead});
  final bool throwRead;
  @override
  Future<JournalStorageRead> read(JournalBinding binding) async {
    if (throwRead) throw StateError('fictional backend failure');
    return const JournalStorageRead.absent();
  }

  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    throw StateError('fictional backend failure');
  }
}

void main() {
  for (final throwRead in [false, true]) {
    test(
      'unexpected backend exception (read=$throwRead) becomes a safe blocked result',
      () async {
        final journal = CommandJournal(_ThrowingStorage(throwRead: throwRead));
        final result = await journal.prepare(
          journalBinding(),
          journalCommand(),
          expectedRevision: 0,
          expectedKey: null,
        );
        expect(result.issue, JournalIssue.storageFailure);
        expect(result.isAbsent, isFalse);
        expect(result.record, isNull);
      },
    );
  }
  final actions = <String, JournalRecord Function(JournalRecord)>{
    'prepare': (r) => r.prepare(journalCommand()),
    'send': (r) => r.markMayHaveSent(),
    'uncertain': (r) => r.markUncertain(),
    'confirm': (r) => r.confirm(journalConfirmation(journalCommand())),
    'block': (r) => r.blockRecovery(JournalBlockReason.manualReview),
    'cleanup': (r) => r.compactConfirmed(
      canonicalStateVerified: true,
      confirmationConsumed: true,
    ),
  };
  final allowed = <JournalPhase, Set<String>>{
    JournalPhase.empty: {'prepare'},
    JournalPhase.prepared: {'send', 'block'},
    JournalPhase.mayHaveSent: {'send', 'uncertain', 'confirm', 'block'},
    JournalPhase.uncertain: {'send', 'confirm', 'block'},
    JournalPhase.confirmed: {'cleanup', 'block'},
    JournalPhase.blocked: {},
  };
  final target = {
    'prepare': JournalPhase.prepared,
    'send': JournalPhase.mayHaveSent,
    'uncertain': JournalPhase.uncertain,
    'confirm': JournalPhase.confirmed,
    'block': JournalPhase.blocked,
    'cleanup': JournalPhase.empty,
  };
  for (final phase in JournalPhase.values) {
    for (final action in actions.entries) {
      test(
        '$phase -> ${action.key} is ${allowed[phase]!.contains(action.key) ? 'legal' : 'illegal'}',
        () {
          final record = recordAt(phase);
          final original = record.toJson();
          if (!allowed[phase]!.contains(action.key)) {
            expect(
              () => action.value(record),
              throwsA(
                isA<JournalException>().having(
                  (e) => e.issue,
                  'issue',
                  JournalIssue.illegalTransition,
                ),
              ),
            );
          } else {
            final next = action.value(record);
            expect(next.phase, target[action.key]);
            expect(next.revision, record.revision + 1);
            expect(next.binding.matches(record.binding), isTrue);
            if (next.command != null && record.command != null) {
              expect(
                next.command!.parametersJson,
                record.command!.parametersJson,
              );
              expect(next.command!.key, record.command!.key);
            }
            if (action.key == 'block' && phase == JournalPhase.confirmed) {
              expect(
                next.confirmation!.dataJson,
                record.confirmation!.dataJson,
              );
            }
          }
          expect(record.toJson(), original);
        },
      );
    }
  }

  late MemoryJournalDisk disk;
  late CommandJournal journal;
  final binding = journalBinding();
  setUp(() {
    disk = MemoryJournalDisk();
    journal = CommandJournal(MemoryJournalStorage(disk));
  });
  Future<JournalRecord> prepare() async => (await journal.prepare(
    binding,
    journalCommand(),
    expectedRevision: 0,
    expectedKey: null,
  )).record!;
  Future<JournalRecord> send(JournalRecord record) async =>
      (await journal.markMayHaveSent(
        binding,
        expectedRevision: record.revision,
        expectedKey: record.command!.key,
      )).record!;

  test('absence and a durable empty tombstone are distinguishable', () async {
    expect((await journal.read(binding)).isAbsent, isTrue);
    final record = recordAt(JournalPhase.confirmed);
    disk.inject(binding, JournalCodec.encode(record));
    final cleanup = await journal.compactConfirmed(
      binding,
      expectedRevision: record.revision,
      expectedKey: journalKey,
      canonicalStateVerified: true,
      confirmationConsumed: true,
    );
    expect(cleanup.record!.phase, JournalPhase.empty);
    expect(cleanup.record!.command, isNull);
    expect(cleanup.record!.confirmation, isNull);
    expect((await journal.read(binding)).isAbsent, isFalse);
    expect(utf8.decode(disk.snapshot(binding)!), isNot(contains(journalKey)));
    expect(utf8.decode(disk.snapshot(binding)!), isNot(contains('p_latitude')));
  });
  test('identical duplicate is a no-op preserving the first JSON, phase and receipt', () async {
    final confirmed = recordAt(JournalPhase.confirmed);
    disk.inject(binding, JournalCodec.encode(confirmed));
    final original = confirmed.command!;
    final reordered = JournalCommand.frozen(
      protocol: original.protocol,
      operation: original.operation,
      parametersJson: jsonEncode(
        Map.fromEntries(original.parameters.entries.toList().reversed),
      ),
    );
    expect(reordered.parametersJson, isNot(original.parametersJson));
    final result = await journal.prepare(
      binding,
      reordered,
      expectedRevision: confirmed.revision,
      expectedKey: journalKey,
    );
    expect(result.record!.toJson(), confirmed.toJson());
    expect(disk.writes, 0);
  });
  for (final sameKey in [false, true]) {
    test(
      'conflicting unresolved request (sameKey=$sameKey) is retained',
      () async {
        final prepared = await prepare();
        final originalBytes = disk.snapshot(binding);
        final other = sameKey
            ? JournalCommand.parameters(
                protocol: JournalProtocol.attendanceV2,
                operation: prepared.command!.operation,
                parameters: {
                  ...prepared.command!.parameters,
                  'p_site_description': 'changed',
                },
              )
            : journalCommand(key: 'fictional-other-key');
        final result = await journal.prepare(
          binding,
          other,
          expectedRevision: prepared.revision,
          expectedKey: journalKey,
        );
        expect(result.issue, JournalIssue.commandConflict);
        expect(disk.snapshot(binding), originalBytes);
      },
    );
  }
  for (final wrongKey in [false, true]) {
    test(
      'CAS rejects stale ${wrongKey ? 'key' : 'revision'} without changing data',
      () async {
        final prepared = await prepare();
        final original = disk.snapshot(binding);
        final result = await journal.markMayHaveSent(
          binding,
          expectedRevision: wrongKey ? prepared.revision : 0,
          expectedKey: wrongKey ? 'other-key' : journalKey,
        );
        expect(result.issue, JournalIssue.revisionConflict);
        expect(disk.snapshot(binding), original);
      },
    );
  }
  test(
    'two coordinators sharing storage cannot both win the same revision',
    () async {
      final prepared = await prepare();
      final second = CommandJournal(MemoryJournalStorage(disk));
      final results = await Future.wait([
        journal.markMayHaveSent(
          binding,
          expectedRevision: prepared.revision,
          expectedKey: journalKey,
        ),
        second.block(
          binding,
          JournalBlockReason.manualReview,
          expectedRevision: prepared.revision,
          expectedKey: journalKey,
        ),
      ]);
      expect(results.where((r) => r.issue == null).length, 1);
      expect(
        results.where((r) => r.issue == JournalIssue.revisionConflict).length,
        1,
      );
      expect(
        (await journal.read(binding)).record!.command!.parametersJson,
        prepared.command!.parametersJson,
      );
    },
  );
  for (final issue in [
    JournalIssue.unreadable,
    JournalIssue.missingKey,
    JournalIssue.unsupportedFormat,
    JournalIssue.identityMismatch,
    JournalIssue.storageFailure,
  ]) {
    test(
      '$issue blocks access and replacement without returning contents',
      () async {
        await prepare();
        final bytes = disk.snapshot(binding);
        disk.readIssues[binding.storageIdentity] = issue;
        final result = await journal.read(binding);
        expect(result.issue, issue);
        expect(result.record, isNull);
        expect(result.isAbsent, isFalse);
        expect(
          (await journal.prepare(
            binding,
            journalCommand(),
            expectedRevision: 0,
            expectedKey: null,
          )).issue,
          issue,
        );
        expect(disk.snapshot(binding), bytes);
      },
    );
  }
  for (final invalid in [
    '',
    '{}',
    '{broken',
    '{"journal_format":2,"journal_format":2}',
  ]) {
    test(
      'existing invalid bytes block instead of appearing empty: $invalid',
      () async {
        final bytes = utf8.encode(invalid);
        disk.inject(binding, bytes);
        expect((await journal.read(binding)).isBlocked, isTrue);
        expect(
          (await journal.prepare(
            binding,
            journalCommand(),
            expectedRevision: 0,
            expectedKey: null,
          )).isBlocked,
          isTrue,
        );
        expect(disk.snapshot(binding), bytes);
      },
    );
  }
  for (final fault in [JournalFault.beforeRead, JournalFault.afterRead]) {
    test('$fault is not empty storage', () async {
      await prepare();
      disk.failNext(fault);
      final result = await journal.read(binding);
      expect(result.issue, JournalIssue.storageFailure);
      expect(result.isAbsent, isFalse);
      expect(
        (await journal.read(binding)).record!.phase,
        JournalPhase.prepared,
      );
    });
  }
  for (final fault in [
    JournalFault.beforeWrite,
    JournalFault.afterWrite,
    JournalFault.readback,
  ]) {
    test('$fault during preparation cannot authorize transmission', () async {
      disk.failNext(fault);
      final result = await journal.prepare(
        binding,
        journalCommand(),
        expectedRevision: 0,
        expectedKey: null,
      );
      expect(result.issue, JournalIssue.storageFailure);
      final restored = await CommandJournal(MemoryJournalStorage(disk))
          .read(binding);
      expect(restored.isAbsent, fault == JournalFault.beforeWrite);
      if (restored.record != null) {
        expect(restored.record!.phase, JournalPhase.prepared);
        expect(restored.record!.command!.key, journalKey);
      }
    });
    for (final stage in ['send', 'uncertain', 'confirm', 'cleanup', 'block']) {
      test(
        '$fault during $stage retains the old or complete new record',
        () async {
          final initial = recordAt(
            stage == 'send' || stage == 'block'
                ? JournalPhase.prepared
                : stage == 'cleanup'
                ? JournalPhase.confirmed
                : JournalPhase.mayHaveSent,
          );
          disk.inject(binding, JournalCodec.encode(initial));
          disk.failNext(fault);
          final rev = initial.revision;
          final result = switch (stage) {
            'send' => await journal.markMayHaveSent(
              binding,
              expectedRevision: rev,
              expectedKey: journalKey,
            ),
            'uncertain' => await journal.markUncertain(
              binding,
              expectedRevision: rev,
              expectedKey: journalKey,
            ),
            'confirm' => await journal.confirm(
              binding,
              journalConfirmation(initial.command!),
              expectedRevision: rev,
              expectedKey: journalKey,
            ),
            'block' => await journal.block(
              binding,
              JournalBlockReason.manualReview,
              expectedRevision: rev,
              expectedKey: journalKey,
            ),
            _ => await journal.compactConfirmed(
              binding,
              expectedRevision: rev,
              expectedKey: journalKey,
              canonicalStateVerified: true,
              confirmationConsumed: true,
            ),
          };
          expect(result.issue, JournalIssue.storageFailure);
          final stored = (await CommandJournal(
            MemoryJournalStorage(disk),
          ).read(binding)).record!;
          expect(
            stored.revision,
            rev + (fault == JournalFault.beforeWrite ? 0 : 1),
          );
          if (stored.phase != JournalPhase.empty) {
            expect(
              stored.command!.parametersJson,
              initial.command!.parametersJson,
            );
            expect(stored.command!.key, journalKey);
          }
          if (stage == 'cleanup' && fault == JournalFault.beforeWrite) {
            expect(stored.confirmation, isNotNull);
          }
          if (stage == 'confirm' && fault != JournalFault.beforeWrite) {
            expect(
              stored.confirmation!.dataJson,
              journalConfirmation(initial.command!).dataJson,
            );
          }
        },
      );
    }
  }
  test('simulated lost response/restart retains exact command through replay confirmation', () async {
    final prepared = await prepare();
    final sending = await send(prepared);
    // Simulated server commit with no response; no server or disk is involved.
    final restarted = CommandJournal(MemoryJournalStorage(disk));
    final recovered = (await restarted.read(binding)).record!;
    expect(recovered.phase, JournalPhase.mayHaveSent);
    final uncertain = await restarted.markUncertain(
      binding,
      expectedRevision: sending.revision,
      expectedKey: journalKey,
    );
    final confirmed = await restarted.confirm(
      binding,
      journalConfirmation(prepared.command!, replay: true),
      expectedRevision: uncertain.record!.revision,
      expectedKey: journalKey,
    );
    expect(confirmed.record!.phase, JournalPhase.confirmed);
    expect(
      confirmed.record!.command!.parametersJson,
      prepared.command!.parametersJson,
    );
    expect(confirmed.record!.confirmation!.data['status'], 'idempotent_replay');
  });
  test('failed SELECT after confirmation cannot erase receipt or reopen transmission', () async {
    final sending = await send(await prepare());
    final confirmed = await journal.confirm(
      binding,
      journalConfirmation(sending.command!),
      expectedRevision: sending.revision,
      expectedKey: journalKey,
    );
    // A later coordinator SELECT fails. Cleanup conditions are not satisfied.
    final result = await journal.compactConfirmed(
      binding,
      expectedRevision: confirmed.record!.revision,
      expectedKey: journalKey,
      canonicalStateVerified: false,
      confirmationConsumed: true,
    );
    expect(result.issue, JournalIssue.illegalTransition);
    final stored = (await journal.read(binding)).record!;
    expect(stored.phase, JournalPhase.confirmed);
    expect(
      stored.confirmation!.dataJson,
      confirmed.record!.confirmation!.dataJson,
    );
    expect(
      (await journal.markMayHaveSent(
        binding,
        expectedRevision: stored.revision,
        expectedKey: journalKey,
      )).issue,
      JournalIssue.illegalTransition,
    );
  });
  for (final conditions in [(false, false), (false, true), (true, false)]) {
    test('cleanup requires both safeguards $conditions', () {
      final record = recordAt(JournalPhase.confirmed);
      expect(
        () => record.compactConfirmed(
          canonicalStateVerified: conditions.$1,
          confirmationConsumed: conditions.$2,
        ),
        throwsA(isA<JournalException>()),
      );
    });
  }
  for (final data in [
    {'contract_version': 2, 'status': 'not_found'},
    {'status': 'idempotency_key_conflict'},
    {'status': 'error', 'message': 'idempotency_key_conflict'},
  ]) {
    test('non-acknowledgement $data never confirms attendance', () {
      final record = recordAt(JournalPhase.mayHaveSent);
      expect(
        () => JournalConfirmation(
          source: JournalConfirmationSource.rpcV2,
          dataJson: jsonEncode(data),
          command: record.command!,
        ),
        throwsA(anything),
      );
      expect(record.phase, JournalPhase.mayHaveSent);
      expect(record.confirmation, isNull);
    });
  }
  test('confirmation from a different original command cannot be attached', () {
    final record = recordAt(JournalPhase.mayHaveSent);
    final other = journalCommand(key: 'fictional-other-key');
    expect(
      () => record.confirm(journalConfirmation(other)),
      throwsA(isA<JournalException>()),
    );
    final changed = JournalCommand.parameters(
      protocol: record.command!.protocol,
      operation: record.command!.operation,
      parameters: {...record.command!.parameters, 'p_latitude': 46},
    );
    expect(
      () => record.confirm(journalConfirmation(changed)),
      throwsA(isA<JournalException>()),
    );
  });
  test('hash conflict is a durable terminal recovery block preserving original evidence', () async {
    final sending = await send(await prepare());
    final blocked = await journal.block(
      binding,
      JournalBlockReason.hashConflict,
      expectedRevision: sending.revision,
      expectedKey: journalKey,
    );
    expect(blocked.isBlocked, isTrue);
    expect(
      blocked.record!.command!.parametersJson,
      sending.command!.parametersJson,
    );
    expect(blocked.record!.confirmation, isNull);
    expect(
      (await journal.markMayHaveSent(
        binding,
        expectedRevision: blocked.record!.revision,
        expectedKey: journalKey,
      )).issue,
      JournalIssue.illegalTransition,
    );
  });
  test(
    'account/environment changes cannot see or mutate another binding',
    () async {
      final original = await prepare();
      for (final other in [
        journalBinding(auth: journalOtherId),
        journalBinding(company: journalOtherId),
        journalBinding(profile: journalOtherId),
        journalBinding(environment: 'other'),
        journalBinding(url: 'https://other.invalid'),
      ]) {
        expect((await journal.read(other)).isAbsent, isTrue);
        expect(
          (await journal.markMayHaveSent(
            other,
            expectedRevision: original.revision,
            expectedKey: journalKey,
          )).issue,
          JournalIssue.revisionConflict,
        );
        // Simulate a broken backend misrouting the original file: decode still denies it.
        disk.inject(other, disk.snapshot(binding)!);
        expect(
          (await journal.read(other)).issue,
          JournalIssue.identityMismatch,
        );
      }
      expect((await journal.read(binding)).record!.toJson(), original.toJson());
    },
  );
  test(
    'late callbacks cannot clear a newer command after confirmed cleanup',
    () async {
      final confirmed = recordAt(JournalPhase.confirmed);
      disk.inject(binding, JournalCodec.encode(confirmed));
      final empty = await journal.compactConfirmed(
        binding,
        expectedRevision: confirmed.revision,
        expectedKey: journalKey,
        canonicalStateVerified: true,
        confirmationConsumed: true,
      );
      final newer = await journal.prepare(
        binding,
        journalCommand(key: 'fictional-newer-key'),
        expectedRevision: empty.record!.revision,
        expectedKey: null,
      );
      final stale = await journal.compactConfirmed(
        binding,
        expectedRevision: confirmed.revision,
        expectedKey: journalKey,
        canonicalStateVerified: true,
        confirmationConsumed: true,
      );
      expect(stale.issue, JournalIssue.revisionConflict);
      expect(
        (await journal.read(binding)).record!.command!.key,
        newer.record!.command!.key,
      );
    },
  );
}
