import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/integration/attendance_integration_guard.dart';
import 'package:chantipoint/src/attendance/integration/development_attendance_authority.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

class Evidence implements DevelopmentEnrollmentEvidence {
  bool valid = false;
  Completer<void>? wait;
  int calls = 0;
  @override
  Future<void> verify(JournalBinding binding) async {
    calls++;
    await wait?.future;
    if (!valid) throw StateError('fictional');
  }
}

void main() {
  late Evidence evidence;
  late DevelopmentAttendanceAuthority authority;
  late AttendanceOperationIdentity current;
  bool gate2 = true;
  int capabilities = 0;
  Completer<void>? capabilityWait;
  setUp(() {
    evidence = Evidence();
    current = AttendanceOperationIdentity(journalBinding(), 1);
    gate2 = true;
    capabilities = 0;
    capabilityWait = null;
    authority = DevelopmentAttendanceAuthority(
      enrollment: evidence,
      isCurrent: (id) =>
          id.generation == current.generation &&
          id.binding.matches(current.binding),
      requireCapability: (id) async {
        capabilities++;
        await capabilityWait?.future;
        if (!gate2) throw StateError('fictional unavailable gate/epoch');
      },
    );
  });
  Future<void> denied(AttendanceOperationIdentity id) async {
    await expectLater(
      authority.verify(id),
      throwsA(isA<AttendanceIntegrationFailure>()),
    );
    expect(authority.isApproved(id), false);
  }

  test('default installation denies before any capability', () async {
    expect(authority.isApproved(current), false);
    await denied(current);
    expect(capabilities, 0);
  });
  test(
    'signed enrolled fixture needs fresh capability; restart re-verifies',
    () async {
      evidence.valid = true;
      await authority.verify(current);
      expect(authority.isApproved(current), true);
      final restarted = DevelopmentAttendanceAuthority(
        enrollment: evidence,
        isCurrent: (id) => identical(id, current),
        requireCapability: (_) async {},
      );
      expect(restarted.isApproved(current), false);
      await restarted.verify(current);
      expect(restarted.isApproved(current), true);
      expect(evidence.calls, 4);
    },
  );
  for (final reason in [
    'gate 1',
    'unavailable',
    'wrong epoch',
    'rotated epoch',
  ]) {
    test('$reason denies even approved durable evidence', () async {
      evidence.valid = true;
      gate2 = false;
      await denied(current);
    });
  }
  for (final reason in [
    'corrupt',
    'interrupted',
    'replaced',
    'legacy ambiguity',
    'note uncertainty',
    'missing slot',
  ]) {
    test('$reason revokes cached approval', () async {
      evidence.valid = true;
      await authority.verify(current);
      evidence.valid = false;
      await denied(current);
    });
  }
  for (final reason in [
    'logout',
    'same-user relogin',
    'authorization loss',
    'account switch',
  ]) {
    test(
      '$reason during asynchronous enrollment cannot grant stale authority',
      () async {
        evidence.valid = true;
        evidence.wait = Completer<void>();
        final old = current;
        final pending = denied(old);
        current = AttendanceOperationIdentity(
          journalBinding(
            auth: reason == 'account switch'
                ? journalOtherId
                : current.binding.authUserId,
          ),
          2,
        );
        evidence.wait!.complete();
        await pending;
        expect(capabilities, 0);
      },
    );
  }
  test('invalidation during capability denies', () async {
    evidence.valid = true;
    capabilityWait = Completer<void>();
    final old = current;
    final pending = denied(old);
    await Future<void>.delayed(Duration.zero);
    current = AttendanceOperationIdentity(current.binding, 2);
    capabilityWait!.complete();
    await pending;
  });
  test('older concurrent failure cannot revoke newer approval', () async {
    evidence.valid = true;
    evidence.wait = Completer<void>();
    final first = expectLater(
      authority.verify(current),
      throwsA(isA<AttendanceIntegrationFailure>()),
    );
    final latch = evidence.wait!;
    evidence.wait = null;
    await authority.verify(current);
    latch.complete();
    await first;
    expect(authority.isApproved(current), true);
  });
}
