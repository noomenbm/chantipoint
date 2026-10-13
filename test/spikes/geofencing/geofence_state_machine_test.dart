import 'package:chantipoint/spikes/geofencing/geofence_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const machine = GeofenceSpikeStateMachine();
  final startAt = DateTime.utc(2026, 10, 12, 12);

  GeofenceSpikeSnapshot started() {
    return machine
        .start(
          sessionId: 'session-a',
          geofenceId: 'geofence-a',
          nowUtc: startAt,
        )
        .snapshot;
  }

  GeofenceSpikeEvent event({
    required String id,
    required GeofenceSpikeEventType type,
    DateTime? callbackAt,
    String sessionId = 'session-a',
    String geofenceId = 'geofence-a',
  }) {
    return GeofenceSpikeEvent(
      id: id,
      sessionId: sessionId,
      geofenceId: geofenceId,
      type: type,
      callbackReceivedAtUtc: callbackAt,
    );
  }

  test('normal start and stop', () {
    final start = machine.start(
      sessionId: 'session-a',
      geofenceId: 'geofence-a',
      nowUtc: startAt,
    );

    expect(start.accepted, isTrue);
    expect(start.snapshot.state, GeofenceSpikeState.monitoring);
    expect(start.snapshot.hasActiveSession, isTrue);

    final stop = machine.stop(
      start.snapshot,
      nowUtc: startAt.add(const Duration(minutes: 1)),
    );

    expect(stop.accepted, isTrue);
    expect(stop.snapshot.state, GeofenceSpikeState.stopped);
    expect(stop.snapshot.hasActiveSession, isFalse);
  });

  test('exit starts grace period', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final result = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    expect(result.accepted, isTrue);
    expect(result.snapshot.state, GeofenceSpikeState.gracePeriod);
    expect(result.snapshot.graceStartedAtUtc, exitAt);
    expect(
      result.snapshot.graceExpiresAtUtc,
      exitAt.add(const Duration(minutes: 10)),
    );
  });

  test('return before expiration cancels automatic checkout candidate', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final returnAt = exitAt.add(const Duration(minutes: 9, seconds: 59));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    final result = machine.applyEvent(
      afterExit.snapshot,
      event(
        id: 'enter-1',
        type: GeofenceSpikeEventType.enter,
        callbackAt: returnAt,
      ),
      nowUtc: returnAt,
    );

    expect(result.accepted, isTrue);
    expect(result.snapshot.state, GeofenceSpikeState.monitoring);
    expect(result.snapshot.graceStartedAtUtc, isNull);
    expect(result.snapshot.graceExpiresAtUtc, isNull);
    expect(result.snapshot.records.last.type, 'return');
    expect(result.snapshot.records.last.occurredAtUtc, returnAt);
  });

  test('return during grace resumes monitoring and allows a new exit', () {
    final firstExitAt = startAt.add(const Duration(minutes: 2));
    final returnAt = firstExitAt.add(const Duration(minutes: 3));
    final secondExitAt = returnAt.add(const Duration(minutes: 1));
    final afterFirstExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: firstExitAt,
      ),
      nowUtc: firstExitAt,
    );
    final afterReturn = machine.applyEvent(
      afterFirstExit.snapshot,
      event(
        id: 'enter-1',
        type: GeofenceSpikeEventType.enter,
        callbackAt: returnAt,
      ),
      nowUtc: returnAt,
    );

    final afterSecondExit = machine.applyEvent(
      afterReturn.snapshot,
      event(
        id: 'exit-2',
        type: GeofenceSpikeEventType.exit,
        callbackAt: secondExitAt,
      ),
      nowUtc: secondExitAt,
    );

    expect(afterFirstExit.snapshot.state, GeofenceSpikeState.gracePeriod);
    expect(afterReturn.accepted, isTrue);
    expect(afterReturn.snapshot.state, GeofenceSpikeState.monitoring);
    expect(afterSecondExit.accepted, isTrue);
    expect(afterSecondExit.snapshot.state, GeofenceSpikeState.gracePeriod);
    expect(afterSecondExit.snapshot.graceStartedAtUtc, secondExitAt);
    expect(
      afterSecondExit.snapshot.graceExpiresAtUtc,
      secondExitAt.add(const Duration(minutes: 10)),
    );
    expect(
      afterSecondExit.snapshot.records.map((record) => record.type),
      containsAllInOrder(<String>['start', 'exit', 'return', 'exit']),
    );
  });

  test('persistent exit becomes automatic checkout candidate', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    final result = machine.evaluate(
      afterExit.snapshot,
      exitAt.add(const Duration(minutes: 10)),
    );

    expect(result.accepted, isTrue);
    expect(
      result.snapshot.state,
      GeofenceSpikeState.automaticCheckoutCandidate,
    );
  });

  test('duplicate exit events do not restart grace period', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    final duplicate = machine.applyEvent(
      afterExit.snapshot,
      event(
        id: 'exit-2',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt.add(const Duration(minutes: 1)),
      ),
      nowUtc: exitAt.add(const Duration(minutes: 1)),
    );

    expect(duplicate.accepted, isFalse);
    expect(duplicate.snapshot.state, GeofenceSpikeState.gracePeriod);
    expect(duplicate.snapshot.graceStartedAtUtc, exitAt);
  });

  test('duplicate return events are ignored safely', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final returnAt = exitAt.add(const Duration(minutes: 2));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );
    final afterReturn = machine.applyEvent(
      afterExit.snapshot,
      event(
        id: 'enter-1',
        type: GeofenceSpikeEventType.enter,
        callbackAt: returnAt,
      ),
      nowUtc: returnAt,
    );

    final duplicate = machine.applyEvent(
      afterReturn.snapshot,
      event(
        id: 'enter-2',
        type: GeofenceSpikeEventType.enter,
        callbackAt: returnAt.add(const Duration(seconds: 10)),
      ),
      nowUtc: returnAt.add(const Duration(seconds: 10)),
    );

    expect(duplicate.accepted, isFalse);
    expect(duplicate.snapshot.state, GeofenceSpikeState.monitoring);
  });

  test('out-of-order events are ignored', () {
    final exitAt = startAt.add(const Duration(minutes: 5));
    final oldReturnAt = startAt.add(const Duration(minutes: 4));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    final result = machine.applyEvent(
      afterExit.snapshot,
      event(
        id: 'enter-old',
        type: GeofenceSpikeEventType.enter,
        callbackAt: oldReturnAt,
      ),
      nowUtc: oldReturnAt,
    );

    expect(result.accepted, isFalse);
    expect(result.snapshot.state, GeofenceSpikeState.gracePeriod);
  });

  test('missing timestamps are ignored as insufficient evidence', () {
    final result = machine.applyEvent(
      started(),
      event(id: 'exit-missing-time', type: GeofenceSpikeEventType.exit),
    );

    expect(result.accepted, isFalse);
    expect(result.snapshot.state, GeofenceSpikeState.monitoring);
  });

  test('permission or monitoring failure becomes monitoring unavailable', () {
    final result = machine.monitoringUnavailable(
      started(),
      nowUtc: startAt.add(const Duration(minutes: 1)),
      reason: 'Location permission revoked.',
    );

    expect(result.accepted, isTrue);
    expect(result.snapshot.state, GeofenceSpikeState.monitoringUnavailable);
  });

  test('stale events from an old session are ignored', () {
    final result = machine.applyEvent(
      started(),
      event(
        id: 'old-exit',
        type: GeofenceSpikeEventType.exit,
        callbackAt: startAt.add(const Duration(minutes: 1)),
        sessionId: 'old-session',
        geofenceId: 'old-geofence',
      ),
    );

    expect(result.accepted, isFalse);
    expect(result.snapshot.state, GeofenceSpikeState.monitoring);
  });

  test('grace-period boundary flags candidate at exactly ten minutes', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    final result = machine.evaluate(
      afterExit.snapshot,
      exitAt.add(const Duration(minutes: 10)),
    );

    expect(result.accepted, isTrue);
    expect(
      result.snapshot.state,
      GeofenceSpikeState.automaticCheckoutCandidate,
    );
  });

  test('return at the exact boundary does not cancel the candidate', () {
    final exitAt = startAt.add(const Duration(minutes: 2));
    final boundary = exitAt.add(const Duration(minutes: 10));
    final afterExit = machine.applyEvent(
      started(),
      event(
        id: 'exit-1',
        type: GeofenceSpikeEventType.exit,
        callbackAt: exitAt,
      ),
      nowUtc: exitAt,
    );

    final result = machine.applyEvent(
      afterExit.snapshot,
      event(
        id: 'enter-boundary',
        type: GeofenceSpikeEventType.enter,
        callbackAt: boundary,
      ),
      nowUtc: boundary,
    );

    expect(result.accepted, isFalse);
    expect(
      result.snapshot.state,
      GeofenceSpikeState.automaticCheckoutCandidate,
    );
  });
}
