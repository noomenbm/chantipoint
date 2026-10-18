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
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_attendance_operation_ports.dart';
import 'support/fake_attendance_request_authority.dart';
import 'support/journal_fixtures.dart';

void main() {
  late FictionalAttendanceOperations h;
  late FictionalRequestAuthority authority;
  late AttendanceOperationIdentity identity;
  late MockClient client;
  late SupabaseAttendanceOperationTransport adapter;
  late Future<http.StreamedResponse> Function(http.BaseRequest, List<int>)
  handler;
  late List<({http.BaseRequest request, List<int> body})> requests;

  http.StreamedResponse response(String text, {int status = 200}) =>
      http.StreamedResponse(Stream.value(utf8.encode(text)), status);
  Map<String, dynamic> session({bool closed = false}) => {
    'id': journalSessionId,
    'company_id': h.binding.companyId,
    'employee_profile_id': h.binding.profileId,
    'location_context': 'factory',
    'lifecycle_status': closed ? 'closed_manual' : 'active',
    'started_at': '2026-10-17T10:00:00-04:00',
    'ended_at': closed ? '2026-10-17T18:00:00-04:00' : null,
    'site_description': 'fictional site',
    'employee_note': 'note fictive',
    'review_status': 'normal',
  };
  Future<AttendanceTransportReply> dispatch({
    JournalCommand? command,
    bool replay = false,
  }) => adapter.dispatch(
    identity,
    command ?? journalCommand(),
    replayOnly: replay,
  );
  Future<WorkSession?> read() =>
      adapter.readSession(identity, journalSessionId);
  AttendanceOperationCoordinator coordinator() =>
      AttendanceOperationCoordinator(
        storage: h.storage,
        transport: adapter,
        canonical: adapter,
      );

  setUp(() {
    h = FictionalAttendanceOperations();
    authority = FictionalRequestAuthority(h.issuer);
    identity = AttendanceOperationIdentity(h.binding, h.issuer.generation);
    requests = [];
    handler = (_, _) async =>
        response(JournalJson.encode(journalReceipt(journalCommand())));
    client = MockClient.streaming((request, stream) async {
      final body = await stream.toBytes();
      requests.add((request: request, body: body));
      return handler(request, body);
    });
    adapter = SupabaseAttendanceOperationTransport(
      authority: authority,
      client: client,
    );
  });
  tearDown(() => client.close());

  test('raw acknowledgement, offsets, fractional seconds and JSON spelling survive', () async {
    final command = journalCommand();
    final row = journalReceipt(command)
      ..['started_at'] = '2026-10-17T10:00:00.123456-04:00';
    final raw =
        ' \n${jsonEncode(row).replaceFirst('created', r'cre\u0061ted')}\n ';
    final bytes = utf8.encode(raw);
    handler = (_, _) async => http.StreamedResponse(
      Stream.fromIterable([bytes.sublist(0, 11), bytes.sublist(11)]),
      200,
    );
    final reply = await dispatch(command: command);
    expect(reply.dataJson, raw);
    final confirmation = JournalConfirmation(
      source: JournalConfirmationSource.rpcV2,
      dataJson: reply.dataJson!,
      command: command,
    );
    expect(confirmation.dataJson, raw);
    expect(confirmation.data['started_at'], row['started_at']);
    expect(requests.single.request.url.path, '/rest/v1/rpc/check_in_v2');
    expect(
      requests.single.request.headers['Authorization'],
      'Bearer fictional-pinned-token',
    );
    expect(
      requests.single.request.headers['apikey'],
      'fictional-publishable-key',
    );
  });

  for (final note in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace(''),
    const CheckoutNoteIntent.replace('  e\u0301 🚧\nfin  '),
  ]) {
    for (final replay in [false, true]) {
      test(
        'checkout ${note.action}/${note.text} replay=$replay preserves frozen evidence/note',
        () async {
          final base = journalCommand(
            operation: AttendanceCommandKind.checkOut,
            note: note,
          );
          final frozen =
              ' \n${base.parametersJson.replaceFirst('12.345', '1.2345e1').replaceFirst('2026-10-17T14:30:00.000Z', '2026-10-17T10:30:00-04:00')} ';
          final command = JournalCommand.frozen(
            protocol: base.protocol,
            operation: base.operation,
            parametersJson: frozen,
          );
          handler = (_, _) async => response(
            JournalJson.encode(journalReceipt(command, replay: replay)),
          );
          final reply = await dispatch(command: command, replay: replay);
          expect(reply.dataJson, isNotNull);
          expect(requests.single.request.url.path, '/rest/v1/rpc/check_out_v2');
          expect(requests.single.request.method, 'POST');
          final outgoing = utf8.decode(requests.single.body);
          if (!replay) expect(outgoing, frozen);
          expect(
            JournalJson.decodeText(outgoing),
            command.rpcParameters(replayOnly: replay),
          );
          expect(command.parametersJson, frozen);
          expect(command.parameters['p_replay_only'], false);
        },
      );
    }
  }
  for (final replay in [false, true]) {
    test(
      'check-in replay=$replay sends original complete payload and key',
      () async {
        final command = journalCommand();
        final original = command.toJson();
        await dispatch(command: command, replay: replay);
        expect(
          JournalJson.decode(requests.single.body),
          command.rpcParameters(replayOnly: replay),
        );
        if (!replay) {
          expect(utf8.decode(requests.single.body), command.parametersJson);
        }
        expect(command.toJson(), original);
      },
    );
  }

  for (final raw in [
    '{"contract_version":2,"status":"not_found"}',
    ' \n{"status":"not_found", "contract_version":2}\t',
  ]) {
    test(
      'exact semantic replay miss accepted with original formatting $raw',
      () async {
        handler = (_, _) async => response(raw);
        expect((await dispatch(replay: true)).dataJson, isNull);
        expect((await dispatch()).dataJson, raw);
        expect(requests.length, 2);
      },
    );
  }
  for (final raw in [
    '{"contract_version":2,"status":"not_found","extra":null}',
    '{"contract_version":2,"status":"not_found","status":"not_found"}',
    r'{"contract_version":2,"status":"not_found","st\u0061tus":"not_found"}',
    '{"contract_version":2.0,"status":"not_found"}',
    '{"contract_version":"2","status":"not_found"}',
    '{"contract_version":2,"status":"not_found"',
    '[{"contract_version":2,"status":"not_found"}]',
    'null',
    '<html>fictional private proxy error</html>',
    '',
  ]) {
    test(
      'malformed/extra/duplicate/non-object miss is never a sentinel: $raw',
      () async {
        handler = (_, _) async => response(raw);
        expect((await dispatch(replay: true)).dataJson, raw);
      },
    );
  }
  for (final status in [
    301,
    302,
    307,
    308,
    400,
    401,
    403,
    404,
    429,
    500,
    503,
  ]) {
    test(
      'HTTP $status is one attempt, never a miss or followed redirect',
      () async {
        handler = (_, _) async => http.StreamedResponse(
          Stream.value(
            utf8.encode('{"contract_version":2,"status":"not_found"}'),
          ),
          status,
          headers: {'location': 'https://other-fictional.invalid'},
        );
        await expectLater(
          dispatch(replay: true),
          throwsA(failure(AttendanceHttpFailureKind.http)),
        );
        expect(requests.length, 1);
        expect(requests.single.request.followRedirects, false);
        expect(requests.single.request.maxRedirects, 0);
      },
    );
  }

  test('send exception is sanitized with no implicit retry', () async {
    handler = (_, _) async => throw http.ClientException(
      'fictional-token private body',
      Uri.parse('https://private.invalid'),
    );
    await expectLater(
      dispatch(),
      throwsA(failure(AttendanceHttpFailureKind.network)),
    );
    expect(requests.length, 1);
  });
  test(
    'stream errors are consumed until termination before safe failure',
    () async {
      final body = StreamController<List<int>>();
      final entered = Completer<void>();
      handler = (_, _) async {
        entered.complete();
        return http.StreamedResponse(body.stream, 200);
      };
      var settled = false;
      final result = dispatch().whenComplete(() => settled = true);
      final expected = expectLater(
        result,
        throwsA(failure(AttendanceHttpFailureKind.network)),
      );
      await entered.future;
      body.add(utf8.encode('{"partial":'));
      body.addError(StateError('private stream error'));
      await turn();
      expect(settled, false);
      body.add(utf8.encode('null}'));
      await body.close();
      await expected;
      expect(settled, true);
      expect(requests.length, 1);
    },
  );
  for (final announced in [false, true]) {
    test(
      'oversize announced=$announced drains without early settlement',
      () async {
        final body = StreamController<List<int>>();
        final entered = Completer<void>();
        handler = (_, _) async {
          entered.complete();
          return http.StreamedResponse(
            body.stream,
            200,
            contentLength: announced
                ? SupabaseAttendanceOperationTransport.responseLimit + 1
                : null,
          );
        };
        var settled = false;
        final expected = expectLater(
          dispatch().whenComplete(() => settled = true),
          throwsA(failure(AttendanceHttpFailureKind.responseTooLarge)),
        );
        await entered.future;
        body.add(
          List.filled(SupabaseAttendanceOperationTransport.responseLimit, 0x20),
        );
        body.add([0x20]);
        await turn();
        expect(settled, false);
        body.add([0x20]);
        await body.close();
        await expected;
        expect(requests.length, 1);
      },
    );
  }
  test(
    'HTTP error body is drained too, without surfacing private text',
    () async {
      final body = StreamController<List<int>>();
      final entered = Completer<void>();
      handler = (_, _) async {
        entered.complete();
        return http.StreamedResponse(body.stream, 403);
      };
      var settled = false;
      final expected = expectLater(
        dispatch().whenComplete(() => settled = true),
        throwsA(failure(AttendanceHttpFailureKind.http)),
      );
      await entered.future;
      body.add(utf8.encode('private body'));
      await turn();
      expect(settled, false);
      await body.close();
      await expected;
    },
  );
  test(
    'strict UTF-8 rejects invalid bytes after consuming the stream',
    () async {
      handler = (_, _) async =>
          http.StreamedResponse(Stream.value([0xc3, 0x28]), 200);
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.malformedResponse)),
      );
    },
  );
  test('UTF-8 characters split across chunks retain exact JSON', () async {
    final raw = ' {"fictional":"é🚧"} ';
    handler = (_, _) async => http.StreamedResponse(
      Stream.fromIterable(utf8.encode(raw).map((b) => [b])),
      200,
    );
    expect((await dispatch()).dataJson, raw);
  });
  test(
    'declared content length mismatch cannot acknowledge even valid JSON',
    () async {
      handler = (_, _) async => http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        200,
        contentLength: 3,
      );
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.malformedResponse)),
      );
    },
  );
  test('exact response limit is accepted, next byte is rejected', () async {
    final text = ' ' * SupabaseAttendanceOperationTransport.responseLimit;
    handler = (_, _) async => response(text);
    expect((await dispatch()).dataJson, text);
    handler = (_, _) async => response('$text ');
    await expectLater(
      dispatch(),
      throwsA(failure(AttendanceHttpFailureKind.responseTooLarge)),
    );
  });

  for (final canonical in [false, true]) {
    for (final change in ['logout', 'same-user-relogin', 'account-switch']) {
      test(
        '$change during delayed acquisition blocks canonical=$canonical',
        () async {
          final gate = Completer<void>();
          final entered = Completer<void>();
          authority.onAcquire = (_) async {
            final scope = authority.scope();
            entered.complete();
            await gate.future;
            return scope;
          };
          final expected = expectLater(
            canonical ? read() : dispatch(),
            throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
          );
          await entered.future;
          if (change == 'logout') {
            authority.authorized = false;
          } else {
            h.issuer.relogin(
              asBinding: change == 'account-switch'
                  ? journalBinding(auth: journalOtherId)
                  : null,
            );
          }
          gate.complete();
          await expected;
          expect(requests, isEmpty);
          expect(authority.acquisitions, 1);
        },
      );
    }
  }
  test(
    'already invalid generation does not acquire credentials or send',
    () async {
      h.issuer.relogin();
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
      );
      expect(authority.acquisitions, 0);
      expect(requests, isEmpty);
    },
  );
  test(
    'currency is rechecked immediately before send, not only after acquisition',
    () async {
      var observations = 0;
      authority.onAcquire = (_) async =>
          authority.scope(current: () => ++observations == 1);
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
      );
      expect(observations, 2);
      expect(requests, isEmpty);
    },
  );
  for (final field in [
    'environment',
    'url',
    'auth',
    'company',
    'profile',
    'generation',
    'endpoint',
  ]) {
    test('wrong $field scope cannot route or authenticate a request', () async {
      final binding = journalBinding(
        environment: field == 'environment'
            ? 'other-environment'
            : h.binding.environmentId,
        url: field == 'url' ? 'https://other.invalid' : h.binding.baseUrl,
        auth: field == 'auth' ? journalOtherId : h.binding.authUserId,
        company: field == 'company' ? journalOtherId : h.binding.companyId,
        profile: field == 'profile' ? journalOtherId : h.binding.profileId,
      );
      authority.onAcquire = (_) async => authority.scope(
        asIdentity: AttendanceOperationIdentity(
          binding,
          identity.generation + (field == 'generation' ? 1 : 0),
        ),
        projectUrl: field == 'endpoint'
            ? Uri.parse('https://other.invalid')
            : null,
        current: () => true,
      );
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
      );
      expect(requests, isEmpty);
    });
  }
  for (final value in ['', 'private\r\nheader', 'x' * 8193]) {
    test(
      'invalid/oversized credential header is rejected safely length=${value.length}',
      () async {
        authority.onAcquire = (_) async => authority.scope(token: value);
        await expectLater(
          dispatch(),
          throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
        );
        expect(requests, isEmpty);
      },
    );
  }
  test(
    'authority failure cannot leak errors or fall back to shared auth',
    () async {
      authority.onAcquire = (_) async => throw StateError('private credential');
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.authorityUnavailable)),
      );
      authority.throwOnCurrent = true;
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
      );
      expect(requests, isEmpty);
    },
  );
  test('legacy RPC and invalid session target rejected before authority acquisition', () async {
    await expectLater(
      dispatch(command: journalCommand(protocol: JournalProtocol.legacyV1)),
      throwsA(failure(AttendanceHttpFailureKind.invalidRequest)),
    );
    await expectLater(
      adapter.readSession(identity, 'private-target'),
      throwsA(failure(AttendanceHttpFailureKind.invalidRequest)),
    );
    expect(authority.acquisitions, 0);
    expect(requests, isEmpty);
  });

  for (final closed in [false, true]) {
    test(
      'owner-scoped canonical closed=$closed includes no active filter',
      () async {
        handler = (_, _) async =>
            response(jsonEncode([session(closed: closed)]));
        final result = await read();
        expect(result!.isActive, !closed);
        expect(result.startedAt, DateTime.utc(2026, 10, 17, 14));
        expect(result.employeeNote, 'note fictive');
        final request = requests.single.request;
        expect(request.method, 'GET');
        expect(request.url.path, '/rest/v1/work_sessions');
        expect(request.url.queryParameters['id'], 'eq.$journalSessionId');
        expect(
          request.url.queryParameters['company_id'],
          'eq.${h.binding.companyId}',
        );
        expect(
          request.url.queryParameters['employee_profile_id'],
          'eq.${h.binding.profileId}',
        );
        expect(
          request.url.queryParameters.containsKey('lifecycle_status'),
          false,
        );
        expect(
          request.url.queryParameters['select'],
          contains('employee_note'),
        );
        expect(request.followRedirects, false);
      },
    );
  }
  test('empty RLS-filtered canonical result is unavailable, not attendance failure', () async {
    handler = (_, _) async => response('[]');
    expect(await read(), isNull);
  });
  for (final field in [
    'id',
    'company_id',
    'employee_profile_id',
    'review_status',
    'started_at',
    'missing-note',
    'extra-field',
    'multiple',
  ]) {
    test(
      'malformed or wrong-owner canonical $field is never returned',
      () async {
        final row = session();
        if (field == 'missing-note') {
          row.remove('employee_note');
        } else if (field != 'multiple') {
          row[field] = journalOtherId;
        }
        handler = (_, _) async =>
            response(jsonEncode([row, if (field == 'multiple') row]));
        await expectLater(
          read(),
          throwsA(failure(AttendanceHttpFailureKind.malformedResponse)),
        );
      },
    );
  }
  test('canonical checks auth after delayed response and cannot publish after relogin', () async {
    final gate = Completer<http.StreamedResponse>();
    final entered = Completer<void>();
    handler = (_, _) {
      entered.complete();
      return gate.future;
    };
    final expected = expectLater(
      read(),
      throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
    );
    await entered.future;
    h.issuer.relogin();
    gate.complete(response(jsonEncode([session()])));
    await expected;
    expect(requests.length, 1);
  });

  for (final change in ['logout', 'same-user-relogin', 'account-switch']) {
    test(
      'adapter-backed C3.1 retains complete late receipt after $change without refresh',
      () async {
        final body = StreamController<List<int>>();
        final entered = Completer<void>();
        final command = journalCommand();
        final raw = ' \n${JournalJson.encode(journalReceipt(command))} ';
        handler = (_, _) async {
          entered.complete();
          return http.StreamedResponse(body.stream, 200);
        };
        final context = h.issuer.context();
        final core = coordinator();
        final operation = core.submit(context, command);
        await entered.future;
        body.add(utf8.encode(raw.substring(0, 25)));
        await turn();
        expect(context.releaseCalls, 0);
        if (change == 'logout') authority.authorized = false;
        // The shared fake context issuer invalidates the original epoch too.
        h.issuer.relogin(
          asBinding: change == 'account-switch'
              ? journalBinding(auth: journalOtherId)
              : null,
        );
        body.add(utf8.encode(raw.substring(25)));
        await body.close();
        final result = await operation;
        expect(result.outcome, AttendanceOperationOutcome.invalidated);
        expect(result.snapshot, isNull);
        expect(h.record!.phase, JournalPhase.confirmed);
        expect(h.record!.confirmation!.dataJson, raw);
        expect(h.record!.command!.toJson(), command.toJson());
        expect(h.record!.binding.matches(identity.binding), true);
        expect(requests.length, 1);
        expect(
          requests.single.request.headers['Authorization'],
          'Bearer fictional-pinned-token',
        );
        expect(context.releaseCalls, 1);
        await expectLater(
          dispatch(),
          throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
        );
        expect(requests.length, 1);
      },
    );
  }

  test(
    'caller timeout leaves C3.1 response work, queue and ownership outstanding',
    () async {
      final body = StreamController<List<int>>();
      final entered = Completer<void>();
      final command = journalCommand();
      handler = (_, _) async {
        entered.complete();
        return http.StreamedResponse(body.stream, 200);
      };
      final context = h.issuer.context();
      final core = coordinator();
      final operation = core.submit(context, command);
      await entered.future;
      await expectLater(
        operation.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      final queuedContext = h.issuer.context();
      final queued = core.refresh(queuedContext);
      await turn();
      expect(context.releaseCalls, 0);
      expect(queuedContext.releaseCalls, 0);
      expect(requests.length, 1);
      body.add(utf8.encode(JournalJson.encode(journalReceipt(command))));
      handler = (_, _) async => response(jsonEncode([session()]));
      await body.close();
      expect((await operation).outcome, AttendanceOperationOutcome.confirmed);
      expect((await queued).outcome, AttendanceOperationOutcome.confirmed);
      expect(context.releaseCalls, 1);
      expect(requests.map((r) => r.request.method), ['POST', 'GET', 'GET']);
    },
  );

  for (final issue in ['empty', 'denied', 'network', 'malformed']) {
    test(
      'adapter-backed C3.1 canonical $issue retains receipt and retries refresh only',
      () async {
        var fail = true;
        handler = (request, _) async {
          if (request.method == 'POST') {
            return response(
              JournalJson.encode(journalReceipt(journalCommand())),
            );
          }
          if (!fail) return response(jsonEncode([session(closed: true)]));
          return switch (issue) {
            'empty' => response('[]'),
            'denied' => response('private backend error', status: 403),
            'network' => throw http.ClientException('private network error'),
            _ => response('[{"private":"malformed"}]'),
          };
        };
        final core = coordinator();
        final result = await core.submit(h.issuer.context(), journalCommand());
        expect(
          result.outcome,
          AttendanceOperationOutcome.confirmedNeedsRefresh,
        );
        final confirmed = JournalCodec.encode(h.record!);
        fail = false;
        final refreshed = await core.refresh(h.issuer.context());
        expect(refreshed.outcome, AttendanceOperationOutcome.confirmed);
        expect(refreshed.snapshot!.canonicalSession!.isActive, false);
        expect(JournalCodec.encode(h.record!), confirmed);
        expect(requests.map((r) => r.request.method), ['POST', 'GET', 'GET']);
      },
    );
  }
  test(
    'leading UTF-8 BOM is rejected rather than silently removed into a miss',
    () async {
      handler = (_, _) async =>
          response('\ufeff{"contract_version":2,"status":"not_found"}');
      await expectLater(
        dispatch(replay: true),
        throwsA(failure(AttendanceHttpFailureKind.malformedResponse)),
      );
    },
  );
  test('maximum bounded frozen request is sent unchanged', () async {
    final base = journalCommand();
    final frozen =
        base.parametersJson +
        ' ' *
            (JournalJson.payloadLimit -
                utf8.encode(base.parametersJson).length);
    final command = JournalCommand.frozen(
      protocol: base.protocol,
      operation: base.operation,
      parametersJson: frozen,
    );
    await dispatch(command: command);
    expect(requests.single.body.length, JournalJson.payloadLimit);
    expect(utf8.decode(requests.single.body), frozen);
    expect(command.parametersJson, frozen);
  });
  test(
    'successful delayed authority acquisition submits only after it settles',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      authority.onAcquire = (_) async {
        final scope = authority.scope();
        entered.complete();
        await gate.future;
        return scope;
      };
      final result = dispatch();
      await entered.future;
      expect(requests, isEmpty);
      gate.complete();
      expect((await result).dataJson, isNotNull);
      expect(requests.length, 1);
      expect(authority.acquisitions, 1);
    },
  );
  test(
    'throwing scope currency observation fails closed without private details',
    () async {
      authority.onAcquire = (_) async => authority.scope(
        current: () => throw StateError('fictional private token'),
      );
      await expectLater(
        dispatch(),
        throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
      );
      expect(requests, isEmpty);
    },
  );
  test(
    'invalid or oversized project API key is rejected before send',
    () async {
      for (final key in ['', 'private\nkey', 'x' * 4097]) {
        authority.onAcquire = (_) async => authority.scope(key: key);
        await expectLater(
          dispatch(),
          throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
        );
      }
      expect(requests, isEmpty);
    },
  );
  for (final empty in [false, true]) {
    test(
      'canonical empty=$empty waits for full body then suppresses invalidated generation',
      () async {
        final body = StreamController<List<int>>();
        final entered = Completer<void>();
        handler = (_, _) async {
          entered.complete();
          return http.StreamedResponse(body.stream, 200);
        };
        var settled = false;
        final expected = expectLater(
          read().whenComplete(() => settled = true),
          throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
        );
        await entered.future;
        body.add(utf8.encode('['));
        await turn();
        expect(settled, false);
        h.issuer.relogin();
        body.add(utf8.encode(empty ? ']' : '${jsonEncode(session())}]'));
        await body.close();
        await expected;
        expect(requests.length, 1);
      },
    );
  }
  for (final operation in AttendanceCommandKind.values) {
    for (final replay in [false, true]) {
      test(
        'adapter-backed C3.1 $operation replay=$replay persists complete raw confirmation',
        () async {
          final command = journalCommand(
            operation: operation,
            note: const CheckoutNoteIntent.replace(
              '  fictional final note 🚧  ',
            ),
          );
          final receipt = journalReceipt(command, replay: replay)
            ..['started_at'] = '2026-10-17T08:00:00.000123-04:00'
            ..['ended_at'] = operation == AttendanceCommandKind.checkOut
                ? '2026-10-17T16:00:00.654321-04:00'
                : null;
          final raw = ' \n${jsonEncode(receipt)}\t';
          handler = (request, _) async => request.method == 'POST'
              ? response(raw)
              : response(
                  jsonEncode([
                    session(
                      closed: operation == AttendanceCommandKind.checkOut,
                    ),
                  ]),
                );
          final core = coordinator();
          if (replay) {
            h.inject(recordAt(JournalPhase.uncertain, command: command));
          }
          final result = replay
              ? await core.replay(h.issuer.context())
              : await core.submit(h.issuer.context(), command);
          expect(result.outcome, AttendanceOperationOutcome.confirmed);
          expect(h.record!.phase, JournalPhase.confirmed);
          expect(h.record!.confirmation!.dataJson, raw);
          expect(h.record!.command!.toJson(), command.toJson());
          expect(requests.map((r) => r.request.method), ['POST', 'GET']);
        },
      );
    }
  }
  for (final malformed in [false, true]) {
    test(
      'adapter-backed C3.1 ${malformed ? 'malformed receipt' : 'replay miss'} retains uncertainty',
      () async {
        final command = journalCommand();
        final original = recordAt(JournalPhase.uncertain, command: command);
        h.inject(original);
        handler = (_, _) async => response(
          malformed
              ? '{"status":"created"}'
              : '{"contract_version":2,"status":"not_found"}',
        );
        final result = await coordinator().replay(h.issuer.context());
        expect(result.outcome, AttendanceOperationOutcome.unresolved);
        expect(
          result.problem,
          malformed
              ? AttendanceOperationProblem.malformedAcknowledgement
              : AttendanceOperationProblem.replayMiss,
        );
        expect(JournalCodec.encode(h.record!), JournalCodec.encode(original));
        expect(requests.length, 1);
      },
    );
  }
}

Matcher failure(AttendanceHttpFailureKind kind) => isA<AttendanceHttpFailure>()
    .having((error) => error.kind, 'kind', kind)
    .having(
      (error) => error.toString(),
      'safe text',
      'AttendanceHttpFailure(${kind.name})',
    );

Future<void> turn() => Future<void>.delayed(Duration.zero);
