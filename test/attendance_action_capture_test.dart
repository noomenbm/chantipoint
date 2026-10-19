import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_action_capture.dart';
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/foreground_location.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance_operation_ports.dart';
import 'support/fake_foreground_location.dart';
import 'support/journal_fixtures.dart';

class _Clock implements AttendanceActionClock {
  int calls = 0;
  DateTime value = DateTime.utc(2026, 10, 18, 12);
  @override
  DateTime now() {
    calls++;
    return value;
  }
}

class _Keys implements AttendanceActionKeys {
  int calls = 0;
  @override
  String next() => 'fictional-action-key-${++calls}';
}

class _UnreadableContext implements AttendanceOperationContext {
  _UnreadableContext(this.releaseFails);
  final bool releaseFails;
  int releases = 0;
  @override
  AttendanceOperationIdentity get identity =>
      throw StateError('fictional unreadable identity');
  @override
  bool get isCurrent => true;
  @override
  Future<void> release() async {
    releases++;
    if (releaseFails) throw StateError('fictional release failure');
  }
}

void main() {
  late FakeLocationAcquisition location;
  late _Clock clock;
  late _Keys keys;
  late AttendanceActionCapture capture;
  late FictionalAttendanceOperations h;
  for (final releaseFails in [false, true]) {
    test(
      'unreadable context/release fails=$releaseFails never leaves capture busy',
      () async {
        final context = _UnreadableContext(releaseFails);
        final result = await capture.checkIn(context: context);
        expect(result.status, AttendanceCaptureStatus.contextUnavailable);
        expect(context.releases, 1);
        expect(capture.isBusy, isFalse);
        expect(location.calls, 0);
        expect(clock.calls, 0);
        expect(keys.calls, 0);
        await capture.close().timeout(const Duration(seconds: 1));
      },
    );
  }
  setUp(() {
    location = FakeLocationAcquisition();
    clock = _Clock();
    keys = _Keys();
    capture = AttendanceActionCapture(
      location: location,
      clock: clock,
      keys: keys,
    );
    h = FictionalAttendanceOperations();
  });
  tearDown(() {
    // Capture itself has no transport/storage API; no RPC or persistence.
    expect(h.transport.calls, isEmpty);
    expect(h.disk.writes, 0);
  });
  test(
    'button time/key/input frozen before permissions; fix time independent',
    () async {
      final platform = FakeForegroundPlatform()
        ..granted = ForegroundPermission.denied;
      final granted = Completer<ForegroundPermission>();
      platform.onRequest = () => granted.future;
      capture = AttendanceActionCapture(
        location: ForegroundLocationService(platform),
        clock: clock,
        keys: keys,
      );
      final context = h.issuer.context();
      var text = '  e\u0301 chantier 🧱  ';
      final originalText = text;
      final actionTime = clock.value;
      final future = capture.checkIn(context: context, siteDescription: text);
      expect(clock.calls, 1);
      expect(keys.calls, 1);
      text = 'changed after tap';
      clock.value = clock.value.add(const Duration(hours: 1));
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls, ['services', 'permission', 'request']);
      granted.complete(ForegroundPermission.approximate);
      final result = await future;
      final command = result.action!.command!;
      expect(result.status, AttendanceCaptureStatus.captured);
      expect(command.key, 'fictional-action-key-1');
      expect(
        command.parametersJson,
        JournalCommand.checkInV2(
          CheckInV2Request(
            idempotencyKey: 'fictional-action-key-1',
            deviceObservedAt: actionTime,
            siteDescription: originalText,
            evidence: LocationEvidence(
              latitude: platform.fix!.latitude,
              longitude: platform.fix!.longitude,
              accuracyMeters: platform.fix!.accuracyMeters,
              observedAt: platform.fix!.observedAt,
              permission: LocationPermissionState.approximate,
              servicesEnabled: true,
              result: LocationAcquisitionResult.fix,
            ),
          ),
        ).parametersJson,
      );
      expect(
        command.parameters['p_device_observed_at'],
        actionTime.toIso8601String(),
      );
      expect(
        command.parameters['p_location_observed_at'],
        platform.fix!.observedAt!.toIso8601String(),
      );
      expect(command.parameters.containsKey('p_location_context'), isFalse);
      expect(
        () => command.parameters['p_idempotency_key'] = 'changed',
        throwsUnsupportedError,
      );
      await result.action!.abandon();
      expect(context.releaseCalls, 1);
    },
  );
  for (final note in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace('  e\u0301 🧱\n texte  '),
    const CheckoutNoteIntent.replace(''),
  ]) {
    test(
      'checkout captures original session and exact note ${note.action}/${note.text?.length}',
      () async {
        final context = h.issuer.context();
        final evidence = location.evidence;
        final result = await capture.checkOut(
          context: context,
          activeSession: journalSession(),
          isSessionCurrent: (id) => id == journalSessionId,
          note: note,
        );
        final command = result.action!.command!;
        expect(
          command.parametersJson,
          JournalCommand.checkOutV2(
            CheckOutV2Request(
              workSessionId: journalSessionId,
              idempotencyKey: 'fictional-action-key-1',
              deviceObservedAt: clock.value,
              noteIntent: note,
              evidence: evidence,
            ),
          ).parametersJson,
        );
        expect(command.parameters['p_work_session_id'], journalSessionId);
        expect(command.parameters['p_employee_note'], note.text);
        expect(command.parameters['p_note_action'], note.action.name);
        expect(command.parameters['p_replay_only'], isFalse);
        final frozen = command.parametersJson;
        command.rpcParameters(replayOnly: true);
        expect(command.parametersJson, frozen);
        await result.action!.abandon();
      },
    );
  }
  for (final result in LocationAcquisitionResult.values.where(
    (e) => e != LocationAcquisitionResult.fix,
  )) {
    test('$result does not independently block an authorized action', () async {
      location.evidence = LocationEvidence(result: result);
      final captured = await capture.checkIn(context: h.issuer.context());
      expect(captured.status, AttendanceCaptureStatus.captured);
      expect(
        captured.action!.command!.parameters['p_location_result'],
        result.sqlValue,
      );
      expect(captured.action!.command!.parameters['p_latitude'], isNull);
      expect(
        captured.action!.command!.parameters['p_location_observed_at'],
        isNull,
      );
      await captured.action!.abandon();
    });
  }
  test(
    'unexpected acquisition exception becomes provider-error evidence',
    () async {
      location.onAcquire = () async =>
          throw StateError('private provider error');
      final result = await capture.checkIn(context: h.issuer.context());
      expect(result.status, AttendanceCaptureStatus.captured);
      expect(
        result.action!.command!.parameters['p_location_result'],
        'provider_error',
      );
      await result.action!.abandon();
    },
  );
  test(
    'duplicate taps do not regenerate key/time or release original attempt',
    () async {
      final fix = Completer<LocationEvidence>();
      location.onAcquire = () => fix.future;
      final context = h.issuer.context();
      final other = h.issuer.context();
      final first = capture.checkIn(context: context);
      expect(
        (await capture.checkIn(context: other)).status,
        AttendanceCaptureStatus.busy,
      );
      expect(
        (await capture.checkIn(context: context)).status,
        AttendanceCaptureStatus.contextUnavailable,
      );
      expect(other.releaseCalls, 1);
      expect(context.releaseCalls, 0);
      expect(keys.calls, 1);
      expect(clock.calls, 1);
      expect(location.calls, 1);
      fix.complete(location.evidence);
      final action = (await first).action!;
      expect(
        (await capture.checkIn(context: h.issuer.context())).status,
        AttendanceCaptureStatus.busy,
      );
      expect(keys.calls, 1);
      await action.abandon();
      expect(capture.isBusy, isFalse);
      final next = await capture.checkIn(context: h.issuer.context());
      expect(next.action!.command!.key, 'fictional-action-key-2');
      await next.action!.abandon();
    },
  );
  for (final change in [
    'logout',
    'same-user relogin',
    'account switch',
    'binding change',
    'session change',
  ]) {
    test('$change during acquisition abandons original, no retarget', () async {
      final fix = Completer<LocationEvidence>();
      location.onAcquire = () => fix.future;
      final context = h.issuer.context();
      var sessionId = journalSessionId;
      final future = capture.checkOut(
        context: context,
        activeSession: journalSession(),
        isSessionCurrent: (id) => id == sessionId,
      );
      switch (change) {
        case 'logout':
          context.callerDisposed = true;
        case 'same-user relogin':
          h.issuer.relogin();
        case 'account switch':
          h.issuer.relogin(asBinding: journalBinding(auth: journalOtherId));
        case 'binding change':
          h.issuer.binding = journalBinding(
            environment: 'different-deployment',
          );
        case 'session change':
          sessionId = journalOtherId;
      }
      expect(context.releaseCalls, 0);
      fix.complete(location.evidence);
      final result = await future;
      expect(result.status, AttendanceCaptureStatus.invalidated);
      expect(result.action, isNull);
      expect(context.releaseCalls, 1);
      expect(keys.calls, 1);
      expect(capture.isBusy, isFalse);
    });
  }
  test('stale context stopped before clock, key or location', () async {
    final context = h.issuer.context();
    h.issuer.relogin();
    expect(
      (await capture.checkIn(context: context)).status,
      AttendanceCaptureStatus.invalidated,
    );
    expect(clock.calls, 0);
    expect(keys.calls, 0);
    expect(location.calls, 0);
    expect(context.releaseCalls, 1);
  });
  test('result accessed after invalidation cannot hand off; original released once', () async {
    final context = h.issuer.context();
    final result = await capture.checkIn(context: context);
    final original = result.action!;
    h.issuer.relogin();
    expect(result.status, AttendanceCaptureStatus.invalidated);
    expect(result.action, isNull);
    expect(original.command, isNull);
    expect(original.handoff(), isNull);
    await original.abandon();
    await original.abandon();
    expect(context.releaseCalls, 1);
    expect(
      (await capture.checkIn(context: context)).status,
      AttendanceCaptureStatus.contextUnavailable,
    );
  });

  test(
    'stale result can abandon without first obtaining a current action',
    () async {
      final context = h.issuer.context();
      final result = await capture.checkIn(context: context);
      h.issuer.relogin();
      expect(result.action, isNull);
      await result.abandon();
      await result.abandon();
      expect(context.releaseCalls, 1);
      expect(capture.isBusy, isFalse);
      final next = await capture.checkIn(context: h.issuer.context());
      expect(next.status, AttendanceCaptureStatus.captured);
      await next.abandon();
    },
  );

  test(
    'result-level abandonment cannot release a handed-off context',
    () async {
      final context = h.issuer.context();
      final result = await capture.checkIn(context: context);
      final submitted = result.action!.handoff()!;
      h.issuer.relogin();
      await result.abandon();
      expect(capture.isBusy, isTrue);
      expect(context.releaseCalls, 0);
      await submitted.context.release();
      expect(context.releaseCalls, 1);
      expect(capture.isBusy, isFalse);
    },
  );
  test(
    'handoff is single-use; close/disposal waits for coordinator release',
    () async {
      final context = h.issuer.context();
      final action = (await capture.checkIn(context: context)).action!;
      final submitted = action.handoff()!;
      expect(action.handoff(), isNull);
      expect(submitted.context.identity.binding.matches(h.binding), isTrue);
      expect(
        submitted.context.identity.generation,
        context.identity.generation,
      );
      var closed = false;
      final closing = capture.close().then((_) => closed = true);
      await action.abandon();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(capture.isBusy, isTrue);
      expect(context.releaseCalls, 0);
      h.issuer.relogin();
      expect(submitted.context.isCurrent, isFalse);
      await submitted.context.release();
      await submitted.context.release();
      await closing;
      expect(closed, isTrue);
      expect(context.releaseCalls, 1);
      expect(capture.isBusy, isFalse);
    },
  );
  test('close during acquisition waits for native settlement, rejects late ready result', () async {
    final fix = Completer<LocationEvidence>();
    location.onAcquire = () => fix.future;
    final context = h.issuer.context();
    final pending = capture.checkIn(context: context);
    var closed = false;
    final closing = capture.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(context.releaseCalls, 0);
    fix.complete(location.evidence);
    expect((await pending).status, AttendanceCaptureStatus.invalidated);
    await closing;
    expect(context.releaseCalls, 1);
    final rejected = h.issuer.context();
    expect(
      (await capture.checkIn(context: rejected)).status,
      AttendanceCaptureStatus.closed,
    );
    expect(rejected.releaseCalls, 1);
  });
  test(
    'handed context stays owned through real isolated coordinator settlement',
    () async {
      final context = h.issuer.context();
      final action = (await capture.checkIn(context: context)).action!;
      final submitted = action.handoff()!;
      // Exercise a NO-DISPATCH coordinator path; capture's ready command is not sent.
      final result = await h.coordinator.refresh(submitted.context);
      expect(result.problem, AttendanceOperationProblem.recoveryRequired);
      expect(context.releaseCalls, 1);
      expect(capture.isBusy, isFalse);
      await capture.close();
    },
  );
  for (final problem in ['description', 'note', 'inactive', 'session id']) {
    test(
      'invalid $problem rejected before location, releases context',
      () async {
        final context = h.issuer.context();
        final result = problem == 'description'
            ? await capture.checkIn(
                context: context,
                siteDescription: 'x' * 501,
              )
            : await capture.checkOut(
                context: context,
                activeSession: WorkSession(
                  id: problem == 'session id' ? 'invalid' : journalSessionId,
                  locationContext: 'factory',
                  lifecycleStatus: problem == 'inactive' ? 'closed' : 'active',
                  startedAt: journalTime,
                ),
                isSessionCurrent: (_) => true,
                note: problem == 'note'
                    ? CheckoutNoteIntent.replace('x' * 1001)
                    : const CheckoutNoteIntent.preserve(),
              );
        expect(result.action, isNull);
        expect(location.calls, 0);
        expect(context.releaseCalls, 1);
      },
    );
  }
  test('default secure generator is URL-safe and fresh; UTC system clock', () {
    final generator = SecureAttendanceActionKeys();
    final values = List.generate(100, (_) => generator.next());
    expect(values.toSet().length, 100);
    expect(
      values.every((value) => RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(value)),
      isTrue,
    );
    expect(const SystemAttendanceActionClock().now().isUtc, isTrue);
  });
  test(
    'explicit mock-coordinator handoff retains late receipt before release',
    () async {
      final submitted = FictionalAttendanceOperations();
      final context = submitted.issuer.context();
      final action = (await capture.checkIn(context: context)).action!;
      final handoff = action.handoff()!;
      final entered = Completer<void>();
      final reply = Completer<AttendanceTransportReply>();
      submitted.transport.onDispatch = (_, _) {
        entered.complete();
        return reply.future;
      };
      final operation = submitted.coordinator.submit(
        handoff.context,
        handoff.command,
      );
      await entered.future;
      submitted.issuer.relogin();
      var closed = false;
      final closing = capture.close().then((_) => closed = true);
      await action.abandon();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(context.releaseCalls, 0);
      expect(capture.isBusy, isTrue);
      reply.complete(
        AttendanceTransportReply.acknowledged(
          JournalJson.encode(journalReceipt(handoff.command)),
        ),
      );
      expect((await operation).outcome, AttendanceOperationOutcome.invalidated);
      await closing;
      expect(context.releaseCalls, 1);
      expect(capture.isBusy, isFalse);
      expect(submitted.record!.phase, JournalPhase.confirmed);
      expect(
        submitted.record!.command!.parametersJson,
        handoff.command.parametersJson,
      );
      expect(submitted.canonical.calls, isEmpty);
    },
  );
}
