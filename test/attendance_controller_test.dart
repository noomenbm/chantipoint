import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_controller.dart';
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/auth/authorized_user.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance.dart';
import 'support/test_users.dart';

void main() {
  late FakeAttendanceRepository repository;
  late MemoryCommandStore store;
  late AttendanceController controller;
  setUp(() {
    repository = FakeAttendanceRepository();
    store = MemoryCommandStore();
    controller = AttendanceController(repository, store, testEmployee);
  });
  tearDown(() => controller.dispose());

  test(
    'no active session is confirmed before offering a new check-in',
    () async {
      expect(controller.canCheckIn, isFalse);
      await controller.refresh();
      expect(controller.state.active, isNull);
      expect(controller.canCheckIn, isTrue);
    },
  );

  test(
    'factory check-in waits for acknowledgement and rejects double submissions',
    () async {
      final pending = Completer<WorkSession>();
      repository.onSubmit = (command) async {
        expect(store.commands[controller.owner]!.payload, command.payload);
        return pending.future;
      };
      await controller.refresh();
      final operation = controller.checkIn();
      await Future<void>.delayed(Duration.zero);
      await controller.checkIn();
      expect(repository.submitted.length, 1);
      expect(controller.state.status, AttendanceStatus.submitting);
      expect(controller.state.active, isNull);
      expect(controller.canCheckOut, isFalse);
      repository.active = session();
      pending.complete(repository.active);
      await operation;
      expect(controller.state.active!.startedAt, serverStart);
      expect(controller.canCheckOut, isTrue);
      expect(store.commands, isEmpty);
    },
  );

  test('checkout uses a new key and confirms server completion', () async {
    await controller.refresh();
    await controller.checkIn();
    final first = repository.submitted.single;
    final pending = Completer<WorkSession>();
    repository.onSubmit = (_) => pending.future;
    final operation = controller.checkOut();
    await Future<void>.delayed(Duration.zero);
    await controller.checkOut();
    expect(repository.submitted.length, 2);
    expect(repository.submitted.last.key, isNot(first.key));
    expect(controller.state.completed, isNull);
    repository.active = null;
    pending.complete(session(closed: true));
    await operation;
    expect(
      controller.state.completed!.endedAt,
      serverStart.add(const Duration(hours: 8)),
    );
    expect(controller.state.active, isNull);
    expect(controller.canCheckIn, isTrue);
  });

  test(
    'uncertain responses retain the exact payload and key for a retry',
    () async {
      repository.onSubmit = (_) async =>
          throw const AttendanceFailure(AttendanceFailureKind.network);
      await controller.refresh();
      await controller.checkIn();
      final original = repository.submitted.single;
      expect(controller.state.status, AttendanceStatus.pending);
      await controller.checkIn();
      expect(repository.submitted.length, 1);
      repository.readFailure = const AttendanceFailure(
        AttendanceFailureKind.network,
      );
      await controller.retryPending();
      expect(repository.submitted.length, 1);
      repository.readFailure = null;
      repository.onSubmit = null;
      await controller.retryPending();
      expect(repository.submitted.last.key, original.key);
      expect(repository.submitted.last.payload, original.payload);
      expect(controller.canCheckOut, isTrue);
    },
  );

  test(
    'restart reconciles a committed check-in with a lost response',
    () async {
      repository.onSubmit = (command) async {
        repository.accept(command);
        throw const AttendanceFailure(AttendanceFailureKind.network);
      };
      await controller.refresh();
      await controller.checkIn();
      final restored = AttendanceController(repository, store, testEmployee);
      addTearDown(restored.dispose);
      await restored.refresh();
      expect(restored.state.active!.id, 'session-1');
      expect(restored.canCheckOut, isTrue);
      expect(repository.submitted.length, 1);
      expect(store.commands, isEmpty);
    },
  );

  test('restart reconciles an acknowledged-on-server checkout', () async {
    repository.active = session();
    await controller.refresh();
    repository.onSubmit = (command) async {
      repository.accept(command);
      throw const AttendanceFailure(AttendanceFailureKind.network);
    };
    await controller.checkOut();
    final restored = AttendanceController(repository, store, testEmployee);
    addTearDown(restored.dispose);
    await restored.refresh();
    expect(restored.state.completed!.isActive, isFalse);
    expect(restored.canCheckIn, isTrue);
    expect(repository.submitted.length, 1);
  });

  test(
    'a missing reconciliation match never permits a fresh command',
    () async {
      final command = AttendanceCommand.factoryCheckIn();
      await store.save(controller.owner, command);
      await controller.refresh();
      expect(controller.state.status, AttendanceStatus.pending);
      expect(controller.canCheckIn, isFalse);
      expect(controller.canCheckOut, isFalse);
      expect(repository.submitted, isEmpty);
      expect(store.commands[controller.owner]!.key, command.key);
    },
  );

  test(
    'failed retrieval does not assert that no active session exists',
    () async {
      repository.readFailure = const AttendanceFailure(
        AttendanceFailureKind.network,
      );
      await controller.refresh();
      expect(controller.state.status, AttendanceStatus.blocked);
      expect(controller.canCheckIn, isFalse);
      expect(controller.state.message, contains('Connexion impossible'));
    },
  );

  test('storage failure prevents the RPC from being sent', () async {
    await controller.refresh();
    store.failWrites = true;
    await controller.checkIn();
    expect(repository.submitted, isEmpty);
    expect(controller.state.message, contains('appareil'));
    expect(controller.canCheckIn, isFalse);
  });

  test(
    'administrator without employee role cannot read or mutate attendance',
    () async {
      final admin = AuthorizedUser(
        profileId: 'admin',
        companyId: 'company',
        displayName: 'Admin',
        email: '',
        roles: {AuthorizedRole.administrator},
      );
      final denied = AttendanceController(repository, store, admin);
      addTearDown(denied.dispose);
      await denied.refresh();
      await denied.checkIn();
      expect(repository.reads, 0);
      expect(repository.submitted, isEmpty);
      expect(denied.state.message, contains('ne permet pas'));
    },
  );

  test('an external active session has no factory checkout action', () async {
    repository.active = session(context: 'external_worksite');
    await controller.refresh();
    await controller.checkOut();
    expect(controller.canCheckOut, isFalse);
    expect(repository.submitted, isEmpty);
  });

  test(
    'server changes before checkout are reflected without a stale command',
    () async {
      repository.active = session();
      await controller.refresh();
      repository.active = null;
      await controller.checkOut();
      expect(repository.submitted, isEmpty);
      expect(controller.state.active, isNull);
      expect(controller.state.message, contains('changé'));
    },
  );

  test(
    'explicit duplicate rejection displays the server active session',
    () async {
      await controller.refresh();
      repository.onSubmit = (_) async {
        repository.active = session(id: 'server-other');
        throw const AttendanceFailure(AttendanceFailureKind.duplicateActive);
      };
      await controller.checkIn();
      expect(controller.state.active!.id, 'server-other');
      expect(controller.state.message, contains('déjà active'));
      expect(store.commands, isEmpty);
    },
  );

  test('authorization failures request auth revalidation and do not confirm attendance', () async {
    var revalidations = 0;
    final checked = AttendanceController(
      repository,
      store,
      testEmployee,
      onAuthorizationFailure: () async {
        revalidations++;
      },
    );
    addTearDown(checked.dispose);
    await checked.refresh();
    repository.onSubmit = (_) async =>
        throw const AttendanceFailure(AttendanceFailureKind.unauthorized);
    await checked.checkIn();
    expect(revalidations, 1);
    expect(checked.state.active, isNull);
    expect(checked.canCheckIn, isFalse);
  });

  test(
    'disposal during an RPC ignores the result and keeps recovery intent',
    () async {
      final pending = Completer<WorkSession>();
      repository.onSubmit = (_) => pending.future;
      final old = AttendanceController(repository, store, testEmployee);
      await old.refresh();
      final operation = old.checkIn();
      await Future<void>.delayed(Duration.zero);
      old.dispose();
      repository.active = session();
      pending.complete(session());
      await operation;
      expect(store.commands[old.owner], isNotNull);
      expect(old.state.active, isNull);
    },
  );
}
