import 'dart:convert';
import 'dart:io';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_controller.dart';
import 'package:chantipoint/src/attendance/file_pending_command_store.dart';
import 'package:chantipoint/src/time/business_time.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_attendance.dart';
import 'support/test_users.dart';
import 'support/legacy_writer_native_fixture.dart';

void main() {
  legacyWriterNativeFixture();
  late Directory directory;
  test(
    'new controller and file store recover a committed command after restart',
    () async {
      final repository = FakeAttendanceRepository();
      final firstStore = FilePendingCommandStore(
        directory: () async => directory,
      );
      final first = AttendanceController(repository, firstStore, testEmployee);
      repository.onSubmit = (command) async {
        repository.accept(command);
        throw const AttendanceFailure(AttendanceFailureKind.network);
      };
      await first.refresh();
      await first.checkIn();
      first.dispose();
      final reopened = AttendanceController(
        repository,
        FilePendingCommandStore(directory: () async => directory),
        testEmployee,
      );
      addTearDown(reopened.dispose);
      await reopened.refresh();
      expect(reopened.state.active!.id, 'session-1');
      expect(reopened.canCheckOut, isTrue);
      expect(repository.submitted.length, 1);
    },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'chantipoint-attendance-test-',
    );
  });
  tearDown(() async {
    final target = directory.absolute;
    if (target.parent.path != Directory.systemTemp.absolute.path ||
        !target.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('chantipoint-attendance-test-')) {
      throw StateError('Unexpected temporary test directory');
    }
    await target.delete(recursive: true);
  });

  test('a fresh store restores the original command exactly and scopes it by owner', () async {
    final store = FilePendingCommandStore(directory: () async => directory);
    final command = AttendanceCommand.factoryCheckIn(
      key: 'fictional-key-123',
      observedAt: DateTime.utc(2026, 10, 15),
    );
    await store.save('employee-a', command);
    final restored = FilePendingCommandStore(directory: () async => directory);
    expect((await restored.read('employee-a'))!.toJson(), command.toJson());
    expect(await restored.read('employee-b'), isNull);
    await restored.clear('employee-a', 'other-key');
    expect(await restored.read('employee-a'), isNotNull);
    await restored.clear('employee-a', command.key);
    expect(await restored.read('employee-a'), isNull);
  });

  test('an unresolved command cannot be overwritten by a new key', () async {
    final store = FilePendingCommandStore(directory: () async => directory);
    final original = AttendanceCommand.factoryCheckIn();
    await store.save('employee', original);
    await expectLater(
      store.save('employee', AttendanceCommand.factoryCheckIn()),
      throwsA(isA<AttendanceFailure>()),
    );
    expect((await store.read('employee'))!.key, original.key);
  });

  test('corrupt journal blocks recovery instead of discarding an uncertain command', () async {
    final store = FilePendingCommandStore(directory: () async => directory);
    await store.save('employee', AttendanceCommand.factoryCheckIn());
    final file = (await directory.list().toList()).whereType<File>().single;
    await file.writeAsString('invalid json', flush: true);
    await expectLater(
      store.read('employee'),
      throwsA(isA<AttendanceFailure>()),
    );
  });

  test(
    'journal rejects GPS fields rather than sending a modified factory payload',
    () {
      final json = jsonDecode(
        jsonEncode(AttendanceCommand.factoryCheckIn().toJson()),
      ) as Map<String, dynamic>;
      (json['payload'] as Map)['p_latitude'] = 45;
      expect(() => AttendanceCommand.fromJson(json), throwsFormatException);
    },
  );

  test('Montreal conversion uses winter and summer offsets independent of the device', () {
    expect(
      formatBusinessTime(DateTime.utc(2026, 1, 15, 15)),
      '15/01/2026 à 10:00 (heure de Montréal, UTC−05:00)',
    );
    expect(
      formatBusinessTime(DateTime.utc(2026, 7, 15, 15)),
      '15/07/2026 à 11:00 (heure de Montréal, UTC−04:00)',
    );
  });

  test('Montreal fall-back distinguishes repeated local times', () {
    expect(
      formatBusinessTime(DateTime.utc(2026, 11, 1, 5, 30)),
      '01/11/2026 à 01:30 (heure de Montréal, UTC−04:00)',
    );
    expect(
      formatBusinessTime(DateTime.utc(2026, 11, 1, 6, 30)),
      '01/11/2026 à 01:30 (heure de Montréal, UTC−05:00)',
    );
  });

  test('missing server timestamps are rejected instead of fabricated', () {
    expect(
      () => WorkSession.fromJson({
        'id': 'session',
        'location_context': 'factory',
        'lifecycle_status': 'active',
        'started_at': null,
        'ended_at': null,
      }),
      throwsFormatException,
    );
  });
}
