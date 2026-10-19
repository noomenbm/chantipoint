import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/employee_attendance_workflow.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/employee_workflow_fixture.dart';
import 'support/journal_fixtures.dart';
import 'support/memory_journal_storage.dart';

class _Verifier implements JournalVerifier {
  final done = Completer<JournalIssue?>();
  final calls = <List<int>>[];
  @override
  Future<JournalIssue?> verify(JournalBinding binding, List<int> record) {
    calls.add(List.of(record));
    return done.future;
  }
}

class _UnreadableContext implements AttendanceOperationContext {
  final released = Completer<void>();
  int releases = 0;
  @override
  AttendanceOperationIdentity get identity =>
      throw StateError('private fixture');
  @override
  bool get isCurrent => true;
  @override
  Future<void> release() {
    releases++;
    return released.future;
  }
}

void main() {
  late EmployeeWorkflowFixture f;
  setUp(() => f = EmployeeWorkflowFixture());
  tearDown(() => f.workflow.dispose());

  test('capture invalidInput has input feedback, releases ownership and permits correction', () async {
    await f.workflow.refresh();
    f.clock.value = DateTime.utc(
      10000,
    ); // Invalid C4 protocol timestamp, no text change.
    await f.workflow.checkIn(siteDescription: 'Réparation à Montréal');
    expect(f.workflow.state.status, EmployeeAttendanceStatus.invalidInput);
    expect(f.workflow.state.inputError, AttendanceInputError.invalidCapture);
    expect(f.workflow.state.message, isNot(contains('Actualisation')));
    expect(f.location.calls, 0);
    expect(f.operations.disk.writes, 0);
    expect(f.operations.transport.calls, isEmpty);
    expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
    expect(f.workflow.canCheckIn, isTrue);
    f.clock.value = DateTime.utc(2026, 10, 19);
    f.workflow.clearInputError();
    await f.workflow.checkIn(siteDescription: 'Réparation à Montréal');
    expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    expect(f.operations.transport.calls, hasLength(1));
  });

  for (final checkout in [false, true]) {
    final limit = checkout ? 1000 : 500;
    for (final offset in [-1, 0, 1]) {
      test(
        'combining text ${limit + offset} code points for ${checkout ? "note" : "description"}',
        () async {
          if (checkout) {
            f.setActive(workflowSession());
            f.operations.canonical.result = workflowSession(closed: true);
          }
          await f.workflow.refresh();
          final points = limit + offset;
          final original =
              '${'e\u0301' * (points ~/ 2)}${points.isOdd ? 'é' : ''}';
          expect(original.runes.length, points);
          final contextsBefore = f.contexts.length;
          Future<void> submit(String text) => checkout
              ? f.workflow.checkOut(note: CheckoutNoteIntent.replace(text))
              : f.workflow.checkIn(siteDescription: text);
          await submit(original);
          if (offset > 0) {
            expect(
              f.workflow.state.status,
              EmployeeAttendanceStatus.invalidInput,
            );
            expect(
              f.workflow.state.inputError,
              checkout
                  ? AttendanceInputError.noteTooLong
                  : AttendanceInputError.descriptionTooLong,
            );
            expect(
              f.workflow.state.message,
              contains('$limit caractères Unicode'),
            );
            expect(f.workflow.state.message, isNot(contains('Actualisation')));
            expect(f.contexts.length, contextsBefore);
            expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
            expect(f.keys.calls, 0);
            expect(f.location.calls, 0);
            expect(f.operations.disk.writes, 0);
            expect(f.operations.transport.calls, isEmpty);
            expect(f.capture.isBusy, isFalse);
            if (checkout) {
              expect(
                f.workflow.state.session!.employeeNote,
                'Note canonique fictive',
              );
            }
            // An unchanged invalid retry cannot issue credentials, evidence or a key.
            await submit(original);
            expect(f.contexts.length, contextsBefore);
            f.clock.value = DateTime.utc(2026, 10, 19, 12);
            await submit('  À Montréal, l’équipe répare l’entrée.  ');
            expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
            expect(f.keys.calls, 1);
            expect(f.location.calls, 1);
            expect(f.contexts.length, contextsBefore + 1);
            expect(f.contexts.last.releaseCalls, 1);
            expect(
              f.operations.transport.calls.single.command.parameters[checkout
                  ? 'p_employee_note'
                  : 'p_site_description'],
              '  À Montréal, l’équipe répare l’entrée.  ',
            );
            expect(
              f
                  .operations
                  .transport
                  .calls
                  .single
                  .command
                  .parameters['p_device_observed_at'],
              '2026-10-19T12:00:00.000Z',
            );
          } else {
            expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
            expect(
              f.operations.transport.calls.single.command.parameters[checkout
                  ? 'p_employee_note'
                  : 'p_site_description'],
              original,
            );
          }
        },
      );
    }

    test(
      'ordinary French ${checkout ? "note" : "description"} remains unchanged',
      () async {
        if (checkout) {
          f.setActive(workflowSession());
          f.operations.canonical.result = workflowSession(closed: true);
        }
        await f.workflow.refresh();
        const text =
            '  À Montréal : réparation d’une fenêtre, côté ouest. 🛠️  ';
        await (checkout
            ? f.workflow.checkOut(note: const CheckoutNoteIntent.replace(text))
            : f.workflow.checkIn(siteDescription: text));
        expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        expect(
          f.operations.transport.calls.single.command.parameters[checkout
              ? 'p_employee_note'
              : 'p_site_description'],
          text,
        );
      },
    );

    for (final invalid in ['\u0000', '\uD800']) {
      test(
        'unsupported Unicode ${invalid.codeUnitAt(0)} rejected before capture/$checkout',
        () async {
          if (checkout) f.setActive(workflowSession());
          await f.workflow.refresh();
          await (checkout
              ? f.workflow.checkOut(note: CheckoutNoteIntent.replace(invalid))
              : f.workflow.checkIn(siteDescription: invalid));
          expect(
            f.workflow.state.status,
            EmployeeAttendanceStatus.invalidInput,
          );
          expect(f.workflow.state.inputError, AttendanceInputError.invalidText);
          expect(f.location.calls, 0);
          expect(f.keys.calls, 0);
          expect(f.contexts.length, 1);
          expect(f.operations.disk.writes, 0);
          expect(f.operations.transport.calls, isEmpty);
        },
      );
    }
  }

  test(
    'malformed issued context cleanup remains part of the workflow future',
    () async {
      final context = _UnreadableContext();
      final workflow = EmployeeAttendanceWorkflow(
        issueContext: () => context,
        authorizationChanges: f.changes,
        activeSessions: f.active,
        capture: f.capture,
        coordinator: f.operations.coordinator,
      );
      addTearDown(workflow.dispose);
      final work = workflow.refresh();
      await pumpEventQueue();
      expect(workflow.isBusy, isTrue);
      expect(context.releases, 1);
      expect(f.operations.storage.reads, 0);
      context.released.complete();
      await work;
      expect(workflow.isBusy, isFalse);
      expect(
        workflow.state.status,
        EmployeeAttendanceStatus.authorizationUnavailable,
      );
    },
  );

  test('empty authorized canonical selection enables one check-in', () async {
    await f.workflow.refresh();
    expect(f.workflow.canCheckIn, isTrue);
    expect(f.workflow.canCheckOut, isFalse);
    expect(f.active.calls.single.binding.matches(f.operations.binding), isTrue);
    expect(f.contexts.single.releaseCalls, 1);
    expect(f.operations.transport.calls, isEmpty);
  });

  test(
    'refresh ownership stays busy until asynchronous context release settles',
    () async {
      final release = Completer<void>();
      f.active.onRead = () async {
        f.contexts.last.onRelease = () => release.future;
        return null;
      };
      final work = f.workflow.refresh();
      await pumpEventQueue();
      expect(f.workflow.isBusy, isTrue);
      await f.workflow.checkIn();
      expect(f.keys.calls, 0);
      release.complete();
      await work;
      expect(f.workflow.canCheckIn, isTrue);
    },
  );

  test(
    'context release failure blocks presentation without surfacing its message',
    () async {
      f.active.onRead = () async {
        f.contexts.last.onRelease = () async =>
            throw StateError('private fixture detail');
        return null;
      };
      await f.workflow.refresh();
      expect(f.workflow.state.status, EmployeeAttendanceStatus.blocked);
      expect(f.workflow.state.message, isNull);
      expect(f.workflow.canCheckIn, isFalse);
      expect(f.workflow.isBusy, isFalse);
    },
  );

  test('same-user new generation during context issuance cannot retarget old intent', () async {
    await f.workflow.refresh();
    f.beforeIssue = () => f.invalidate(notify: false);
    await f.workflow.checkIn();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.authorizationUnavailable,
    );
    expect(f.location.calls, 0);
    expect(f.keys.calls, 0);
    expect(f.contexts.last.releaseCalls, 1);
  });

  test(
    'closed row in active selection fails closed rather than enabling check-in',
    () async {
      f.active.result = workflowSession(closed: true);
      await f.workflow.refresh();
      expect(
        f.workflow.state.status,
        EmployeeAttendanceStatus.refreshUnavailable,
      );
      expect(f.workflow.canCheckIn, isFalse);
    },
  );

  for (final phase in [JournalPhase.prepared, JournalPhase.mayHaveSent]) {
    test(
      'reported storage failure at $phase never confirms or submits new intent',
      () async {
        await f.workflow.refresh();
        f.operations.storage.faults[phase] = JournalFault.afterWrite;
        await f.workflow.checkIn();
        expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
        expect(f.operations.transport.calls, isEmpty);
        expect(f.workflow.canCheckIn, isFalse);
        await f.workflow.checkIn();
        expect(f.keys.calls, 1);
      },
    );
  }

  test('canonical network error retains durable confirmation and suppresses details', () async {
    await f.workflow.refresh();
    f.operations.canonical.onRead = () async =>
        throw StateError('private fixture');
    await f.workflow.checkIn();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.confirmedNeedsRefresh,
    );
    expect(f.workflow.state.session, isNull);
    expect(f.operations.record!.confirmation, isNotNull);
  });

  test('restart recovery waits for durability barrier before canonical publication', () async {
    final verifier = _Verifier();
    f = EmployeeWorkflowFixture(verifier: verifier);
    f.operations.inject(recordAt(JournalPhase.confirmed));
    await f.workflow.refresh();
    final work = f.workflow.recover();
    await pumpEventQueue();
    expect(
      verifier.calls.single,
      f.operations.disk.snapshot(f.operations.binding),
    );
    expect(f.workflow.state.session, isNull);
    expect(f.operations.canonical.calls, isEmpty);
    verifier.done.complete(null);
    await work;
    expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    expect(f.operations.transport.calls, isEmpty);
  });

  test(
    'malformed acknowledgement remains unresolved without canonical read',
    () async {
      await f.workflow.refresh();
      f.operations.transport.onDispatch = (_, _) async =>
          const AttendanceTransportReply.acknowledged('{"status":"created"}');
      await f.workflow.checkIn();
      expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
      expect(f.operations.canonical.calls, isEmpty);
      expect(f.workflow.canRecover, isTrue);
    },
  );

  test(
    'changed session observation rejects a delayed active-session selection',
    () async {
      final result = Completer<WorkSession?>();
      f.active.onRead = () => result.future;
      final work = f.workflow.refresh();
      await pumpEventQueue();
      f.setActive(workflowSession(id: journalOtherId));
      result.complete(workflowSession());
      await work;
      expect(
        f.workflow.state.status,
        EmployeeAttendanceStatus.refreshUnavailable,
      );
      expect(f.workflow.state.session, isNull);
      expect(f.workflow.canCheckOut, isFalse);
    },
  );

  test('changed session during submitted work retains receipt without stale publication', () async {
    await f.workflow.refresh();
    final result = Completer<AttendanceTransportReply>();
    f.operations.transport.onDispatch = (_, _) => result.future;
    final work = f.workflow.checkIn();
    await pumpEventQueue();
    final command = f.operations.transport.calls.single.command;
    f.setActive(workflowSession(id: journalOtherId));
    result.complete(
      AttendanceTransportReply.acknowledged(
        JournalJson.encode(journalReceipt(command)),
      ),
    );
    await work;
    expect(f.operations.record!.phase, JournalPhase.confirmed);
    expect(f.workflow.state.session, isNull);
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.refreshUnavailable,
    );
  });

  test(
    'outbox changes during capture are gated by coordinator, never overwritten',
    () async {
      await f.workflow.refresh();
      final location = Completer<LocationEvidence>();
      f.location.onAcquire = () => location.future;
      final work = f.workflow.checkIn();
      final original = recordAt(JournalPhase.uncertain);
      f.operations.inject(original);
      location.complete(const LocationEvidence());
      await work;
      expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
      expect(
        f.operations.record!.command!.parametersJson,
        original.command!.parametersJson,
      );
      expect(f.operations.transport.calls, isEmpty);
    },
  );

  test('check-in freezes original input/time and confirms only after canonical read', () async {
    await f.workflow.refresh();
    final acquired = Completer<LocationEvidence>();
    f.location.onAcquire = () => acquired.future;
    final canonical = Completer<WorkSession?>();
    f.operations.canonical.onRead = () => canonical.future;
    final operation = f.workflow.checkIn(siteDescription: '  Lieu e\u0301  ');
    expect(f.workflow.state.status, EmployeeAttendanceStatus.acquiringLocation);
    f.clock.value = DateTime.utc(2030);
    expect(f.keys.calls, 1);
    await f.workflow.checkIn(siteDescription: 'Deuxième');
    await f.workflow.refresh();
    expect(f.keys.calls, 1);
    expect(f.active.calls, hasLength(1));
    acquired.complete(const LocationEvidence());
    await pumpEventQueue();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.awaitingConfirmation,
    );
    expect(f.workflow.state.session, isNull);
    final command = f.operations.transport.calls.single.command;
    expect(command.parameters['p_site_description'], '  Lieu e\u0301  ');
    expect(
      command.parameters['p_device_observed_at'],
      '2026-10-16T03:45:00.000Z',
    );
    expect(f.operations.record!.phase, JournalPhase.confirmed);
    canonical.complete(workflowSession());
    await operation;
    expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    expect(f.workflow.state.session!.employeeNote, 'Note canonique fictive');
    expect(f.contexts.last.releaseCalls, 1);
    // No presentation-layer compaction or second command behind a retained receipt.
    expect(f.workflow.canCheckOut, isFalse);
    expect(f.operations.record!.confirmation, isNotNull);
  });

  for (final note in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace(''),
    const CheckoutNoteIntent.replace('  e\u0301\ntexte  '),
  ]) {
    test(
      'checkout freezes ${note.action.name}/${note.text ?? "null"} intent',
      () async {
        f.setActive(workflowSession());
        f.operations.canonical.result = workflowSession(
          closed: true,
          note: note.text,
        );
        await f.workflow.refresh();
        final acquired = Completer<LocationEvidence>();
        f.location.onAcquire = () => acquired.future;
        final work = f.workflow.checkOut(note: note);
        expect(f.workflow.canCheckOut, isFalse);
        await f.workflow.checkOut(
          note: const CheckoutNoteIntent.replace('second'),
        );
        acquired.complete(const LocationEvidence());
        await work;
        final command = f.operations.transport.calls.single.command;
        expect(command.operation, AttendanceCommandKind.checkOut);
        expect(command.parameters['p_work_session_id'], journalSessionId);
        expect(command.parameters['p_note_action'], note.action.name);
        expect(command.parameters['p_employee_note'], note.text);
        expect(f.keys.calls, 1);
        expect(f.workflow.state.session!.isActive, isFalse);
      },
    );
  }

  for (final classification in WorkSession.locationContexts) {
    test(
      'canonical classification $classification comes from SELECT, not device',
      () async {
        f.operations.canonical.result = workflowSession(
          context: classification,
        );
        await f.workflow.refresh();
        await f.workflow.checkIn();
        expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
        expect(f.workflow.state.session!.locationContext, classification);
      },
    );
  }

  test(
    'transport uncertainty blocks new intent; replay uses original bytes/key',
    () async {
      await f.workflow.refresh();
      f.operations.transport.onDispatch = (_, _) async =>
          throw StateError('fixture');
      await f.workflow.checkIn(siteDescription: 'Original');
      expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
      final original = f.operations.record!.command!;
      f.operations.transport.onDispatch = null;
      await f.workflow.checkIn(siteDescription: 'Another');
      await f.workflow.recover();
      final calls = f.operations.transport.calls;
      expect(calls, hasLength(2));
      expect(calls.last.replayOnly, isTrue);
      expect(calls.last.command.parametersJson, original.parametersJson);
      expect(calls.last.command.key, original.key);
      expect(f.keys.calls, 1);
      expect(f.location.calls, 1);
      expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    },
  );

  test('replay miss remains pending across repeated explicit checks', () async {
    f.operations.inject(recordAt(JournalPhase.mayHaveSent));
    f.operations.transport.onDispatch = (_, _) async =>
        const AttendanceTransportReply.replayMiss();
    await f.workflow.refresh();
    await f.workflow.recover();
    await f.workflow.recover();
    expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
    expect(f.workflow.canCheckIn, isFalse);
    expect(f.operations.transport.calls.every((c) => c.replayOnly), isTrue);
    expect(f.keys.calls, 0);
    expect(f.location.calls, 0);
    expect(f.operations.record!.phase, JournalPhase.mayHaveSent);
  });

  for (final phase in [JournalPhase.prepared, JournalPhase.blocked]) {
    test('$phase never starts a new command or recaptures evidence', () async {
      f.operations.inject(recordAt(phase));
      await f.workflow.refresh();
      await f.workflow.checkIn();
      await f.workflow.recover();
      expect(f.workflow.canCheckIn, isFalse);
      expect(f.workflow.canRecover, isFalse);
      expect(f.operations.transport.calls, isEmpty);
      expect(f.location.calls, 0);
    });
  }

  test('legacy command and pending migration gate all v2 actions', () async {
    final command = journalCommand(protocol: JournalProtocol.legacyV1);
    final record = JournalRecord.absent(f.operations.binding).importLegacy(
      command,
      JournalMigration(
        sourceBasename: 'attendance_fixture.json',
        sourceSha256: 'a' * 64,
        legacyOwner:
            '${f.operations.binding.companyId}:${f.operations.binding.profileId}',
        bindingApprovalRef: 'fixture-approval',
      ),
    );
    f.operations.inject(record);
    await f.workflow.refresh();
    expect(f.workflow.state.status, EmployeeAttendanceStatus.blocked);
    expect(f.workflow.canRecover, isFalse);
    expect(f.active.calls, isEmpty);
  });

  for (final issue in [
    JournalIssue.missingKey,
    JournalIssue.corrupt,
    JournalIssue.identityMismatch,
  ]) {
    test('storage $issue fails closed before canonical read', () async {
      f.operations.disk.readIssues[f.operations.binding.storageIdentity] =
          issue;
      await f.workflow.refresh();
      expect(f.workflow.state.status, EmployeeAttendanceStatus.blocked);
      expect(f.active.calls, isEmpty);
      expect(f.workflow.canCheckIn, isFalse);
    });
  }

  test('reported confirmation write failure does not prove success even if readable', () async {
    await f.workflow.refresh();
    f.operations.storage.faults[JournalPhase.confirmed] =
        JournalFault.afterWrite;
    await f.workflow.checkIn();
    expect(f.operations.record!.phase, JournalPhase.confirmed);
    expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
    expect(f.workflow.state.session, isNull);
    expect(f.operations.canonical.calls, isEmpty);
    await f.workflow.refresh();
    expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
    await f.workflow
        .recover(); // No verifier: receipt readability is insufficient.
    expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
    expect(f.operations.transport.calls, hasLength(1));
  });

  test('confirmed receipt plus unavailable canonical read allows refresh, not new intent', () async {
    await f.workflow.refresh();
    f.operations.canonical.result = null;
    await f.workflow.checkIn();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.confirmedNeedsRefresh,
    );
    expect(f.workflow.state.session, isNull);
    expect(f.workflow.canCheckIn, isFalse);
    final receipt = f.operations.record!.confirmation!.dataJson;
    f.operations.canonical.result = workflowSession();
    await f.workflow.refresh();
    expect(f.workflow.state.status, EmployeeAttendanceStatus.confirmed);
    expect(f.operations.record!.confirmation!.dataJson, receipt);
    expect(f.operations.transport.calls, hasLength(1));
  });

  test(
    'restored confirmed receipt cannot publish canonical data without barrier',
    () async {
      f.operations.inject(recordAt(JournalPhase.confirmed));
      await f.workflow.refresh();
      expect(f.workflow.state.status, EmployeeAttendanceStatus.pending);
      expect(f.workflow.state.session, isNull);
      expect(f.operations.canonical.calls, isEmpty);
      expect(f.workflow.canRecover, isTrue);
    },
  );

  test(
    'active selection failure is recoverable and not an empty session',
    () async {
      f.active.onRead = () async => throw StateError('fictional failure');
      await f.workflow.refresh();
      expect(
        f.workflow.state.status,
        EmployeeAttendanceStatus.refreshUnavailable,
      );
      expect(f.workflow.canCheckIn, isFalse);
      f.active.onRead = null;
      await f.workflow.refresh();
      expect(f.workflow.canCheckIn, isTrue);
    },
  );

  test('overlapping refreshes share no second read or context', () async {
    final selection = Completer<WorkSession?>();
    f.active.onRead = () => selection.future;
    final work = f.workflow.refresh();
    await pumpEventQueue();
    await f.workflow.refresh();
    await f.workflow.checkIn();
    expect(f.active.calls, hasLength(1));
    expect(f.contexts, hasLength(1));
    selection.complete(null);
    await work;
  });

  for (final afterLocation in [false, true]) {
    test(
      'auth invalidation ${afterLocation ? "after" : "before"} location suppresses handoff',
      () async {
        await f.workflow.refresh();
        if (!afterLocation) {
          f.invalidate();
          await f.workflow.checkIn();
        } else {
          final fix = Completer<LocationEvidence>();
          f.location.onAcquire = () => fix.future;
          final work = f.workflow.checkIn();
          f.invalidate();
          fix.complete(const LocationEvidence());
          await work;
        }
        expect(
          f.workflow.state.status,
          EmployeeAttendanceStatus.authorizationUnavailable,
        );
        expect(f.operations.transport.calls, isEmpty);
        expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
      },
    );
  }

  test('authorization unavailable at issuance never starts location', () async {
    f.authorized = false;
    await f.workflow.refresh();
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.authorizationUnavailable,
    );
    expect(f.location.calls, 0);
  });

  test('same-user relogin suppresses old canonical result even without notification', () async {
    final selected = Completer<WorkSession?>();
    f.active.onRead = () => selected.future;
    final work = f.workflow.refresh();
    await pumpEventQueue();
    f.invalidate(notify: false);
    selected.complete(workflowSession());
    await work;
    expect(f.workflow.state.session, isNull);
    expect(
      f.workflow.state.status,
      EmployeeAttendanceStatus.authorizationUnavailable,
    );
  });

  test(
    'changed checkout session invalidates capture without retargeting',
    () async {
      f.setActive(workflowSession());
      await f.workflow.refresh();
      final fix = Completer<LocationEvidence>();
      f.location.onAcquire = () => fix.future;
      final work = f.workflow.checkOut();
      f.setActive(workflowSession(id: journalOtherId));
      fix.complete(const LocationEvidence());
      await work;
      expect(f.operations.transport.calls, isEmpty);
      expect(f.workflow.canCheckOut, isFalse);
      expect(f.contexts.last.releaseCalls, 1);
    },
  );

  test(
    'disposing during acquisition waits for settlement and does not dispatch',
    () async {
      await f.workflow.refresh();
      final fix = Completer<LocationEvidence>();
      f.location.onAcquire = () => fix.future;
      final work = f.workflow.checkIn();
      final context = f.contexts.last;
      f.workflow.dispose();
      expect(context.releaseCalls, 0);
      fix.complete(const LocationEvidence());
      await work;
      await f.workflow.settled;
      expect(context.releaseCalls, 1);
      expect(f.operations.transport.calls, isEmpty);
    },
  );

  for (final dispose in [false, true]) {
    test(
      'late receipt retained after ${dispose ? "route disposal" : "account switch"}',
      () async {
        await f.workflow.refresh();
        final reply = Completer<AttendanceTransportReply>();
        f.operations.transport.onDispatch = (_, _) => reply.future;
        final work = f.workflow.checkIn();
        await pumpEventQueue();
        final command = f.operations.transport.calls.single.command;
        final context = f.contexts.last;
        var notifications = 0;
        f.workflow.addListener(() => notifications++);
        if (dispose) {
          f.workflow.dispose();
        } else {
          f.operations.issuer.relogin(
            asBinding: journalBinding(profile: journalOtherId),
          );
          f.changes.changed();
        }
        final afterChange = notifications;
        expect(context.releaseCalls, 0);
        reply.complete(
          AttendanceTransportReply.acknowledged(
            JournalJson.encode(journalReceipt(command)),
          ),
        );
        await work;
        expect(context.releaseCalls, 1);
        expect(f.operations.record!.phase, JournalPhase.confirmed);
        if (!dispose) expect(f.operations.canonical.calls, isEmpty);
        if (dispose) expect(notifications, afterChange);
        if (!dispose) expect(f.workflow.state.session, isNull);
      },
    );
  }
}
