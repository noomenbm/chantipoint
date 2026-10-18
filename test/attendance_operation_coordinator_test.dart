import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance_operation_ports.dart';
import 'support/journal_fixtures.dart';
import 'support/legacy_migration_fixtures.dart';
import 'support/memory_journal_storage.dart';

void main() {
  late FictionalAttendanceOperations h;
  setUp(() {
    h = FictionalAttendanceOperations();
  });

  for (final kind in AttendanceCommandKind.values) {
    test(
      'complete $kind persists exact phases/receipt before authoritative refresh',
      () async {
        final command = journalCommand(operation: kind);
        h.canonical.result = WorkSession.fromJson(journalReceipt(command));
        final result = await h.coordinator.submit(h.issuer.context(), command);
        final expected = JournalRecord.absent(h.binding)
            .prepare(command)
            .markMayHaveSent()
            .confirm(journalConfirmation(command));
        expect(result.outcome, AttendanceOperationOutcome.confirmed);
        expect(h.disk.snapshot(h.binding), JournalCodec.encode(expected));
        expect(h.storage.attempts.map((r) => r.phase), [
          JournalPhase.prepared,
          JournalPhase.mayHaveSent,
          JournalPhase.confirmed,
        ]);
        expect(
          h.events.indexOf('cas:prepared'),
          lessThan(h.events.indexOf('cas:mayHaveSent')),
        );
        expect(
          h.events.indexOf('cas:mayHaveSent'),
          lessThan(h.events.indexOf('dispatch:write')),
        );
        expect(
          h.events.indexOf('cas:confirmed'),
          lessThan(h.events.indexOf('canonical')),
        );
        expect(
          result.snapshot!.record.confirmation!.dataJson,
          expected.confirmation!.dataJson,
        );
        expect(
          result.snapshot!.canonicalSession!.lifecycleStatus,
          h.canonical.result!.lifecycleStatus,
        );
        expect(h.record!.phase, JournalPhase.confirmed); // Never compacted.
        expect(h.transport.calls.single.command.toJson(), command.toJson());
      },
    );
  }
  for (final intent in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace(''),
    const CheckoutNoteIntent.replace('  e\u0301 🚧\n  '),
  ]) {
    test(
      'checkout final note ${intent.action}/${intent.text} survives frozen JSON unchanged',
      () async {
        final original = journalCommand(
          operation: AttendanceCommandKind.checkOut,
          note: intent,
        );
        final params = {
          ...original.parameters,
          'p_device_observed_at': '2026-10-17T10:30:00.123456-04:00',
        };
        // Lexical whitespace/numeric spelling is deliberately frozen, not re-encoded.
        final frozen =
            ' ${jsonEncode(params).replaceFirst('45.123456789', '4.5123456789e1')} ';
        final command = JournalCommand.frozen(
          protocol: original.protocol,
          operation: original.operation,
          parametersJson: frozen,
        );
        final result = await h.coordinator.submit(h.issuer.context(), command);
        expect(result.outcome, AttendanceOperationOutcome.confirmed);
        final sent = h.transport.calls.single.command;
        expect(sent.parametersJson, frozen);
        expect(h.record!.command!.parametersJson, frozen);
        expect(sent.key, original.key);
        expect(
          sent.parameters['p_device_observed_at'],
          params['p_device_observed_at'],
        );
        expect(sent.parameters['p_note_action'], intent.action.name);
        expect(sent.parameters['p_employee_note'], intent.text);
        expect(
          sent.parameters['p_latitude'],
          original.parameters['p_latitude'],
        );
        expect(
          sent.parameters['p_location_observed_at'],
          original.parameters['p_location_observed_at'],
        );
      },
    );
  }
  test('complete acknowledgement JSON keeps original timestamp/format and every field', () async {
    final command = journalCommand();
    final row = journalReceipt(command)
      ..['started_at'] = '2026-10-15T10:00:00.123456-04:00';
    final raw = '  ${jsonEncode(row)}\n';
    h.transport.onDispatch = (_, _) async =>
        AttendanceTransportReply.acknowledged(raw);
    expect(
      (await h.coordinator.submit(h.issuer.context(), command)).outcome,
      AttendanceOperationOutcome.confirmed,
    );
    expect(h.record!.confirmation!.dataJson, raw);
    expect(h.record!.confirmation!.data.keys.toSet(), row.keys.toSet());
  });
  for (final phase in [
    JournalPhase.prepared,
    JournalPhase.mayHaveSent,
    JournalPhase.confirmed,
  ]) {
    for (final fault in [
      JournalFault.beforeWrite,
      JournalFault.afterWrite,
      JournalFault.readback,
    ]) {
      test(
        '$phase $fault never treats readable matching bytes as durable success',
        () async {
          h.storage.faults[phase] = fault;
          final result = await h.coordinator.submit(
            h.issuer.context(),
            journalCommand(),
          );
          expect(result.outcome, AttendanceOperationOutcome.unresolved);
          expect(
            result.problem,
            AttendanceOperationProblem.persistenceUncertain,
          );
          expect(result.snapshot, isNull);
          expect(
            h.transport.calls.length,
            phase == JournalPhase.confirmed ? 1 : 0,
          );
          expect(h.canonical.calls, isEmpty);
          if (fault != JournalFault.beforeWrite) expect(h.record!.phase, phase);
          if (h.record?.phase == JournalPhase.confirmed) {
            final retry = await h.coordinator.refresh(h.issuer.context());
            expect(retry.problem, AttendanceOperationProblem.recoveryRequired);
            expect(h.canonical.calls, isEmpty);
          }
        },
      );
    }
  }
  test(
    'refresh failure retries refresh only, retaining the complete confirmation',
    () async {
      h.canonical.onRead = () async =>
          throw StateError('fictional private backend message');
      final first = await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      );
      expect(first.outcome, AttendanceOperationOutcome.confirmedNeedsRefresh);
      final bytes = h.disk.snapshot(h.binding);
      h.canonical.onRead = null;
      final retry = await h.coordinator.refresh(h.issuer.context());
      expect(retry.outcome, AttendanceOperationOutcome.confirmed);
      expect(h.transport.calls.length, 1);
      expect(h.disk.snapshot(h.binding), bytes);
      expect(h.disk.writes, 3);
    },
  );
  for (final missing in [true, false]) {
    test(
      'canonical missing=$missing/wrong target never replaces the receipt',
      () async {
        h.canonical.result = missing
            ? null
            : WorkSession(
                id: journalOtherId,
                locationContext: 'factory',
                lifecycleStatus: 'active',
                startedAt: journalTime,
              );
        final result = await h.coordinator.submit(
          h.issuer.context(),
          journalCommand(),
        );
        expect(
          result.outcome,
          AttendanceOperationOutcome.confirmedNeedsRefresh,
        );
        expect(result.snapshot!.canonicalSession, isNull);
        expect(h.record!.phase, JournalPhase.confirmed);
      },
    );
  }
  test('canonical state may have advanced independently of the retained acknowledgement', () async {
    h.canonical.result = WorkSession(
      id: journalSessionId,
      locationContext: 'factory',
      lifecycleStatus: 'voided',
      startedAt: journalTime,
      endedAt: journalTime.add(const Duration(hours: 1)),
      employeeNote: 'fictional canonical note',
    );
    final result = await h.coordinator.submit(
      h.issuer.context(),
      journalCommand(),
    );
    expect(result.snapshot!.canonicalSession!.lifecycleStatus, 'voided');
    expect(h.record!.confirmation!.data['lifecycle_status'], 'active');
  });
  for (final timeout in [false, true]) {
    test(
      'lost response timeout=$timeout retains original command and blocks new intent',
      () async {
        h.transport.onDispatch = (_, _) async => throw timeout
            ? TimeoutException('fictional')
            : StateError('fictional lost reply');
        final command = journalCommand();
        final result = await h.coordinator.submit(h.issuer.context(), command);
        expect(result.problem, AttendanceOperationProblem.transportUncertain);
        expect(h.record!.phase, JournalPhase.mayHaveSent);
        expect(h.record!.command!.parametersJson, command.parametersJson);
        expect(
          (await h.coordinator.submit(
            h.issuer.context(),
            journalCommand(key: 'fictional-new-key-blocked'),
          )).problem,
          AttendanceOperationProblem.commandConflict,
        );
        expect(h.transport.calls.length, 1);
        expect(h.canonical.calls, isEmpty);
      },
    );
  }
  for (final phase in [JournalPhase.mayHaveSent, JournalPhase.uncertain]) {
    test(
      'explicit replay of $phase changes only outgoing flag and confirms full receipt',
      () async {
        final original = recordAt(phase);
        h.inject(original);
        final result = await h.coordinator.replay(h.issuer.context());
        expect(result.outcome, AttendanceOperationOutcome.confirmed);
        final sent = h.transport.calls.single;
        expect(sent.replayOnly, true);
        expect(sent.command.parametersJson, original.command!.parametersJson);
        expect(sent.command.rpcParameters(replayOnly: true), {
          ...original.command!.parameters,
          'p_replay_only': true,
        });
        expect(h.record!.command!.parameters['p_replay_only'], false);
        expect(h.record!.confirmation!.data['status'], 'idempotent_replay');
      },
    );
    test(
      'replay-only miss for $phase leaves uncertainty and every original byte intact',
      () async {
        final original = recordAt(phase);
        h.inject(original);
        final before = h.disk.snapshot(h.binding);
        h.transport.onDispatch = (_, _) async =>
            const AttendanceTransportReply.replayMiss();
        final result = await h.coordinator.replay(h.issuer.context());
        expect(result.problem, AttendanceOperationProblem.replayMiss);
        expect(h.disk.snapshot(h.binding), before);
        expect(h.disk.writes, 0);
        expect(h.canonical.calls, isEmpty);
        expect(
          (await h.coordinator.submit(
            h.issuer.context(),
            journalCommand(),
          )).problem,
          AttendanceOperationProblem.pendingCommand,
        );
        expect(h.transport.calls.length, 1);
      },
    );
  }
  for (final mutation in [
    'broken',
    'missing',
    'extra',
    'wrong_target',
    'wrong_operation',
    'miss_as_ack',
    'created_on_replay',
  ]) {
    test(
      'malformed acknowledgement $mutation cannot confirm/refresh/clear',
      () async {
        final command = journalCommand(
          operation: AttendanceCommandKind.checkOut,
        );
        final row = journalReceipt(command);
        switch (mutation) {
          case 'missing':
            row.remove('event_id');
          case 'extra':
            row['employee_note'] = 'not in receipt contract';
          case 'wrong_target':
            row['session_id'] = journalOtherId;
          case 'wrong_operation':
            row['status'] = 'created';
          case 'miss_as_ack':
            row
              ..clear()
              ..addAll({'contract_version': 2, 'status': 'not_found'});
          case 'created_on_replay':
            row['status'] = 'closed';
        }
        h.transport.onDispatch = (_, _) async =>
            AttendanceTransportReply.acknowledged(
              mutation == 'broken' ? '{' : jsonEncode(row),
            );
        final result = mutation == 'created_on_replay'
            ? await (() {
                h.inject(recordAt(JournalPhase.uncertain, command: command));
                return h.coordinator.replay(h.issuer.context());
              })()
            : await h.coordinator.submit(h.issuer.context(), command);
        expect(
          result.problem,
          AttendanceOperationProblem.malformedAcknowledgement,
        );
        expect(h.record!.confirmation, isNull);
        expect(h.canonical.calls, isEmpty);
      },
    );
  }
  test('unexpected explicit replay miss on initial mutation is malformed, never success', () async {
    h.transport.onDispatch = (_, _) async =>
        const AttendanceTransportReply.replayMiss();
    expect(
      (await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      )).problem,
      AttendanceOperationProblem.malformedAcknowledgement,
    );
  });
  for (final phase in [
    JournalPhase.prepared,
    JournalPhase.mayHaveSent,
    JournalPhase.confirmed,
  ]) {
    test(
      'CAS conflict at $phase is unresolved without overwriting/compacting conflict',
      () async {
        h.storage.beforeCas = (next) async {
          if (next.phase == phase) {
            final conflict = JournalRecord.fromJson({
              ...next.toJson(),
              'revision': next.revision + 3,
            });
            h.inject(conflict);
          }
        };
        final result = await h.coordinator.submit(
          h.issuer.context(),
          journalCommand(),
        );
        expect(result.problem, AttendanceOperationProblem.persistenceUncertain);
        expect(result.journalIssue, JournalIssue.revisionConflict);
        expect(h.record!.revision, h.storage.attempts.last.revision + 3);
        expect(
          h.transport.calls.length,
          phase == JournalPhase.confirmed ? 1 : 0,
        );
        expect(h.canonical.calls, isEmpty);
      },
    );
  }
  test(
    'invalidation before operation makes no storage/transport/canonical calls',
    () async {
      final context = h.issuer.context();
      h.issuer.relogin();
      final result = await h.coordinator.submit(context, journalCommand());
      expect(result.outcome, AttendanceOperationOutcome.invalidated);
      expect(h.events, isEmpty);
      expect(context.released, true);
    },
  );
  test(
    'invalidation in internal prepare read prevents the following CAS',
    () async {
      h.storage.afterRead = () async {
        if (h.storage.reads == 2) h.issuer.relogin();
      };
      expect(
        (await h.coordinator.submit(
          h.issuer.context(),
          journalCommand(),
        )).outcome,
        AttendanceOperationOutcome.invalidated,
      );
      expect(h.disk.writes, 0);
      expect(h.transport.calls, isEmpty);
    },
  );
  for (final phase in [JournalPhase.prepared, JournalPhase.mayHaveSent]) {
    test(
      'invalidation after $phase persistence prevents dispatch/further transitions',
      () async {
        h.storage.afterCas = (r) async {
          if (r.phase == phase) h.issuer.relogin();
        };
        expect(
          (await h.coordinator.submit(
            h.issuer.context(),
            journalCommand(),
          )).outcome,
          AttendanceOperationOutcome.invalidated,
        );
        expect(h.record!.phase, phase);
        expect(h.transport.calls, isEmpty);
        expect(h.storage.attempts.last.phase, phase);
      },
    );
  }
  for (final switchOwner in [true, false]) {
    test(
      'valid late receipt after same-user relogin/owner switch=$switchOwner stays in ORIGINAL slot',
      () async {
        final entered = Completer<void>();
        final reply = Completer<AttendanceTransportReply>();
        final context = h.issuer.context();
        final command = journalCommand();
        h.transport.onDispatch = (_, _) {
          entered.complete();
          return reply.future;
        };
        final operation = h.coordinator.submit(context, command);
        await entered.future;
        final other = switchOwner
            ? journalBinding(
                environment: 'fictional-other',
                auth: journalOtherId,
              )
            : h.binding;
        h.issuer.relogin(asBinding: other);
        expect(context.released, false);
        reply.complete(
          AttendanceTransportReply.acknowledged(
            JournalJson.encode(journalReceipt(command)),
          ),
        );
        final result = await operation;
        expect(result.outcome, AttendanceOperationOutcome.invalidated);
        expect(result.snapshot, isNull);
        expect(h.record!.phase, JournalPhase.confirmed);
        expect(
          h.record!.confirmation!.dataJson,
          journalConfirmation(command).dataJson,
        );
        expect(h.record!.binding.matches(h.binding), true);
        if (switchOwner) expect(h.disk.snapshot(other), isNull);
        expect(h.canonical.calls, isEmpty);
        expect(
          h.transport.calls.single.identity.generation,
          context.identity.generation,
        );
        expect(context.releaseCalls, 1);
        expect(context.released, true);
      },
    );
  }
  for (final fault in [
    JournalFault.beforeWrite,
    JournalFault.afterWrite,
    JournalFault.readback,
  ]) {
    test(
      'late receipt $fault reports unresolved, never fresh durability or publication',
      () async {
        h.storage.faults[JournalPhase.confirmed] = fault;
        h.transport.onDispatch = (command, _) async {
          h.issuer.relogin();
          return AttendanceTransportReply.acknowledged(
            JournalJson.encode(journalReceipt(command)),
          );
        };
        final result = await h.coordinator.submit(
          h.issuer.context(),
          journalCommand(),
        );
        expect(result.outcome, AttendanceOperationOutcome.unresolved);
        expect(result.problem, AttendanceOperationProblem.persistenceUncertain);
        expect(result.snapshot, isNull);
        expect(h.canonical.calls, isEmpty);
        if (fault != JournalFault.beforeWrite) {
          expect(h.record!.phase, JournalPhase.confirmed);
        }
        expect(
          (await h.coordinator.refresh(h.issuer.context())).problem,
          AttendanceOperationProblem.recoveryRequired,
        );
      },
    );
  }
  test('late receipt with changed complete prior record is rejected despite matching key/revision', () async {
    h.transport.onDispatch = (command, _) async {
      h.issuer.relogin();
      // Even semantically identical parameters are NOT the exact frozen bytes
      // submitted by this receipt-only capability. Key/revision alone cannot
      // authorize finalization of a changed record.
      final other = JournalCommand.frozen(
        protocol: command.protocol,
        operation: command.operation,
        parametersJson: ' ${command.parametersJson} ',
      );
      expect(other.sameRequest(command), true);
      h.inject(
        JournalRecord.fromJson({
          ...h.record!.toJson(),
          'command': other.toJson(),
        }),
      );
      return AttendanceTransportReply.acknowledged(
        JournalJson.encode(journalReceipt(command)),
      );
    };
    final result = await h.coordinator.submit(
      h.issuer.context(),
      journalCommand(),
    );
    expect(result.problem, AttendanceOperationProblem.persistenceUncertain);
    expect(result.journalIssue, JournalIssue.revisionConflict);
    expect(h.record!.confirmation, isNull);
    expect(h.canonical.calls, isEmpty);
  });
  test(
    'result accessed after a later generation cannot publish the old snapshot',
    () async {
      final result = await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      );
      expect(result.snapshot, isNotNull);
      h.issuer.relogin();
      expect(result.isCurrent, false);
      expect(result.snapshot, isNull);
      expect(result.outcome, AttendanceOperationOutcome.invalidated);
    },
  );
  test(
    'invalidation during canonical read suppresses its late result',
    () async {
      h.canonical.onRead = () async {
        h.issuer.relogin();
        return journalSession();
      };
      final result = await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      );
      expect(result.outcome, AttendanceOperationOutcome.invalidated);
      expect(result.snapshot, isNull);
      expect(h.record!.phase, JournalPhase.confirmed);
      expect(h.transport.calls.length, 1);
    },
  );
  for (final differentInstance in [true, false]) {
    test(
      'same-binding calls serialize across coordinator instances=$differentInstance',
      () async {
        final entered = Completer<void>();
        final reply = Completer<AttendanceTransportReply>();
        final command = journalCommand();
        h.transport.onDispatch = (_, _) {
          entered.complete();
          return reply.future;
        };
        final first = h.coordinator.submit(h.issuer.context(), command);
        await entered.future;
        final core = differentInstance ? h.newCoordinator() : h.coordinator;
        final before = h.storage.reads;
        final second = core.submit(h.issuer.context(), command);
        await Future<void>.delayed(Duration.zero);
        expect(h.storage.reads, before);
        expect(h.transport.calls.length, 1);
        reply.complete(
          AttendanceTransportReply.acknowledged(
            JournalJson.encode(journalReceipt(command)),
          ),
        );
        expect((await first).outcome, AttendanceOperationOutcome.confirmed);
        final result = await second;
        expect(
          result.outcome,
          differentInstance
              ? AttendanceOperationOutcome.unresolved
              : AttendanceOperationOutcome.confirmed,
        );
        if (differentInstance) {
          expect(result.problem, AttendanceOperationProblem.recoveryRequired);
        }
        expect(h.transport.calls.length, 1);
        expect(h.disk.writes, 3);
      },
    );
  }
  test('caller timeout/disposal keeps submitted work/context/queue until receipt and release settle', () async {
    final entered = Completer<void>();
    final reply = Completer<AttendanceTransportReply>();
    final release = Completer<void>();
    final context = h.issuer.context()..onRelease = (() => release.future);
    final command = journalCommand();
    h.transport.onDispatch = (_, _) {
      entered.complete();
      return reply.future;
    };
    final operation = h.coordinator.submit(context, command);
    await entered.future;
    await expectLater(
      operation.timeout(Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    context.callerDisposed = true;
    final before = h.storage.reads;
    final queued = h.coordinator.refresh(h.issuer.context());
    await Future<void>.delayed(Duration.zero);
    expect(context.released, false);
    expect(h.storage.reads, before);
    reply.complete(
      AttendanceTransportReply.acknowledged(
        JournalJson.encode(journalReceipt(command)),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(h.record!.phase, JournalPhase.confirmed);
    expect(h.canonical.calls, isEmpty);
    expect(context.released, false);
    expect(h.storage.reads, before + 1); // receipt-only internal read
    release.complete();
    expect((await operation).outcome, AttendanceOperationOutcome.invalidated);
    expect((await queued).outcome, AttendanceOperationOutcome.confirmed);
    expect(h.transport.calls.length, 1);
  });
  test('legacy input, stored legacy command and pending migration metadata remain gated', () async {
    final legacy = journalCommand(protocol: JournalProtocol.legacyV1);
    expect(
      (await h.coordinator.submit(h.issuer.context(), legacy)).problem,
      AttendanceOperationProblem.legacyCommand,
    );
    expect(h.events, isEmpty);
    h.inject(JournalRecord.absent(h.binding).prepare(legacy));
    expect(
      (await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      )).problem,
      AttendanceOperationProblem.legacyCommand,
    );
    h.inject(migrationRecord(h.binding));
    final bytes = h.disk.snapshot(h.binding);
    for (final result in [
      await h.coordinator.submit(h.issuer.context(), journalCommand()),
      await h.coordinator.replay(h.issuer.context()),
      await h.coordinator.refresh(h.issuer.context()),
    ]) {
      expect(result.problem, AttendanceOperationProblem.migrationPending);
    }
    expect(h.disk.snapshot(h.binding), bytes);
    expect(h.storage.attempts, isEmpty);
    expect(h.transport.calls, isEmpty);
    expect(h.canonical.calls, isEmpty);
  });
  for (final phase in [
    JournalPhase.prepared,
    JournalPhase.confirmed,
    JournalPhase.blocked,
  ]) {
    test(
      'restored $phase is not treated as new durable authorization to send',
      () async {
        final record = recordAt(phase);
        h.inject(record);
        final result = await h.coordinator.replay(h.issuer.context());
        expect(
          result.problem,
          phase == JournalPhase.blocked
              ? AttendanceOperationProblem.blockedRecord
              : AttendanceOperationProblem.recoveryRequired,
        );
        expect(h.disk.snapshot(h.binding), JournalCodec.encode(record));
        expect(h.storage.attempts, isEmpty);
        expect(h.transport.calls, isEmpty);
      },
    );
  }
  for (final inFlight in [false, true]) {
    test(
      'context reuse inFlight=$inFlight cannot repeat an attempt or release ownership twice',
      () async {
        final entered = Completer<void>();
        final reply = Completer<AttendanceTransportReply>();
        final context = h.issuer.context();
        final command = journalCommand();
        h.transport.onDispatch = (_, _) {
          entered.complete();
          return reply.future;
        };
        final operation = h.coordinator.submit(context, command);
        await entered.future;
        if (!inFlight) {
          reply.complete(
            AttendanceTransportReply.acknowledged(
              JournalJson.encode(journalReceipt(command)),
            ),
          );
          await operation;
        }
        final reads = h.storage.reads;
        try {
          final result = await h.newCoordinator().submit(context, command);
          expect(result.problem, AttendanceOperationProblem.contextUnavailable);
          expect(result.snapshot, isNull);
          expect(context.releaseCalls, inFlight ? 0 : 1);
          expect(h.storage.reads, reads);
          expect(h.transport.calls.length, 1);
        } finally {
          if (inFlight) {
            reply.complete(
              AttendanceTransportReply.acknowledged(
                JournalJson.encode(journalReceipt(command)),
              ),
            );
          }
          await operation;
        }
        expect(context.releaseCalls, 1);
        expect(
          (await h.coordinator.refresh(h.issuer.context())).outcome,
          AttendanceOperationOutcome.confirmed,
        );
      },
    );
  }
  test(
    'unavailable context identity returns only a safe unresolved code',
    () async {
      final context = _UnavailableContext();
      final result = await h.coordinator.submit(context, journalCommand());
      expect(result.outcome, AttendanceOperationOutcome.unresolved);
      expect(result.problem, AttendanceOperationProblem.contextUnavailable);
      expect(result.snapshot, isNull);
      expect(context.released, true);
      expect(h.events, isEmpty);
    },
  );
  test('context release failure retains receipt but returns unresolved without publication', () async {
    final context = h.issuer.context()
      ..onRelease = (() async =>
          throw StateError('fictional private release error'));
    final result = await h.coordinator.submit(context, journalCommand());
    expect(result.problem, AttendanceOperationProblem.contextUnavailable);
    expect(result.snapshot, isNull);
    expect(h.record!.phase, JournalPhase.confirmed);
    expect(h.transport.calls.length, 1);
    expect(context.releaseCalls, 1);
  });
  for (final issue in [
    JournalIssue.corrupt,
    JournalIssue.unreadable,
    JournalIssue.missingKey,
    JournalIssue.invalidatedKey,
    JournalIssue.authenticationFailed,
    JournalIssue.storageFailure,
  ]) {
    test(
      'unavailable journal $issue never becomes absence or permission to send',
      () async {
        h.disk.readIssues[h.binding.storageIdentity] = issue;
        final result = await h.coordinator.submit(
          h.issuer.context(),
          journalCommand(),
        );
        expect(result.problem, AttendanceOperationProblem.journalUnavailable);
        expect(result.journalIssue, issue);
        expect(h.disk.writes, 0);
        expect(h.transport.calls, isEmpty);
      },
    );
  }
  test(
    'mismatched owner/environment record is not read as an empty slot',
    () async {
      h.disk.inject(
        h.binding,
        JournalCodec.encode(
          JournalRecord.absent(journalBinding(environment: 'fictional-other'))
              .prepare(journalCommand()),
        ),
      );
      final result = await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      );
      expect(result.journalIssue, JournalIssue.identityMismatch);
      expect(h.disk.writes, 0);
      expect(h.transport.calls, isEmpty);
    },
  );
  test('changed complete confirmation invalidates volatile proof, without selecting a revision', () async {
    expect(
      (await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      )).outcome,
      AttendanceOperationOutcome.confirmed,
    );
    final original = h.record!;
    h.inject(
      JournalRecord.fromJson({
        ...original.toJson(),
        'revision': original.revision + 1,
      }),
    );
    final result = await h.coordinator.refresh(h.issuer.context());
    expect(result.problem, AttendanceOperationProblem.recoveryRequired);
    h.inject(original);
    expect(
      (await h.coordinator.refresh(h.issuer.context())).problem,
      AttendanceOperationProblem.recoveryRequired,
    );
    expect(h.canonical.calls.length, 1);
    expect(h.transport.calls.length, 1);
  });
  test('changed target after confirmation CAS blocks canonical refresh and publication', () async {
    h.storage.afterCas = (record) async {
      if (record.phase == JournalPhase.confirmed) {
        h.inject(
          JournalRecord.fromJson({
            ...record.toJson(),
            'revision': record.revision + 1,
          }),
        );
      }
    };
    final result = await h.coordinator.submit(
      h.issuer.context(),
      journalCommand(),
    );
    expect(result.problem, AttendanceOperationProblem.journalUnavailable);
    expect(result.journalIssue, JournalIssue.revisionConflict);
    expect(result.snapshot, isNull);
    expect(h.canonical.calls, isEmpty);
    expect(h.record!.phase, JournalPhase.confirmed);
  });
  test('invalidation during receipt CAS still finalizes only the submitted receipt', () async {
    h.storage.afterCas = (record) async {
      if (record.phase == JournalPhase.confirmed) h.issuer.relogin();
    };
    final result = await h.coordinator.submit(
      h.issuer.context(),
      journalCommand(),
    );
    expect(result.outcome, AttendanceOperationOutcome.invalidated);
    expect(h.record!.phase, JournalPhase.confirmed);
    expect(h.storage.attempts.length, 3);
    expect(h.canonical.calls, isEmpty);
    expect(result.snapshot, isNull);
  });
  test(
    'malformed late response grants no post-invalidation write authority',
    () async {
      h.transport.onDispatch = (_, _) async {
        h.issuer.relogin();
        return const AttendanceTransportReply.acknowledged('{');
      };
      final result = await h.coordinator.submit(
        h.issuer.context(),
        journalCommand(),
      );
      expect(
        result.problem,
        AttendanceOperationProblem.malformedAcknowledgement,
      );
      expect(result.snapshot, isNull);
      expect(h.storage.attempts.map((r) => r.phase), [
        JournalPhase.prepared,
        JournalPhase.mayHaveSent,
      ]);
      expect(h.canonical.calls, isEmpty);
    },
  );
  test(
    'queued old-generation attempt stops before new storage or dispatch',
    () async {
      final entered = Completer<void>();
      final reply = Completer<AttendanceTransportReply>();
      final command = journalCommand();
      h.transport.onDispatch = (_, _) {
        entered.complete();
        return reply.future;
      };
      final first = h.coordinator.submit(h.issuer.context(), command);
      await entered.future;
      final secondContext = h.issuer.context();
      final second = h.coordinator.submit(secondContext, command);
      h.issuer.relogin();
      final before = h.storage.reads;
      reply.complete(
        AttendanceTransportReply.acknowledged(
          JournalJson.encode(journalReceipt(command)),
        ),
      );
      expect((await first).outcome, AttendanceOperationOutcome.invalidated);
      expect((await second).outcome, AttendanceOperationOutcome.invalidated);
      expect(h.storage.reads, before + 1);
      expect(secondContext.released, true);
      expect(h.transport.calls.length, 1);
    },
  );
  test('timeout during persistence does not cancel the submitted write or send after disposal', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    final context = h.issuer.context();
    h.storage.beforeCas = (record) async {
      if (record.phase == JournalPhase.prepared) {
        entered.complete();
        await finish.future;
      }
    };
    final operation = h.coordinator.submit(context, journalCommand());
    await entered.future;
    await expectLater(
      operation.timeout(Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    context.callerDisposed = true;
    expect(context.released, false);
    finish.complete();
    expect((await operation).outcome, AttendanceOperationOutcome.invalidated);
    expect(h.record!.phase, JournalPhase.prepared);
    expect(h.transport.calls, isEmpty);
    expect(context.released, true);
  });
  test('different full bindings are not claimed to share global ownership/serialization', () async {
    final other = FictionalAttendanceOperations(
      binding: journalBinding(environment: 'fictional-separate'),
    );
    final entered = Completer<void>();
    final reply = Completer<AttendanceTransportReply>();
    final command = journalCommand();
    h.transport.onDispatch = (_, _) {
      entered.complete();
      return reply.future;
    };
    final first = h.coordinator.submit(h.issuer.context(), command);
    await entered.future;
    try {
      expect(
        (await other.coordinator.submit(
          other.issuer.context(),
          command,
        )).outcome,
        AttendanceOperationOutcome.confirmed,
      );
      expect(h.record!.phase, JournalPhase.mayHaveSent);
    } finally {
      reply.complete(
        AttendanceTransportReply.acknowledged(
          JournalJson.encode(journalReceipt(command)),
        ),
      );
      await first;
    }
  });
  test('completed migration tombstone may carry a NEW v2 intent without migrating anything', () async {
    final imported = migrationRecord(h.binding, confirmed: true);
    final tombstone = imported
        .markLegacyCleanupComplete(imported.migration!.sourceSha256)
        .compactConfirmed(
          canonicalStateVerified: true,
          confirmationConsumed: true,
        );
    h.inject(tombstone);
    final result = await h.coordinator.submit(
      h.issuer.context(),
      journalCommand(),
    );
    expect(result.outcome, AttendanceOperationOutcome.confirmed);
    expect(h.record!.migration!.toJson(), tombstone.migration!.toJson());
    expect(
      h.transport.calls.single.command.protocol,
      JournalProtocol.attendanceV2,
    );
  });
  test(
    'standalone note save has no command operation or transport path',
    () async {
      expect(
        () => JournalCommand.fromJson({
          'protocol': 'attendance-v2-final-notes',
          'operation': 'update_employee_note',
          'idempotency_key': journalKey,
          'parameters_json': jsonEncode({
            'p_work_session_id': journalSessionId,
            'p_employee_note': 'fictional note',
          }),
        }),
        throwsA(isA<JournalException>()),
      );
      expect(h.events, isEmpty);
    },
  );
}

class _UnavailableContext implements AttendanceOperationContext {
  bool released = false;
  @override
  AttendanceOperationIdentity get identity =>
      throw StateError('fictional private context error');
  @override
  bool get isCurrent => true;
  @override
  Future<void> release() async {
    released = true;
  }
}
