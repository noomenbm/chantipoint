import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/file_pending_command_store.dart';
import 'package:chantipoint/src/attendance/integration/legacy_writer_fence.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/attendance_auth_backend.dart';
import 'support/journal_fixtures.dart';
import 'support/session_note_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidJournalStorage.channelName);
  var retired = false;
  Object? response;
  Completer<void>? wait;
  late Directory directory;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    retired = false;
    response = null;
    wait = null;
    directory = await Directory.systemTemp.createTemp(
      'chantipoint-fictional-retirement-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requireOldWriterAllowedV1');
          expect(call.arguments, {'api_version': 1});
          await wait?.future;
          if (retired) {
            throw PlatformException(
              code: 'journal_illegal_transition',
              message: 'private fixture',
            );
          }
          return response ?? {'status': 'allowed'};
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });
  test('unretired checked adapter remains allowed', () async {
    await requireLegacyWriterAllowed();
  });
  for (final invalid in [
    {'status': 'absent'},
    {'status': 'allowed', 'extra': true},
    false,
  ]) {
    test('malformed retirement response fails closed: $invalid', () async {
      response = invalid;
      await expectLater(
        requireLegacyWriterAllowed(),
        throwsA(isA<AttendanceFailure>()),
      );
    });
  }
  test('unavailable native service fails closed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(
      requireLegacyWriterAllowed(),
      throwsA(isA<AttendanceFailure>()),
    );
  });
  test('retirement blocks saves and cleanup while preserving original pending bytes and reads', () async {
    final store = FilePendingCommandStore(directory: () async => directory);
    const owner = 'fictional-owner';
    final command = AttendanceCommand.factoryCheckIn();
    await store.save(owner, command);
    final file = (await directory.list().toList()).whereType<File>().single;
    final original = await file.readAsBytes();
    retired = true;
    await expectLater(
      store.clear(owner, command.key),
      throwsA(isA<AttendanceFailure>()),
    );
    await expectLater(
      store.save(owner, AttendanceCommand.factoryCheckIn()),
      throwsA(isA<AttendanceFailure>()),
    );
    expect(await file.readAsBytes(), original);
    expect((await store.read(owner))!.key, command.key);
    final reopened = FilePendingCommandStore(directory: () async => directory);
    expect((await reopened.read(owner))!.key, command.key);
    await expectLater(
      reopened.clear(owner, command.key),
      throwsA(isA<AttendanceFailure>()),
    );
  });
  for (final operation in ['checkin', 'checkout', 'updateNote']) {
    test(
      'retired $operation adapter makes no HTTP mutation, preserves reads',
      () async {
        final auth = AttendanceAuthBackend();
        await auth.login();
        addTearDown(auth.close);
        final requests = <http.Request>[];
        final client = SupabaseClient(
          'https://fixture.invalid',
          'fictional-key',
          httpClient: MockClient((r) async {
            requests.add(r);
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
              request: r,
            );
          }),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
        );
        addTearDown(client.dispose);
        await client.auth.setInitialSession(
          jsonEncode(auth.client.auth.currentSession!.toJson()),
        );
        final repository = SupabaseAttendanceRepository(
          client,
          auth.controller.state.user!,
        );
        retired = true;
        final future = operation == 'updateNote'
            ? repository.updateEmployeeNote(
                workSessionId: journalSessionId,
                employeeNote: 'fictional',
              )
            : repository.submit(
                operation == 'checkin'
                    ? AttendanceCommand.factoryCheckIn()
                    : AttendanceCommand.checkOut(journalSession()),
              );
        await expectLater(
          future,
          throwsA(
            isA<AttendanceFailure>().having(
              (f) => f.kind,
              'kind',
              AttendanceFailureKind.contractUnavailable,
            ),
          ),
        );
        expect(requests, isEmpty);
        expect(await repository.activeSession(), null);
        expect(requests.single.method, 'GET');
      },
    );
  }
  for (final replay in [false, true]) {
    test(
      'retired keyed standalone note replay=$replay never submits',
      () async {
        final fixture = SessionNoteFixture();
        addTearDown(fixture.close);
        final command = fixture.command();
        retired = true;
        await expectLater(
          fixture.transport.saveNote(
            fixture.context().identity,
            command,
            replayOnly: replay,
          ),
          throwsA(isA<AttendanceFailure>()),
        );
        expect(fixture.requests, isEmpty);
        expect(command.parametersJson, fixture.command().parametersJson);
      },
    );
  }
  test(
    'retirement during asynchronous check prevents the original send',
    () async {
      wait = Completer<void>();
      final pending = requireLegacyWriterAllowed();
      final rejected = expectLater(pending, throwsA(isA<AttendanceFailure>()));
      retired = true;
      wait!.complete();
      await rejected;
    },
  );
}
