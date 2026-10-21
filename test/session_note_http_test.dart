import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/journal_fixtures.dart';
import 'support/session_note_fixture.dart';

void main() {
  late SessionNoteFixture f;
  setUp(() => f = SessionNoteFixture());
  tearDown(() => f.close());
  test(
    'exact original JSON; public schema; pinned token; no redirects or retries',
    () async {
      final source = f.command();
      final raw = ' \n${source.parametersJson}\n';
      final command = SessionNoteCommand.fromJson(source.identity.binding, {
        'captured_generation': 1,
        'parameters_json': raw,
      });
      final receipt = await f.transport.saveNote(
        command.identity,
        command,
        replayOnly: false,
      );
      expect(receipt.json, f.server[command.key]!.receipt);
      final request = f.requests.single;
      expect(request.body, raw);
      expect(request.url.path, '/rest/v1/rpc/save_employee_note');
      expect(request.headers['Content-Profile'], 'public');
      expect(request.headers['Authorization'], 'Bearer fictional-pinned-token');
      expect(request.followRedirects, false);
      expect(request.maxRedirects, 0);
    },
  );
  test(
    'recovery changes replay flag only and permits explicit fresh generation',
    () async {
      final command = f.command();
      f.operations.issuer.relogin();
      final identity = f.context().identity;
      final receipt = await f.transport.saveNote(
        identity,
        command,
        replayOnly: true,
      );
      expect(receipt.reason, 'replay_fenced');
      expect(jsonDecode(f.requests.single.body), {
        ...command.parameters,
        'p_replay_only': true,
      });
      expect(command.parameters['p_replay_only'], false);
      await expectLater(
        f.transport.saveNote(identity, command, replayOnly: false),
        throwsA(isA<AttendanceHttpFailure>()),
      );
      expect(f.requests, hasLength(1));
    },
  );
  for (final status in [301, 302, 307, 401, 403, 404, 409, 429, 500]) {
    test(
      'HTTP $status is uncertainty, never terminal non-application; exactly one attempt',
      () async {
        f.response = (_, _) => http.Response(
          'private fixture body',
          status,
          headers: {'location': 'https://other.invalid'},
        );
        await expectLater(
          f.transport.saveNote(
            f.command().identity,
            f.command(),
            replayOnly: true,
          ),
          throwsA(
            isA<AttendanceHttpFailure>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains('private fixture')),
            ),
          ),
        );
        expect(f.requests, hasLength(1));
      },
    );
  }
  for (final binding in [
    journalBinding(environment: 'other-deployment'),
    journalBinding(url: 'https://other.invalid'),
    journalBinding(auth: journalOtherId),
    journalBinding(company: journalOtherId),
    journalBinding(profile: journalOtherId),
  ]) {
    test('acquired scope must match every captured binding field', () async {
      f.authority.onAcquire = (_) async => f.authority.scope(
        asIdentity: AttendanceOperationIdentity(binding, 1),
      );
      await expectLater(
        f.transport.saveNote(
          f.command().identity,
          f.command(),
          replayOnly: false,
        ),
        throwsA(isA<AttendanceHttpFailure>()),
      );
      expect(f.requests, isEmpty);
    });
  }
  test(
    'logout initiation during delayed authority acquisition prevents send',
    () async {
      final acquired = Completer<void>(), proceed = Completer<void>();
      f.authority.onAcquire = (identity) async {
        acquired.complete();
        await proceed.future;
        return f.authority.scope(asIdentity: identity);
      };
      final command = f.command();
      final work = f.transport.saveNote(
        command.identity,
        command,
        replayOnly: false,
      );
      final expected = expectLater(work, throwsA(isA<AttendanceHttpFailure>()));
      await acquired.future;
      f.operations.issuer.relogin();
      proceed.complete();
      await expected;
      expect(f.requests, isEmpty);
    },
  );
  for (final failure in [
    'invalidUtf8',
    'bom',
    'oversize',
    'streamError',
    'truncated',
    'extra',
    'duplicate',
    'notFound',
  ]) {
    test('strict bounded response and no weak receipt for $failure', () async {
      final command = f.command();
      var raw = jsonEncode(noteReceiptJson(command));
      if (failure == 'truncated') raw = raw.substring(0, raw.length - 1);
      if (failure == 'extra') {
        raw = jsonEncode({
          ...noteReceiptJson(command),
          'employee_note': 'must not be in receipt',
        });
      }
      if (failure == 'duplicate') {
        raw = raw.replaceFirst('{', '{"outcome":"applied",');
      }
      if (failure == 'notFound') {
        raw = '{"contract_version":2,"status":"not_found"}';
      }
      final client = MockClient.streaming((_, _) async {
        Stream<List<int>> stream = Stream.value(utf8.encode(raw));
        if (failure == 'invalidUtf8') stream = Stream.value([0xff]);
        if (failure == 'bom') {
          stream = Stream.value([0xef, 0xbb, 0xbf, ...utf8.encode(raw)]);
        }
        if (failure == 'oversize') {
          stream = Stream.value(List.filled(17000, 32));
        }
        if (failure == 'streamError') {
          stream = Stream.error(StateError('private fixture stream error'));
        }
        return http.StreamedResponse(stream, 200);
      });
      addTearDown(client.close);
      final transport = SupabaseAttendanceOperationTransport(
        authority: f.authority,
        client: client,
      );
      await expectLater(
        transport.saveNote(command.identity, command, replayOnly: true),
        throwsA(isA<AttendanceHttpFailure>()),
      );
    });
  }
  test('complete stream settles after auth invalidation; original raw receipt retained', () async {
    final command = f.command();
    final raw = ' \n${jsonEncode(noteReceiptJson(command))}\n';
    final stream = StreamController<List<int>>();
    final client = MockClient.streaming(
      (_, _) async => http.StreamedResponse(stream.stream, 200),
    );
    addTearDown(client.close);
    final transport = SupabaseAttendanceOperationTransport(
      authority: f.authority,
      client: client,
    );
    var settled = false;
    final work = transport
        .saveNote(command.identity, command, replayOnly: false)
        .whenComplete(() => settled = true);
    await Future<void>.delayed(Duration.zero);
    stream.add(utf8.encode(raw));
    await Future<void>.delayed(Duration.zero);
    expect(settled, false);
    f.operations.issuer.relogin();
    await stream.close();
    expect((await work).json, raw);
  });
}
