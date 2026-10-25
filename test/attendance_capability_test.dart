// Fictional authorities and mocked HTTP only. No hosted calls or credentials.
import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_capability.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_attendance_operation_ports.dart';
import 'support/fake_attendance_request_authority.dart';
import 'support/journal_fixtures.dart';

String capability({int gate = 2, String? epoch}) => jsonEncode({
  'capability_version': 1,
  'deployment_epoch': epoch ?? journalBinding().environmentId,
  'write_contract': gate,
  'v2_available': gate == 2,
});

Matcher failure(AttendanceHttpFailureKind kind) => isA<AttendanceHttpFailure>()
    .having((error) => error.kind, 'safe kind', kind);

void main() {
  for (final gate in [1, 2]) {
    test('strict capability gate $gate', () {
      final snapshot = AttendanceCapability.parse(capability(gate: gate));
      expect(snapshot.deploymentEpoch, journalBinding().environmentId);
      expect(snapshot.writeContract, gate);
      expect(snapshot.v2Available, gate == 2);
    });
  }
  test('explicit missing server state remains unavailable', () {
    final snapshot = AttendanceCapability.parse(
      '{"capability_version":1,"deployment_epoch":null,"write_contract":null,"v2_available":false}',
    );
    expect(snapshot.v2Available, false);
    expect(snapshot.deploymentEpoch, null);
  });
  final valid = jsonDecode(capability()) as Map<String, dynamic>;
  final invalid = <String>[
    '',
    'null',
    '[]',
    '{}',
    '${capability()} trailing',
    capability().substring(0, capability().length - 1),
    '{"capability_version":1,${capability().substring(1)}',
    '{"capability_versi\\u006fn":1,${capability().substring(1)}',
    ...[
      0,
      2,
      1.0,
      '1',
      null,
      true,
    ].map((v) => jsonEncode({...valid, 'capability_version': v})),
    ...[
      0,
      3,
      2.0,
      '2',
      null,
      true,
    ].map((v) => jsonEncode({...valid, 'write_contract': v})),
    ...[
      null,
      '',
      'fixture-project',
      ' $journalOtherId',
      '$journalOtherId\n',
      5,
    ].map((v) => jsonEncode({...valid, 'deployment_epoch': v})),
    jsonEncode({
      ...valid,
      'deployment_epoch': 'ABCDEF00-0000-4000-8000-000000000099',
    }),
    jsonEncode({...valid, 'v2_available': false}),
    jsonEncode({...valid, 'v2_available': 'true'}),
    jsonEncode({...valid, 'write_contract': 1}),
    jsonEncode({...valid, 'extra': false}),
    ...valid.keys.map((key) => jsonEncode({...valid}..remove(key))),
    ' ' * 1025 + capability(),
  ];
  for (var i = 0; i < invalid.length; i++) {
    test('malformed capability $i cannot advertise permission', () {
      expect(
        () => AttendanceCapability.parse(invalid[i]),
        throwsA(isA<JournalException>()),
      );
    });
  }

  late FictionalAttendanceOperations h;
  late FictionalRequestAuthority authority;
  late AttendanceOperationIdentity identity;
  late SupabaseAttendanceOperationTransport adapter;
  late MockClient client;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handle;
  setUp(() {
    h = FictionalAttendanceOperations();
    authority = FictionalRequestAuthority(h.issuer);
    identity = AttendanceOperationIdentity(h.binding, h.issuer.generation);
    requests = [];
    handle = (_) async => http.Response(capability(), 200);
    client = MockClient((request) {
      requests.add(request);
      return handle(request);
    });
    adapter = SupabaseAttendanceOperationTransport(
      authority: authority,
      client: client,
    );
  });
  tearDown(() => client.close());

  test('authenticated single GET uses pinned trusted project and no body/epoch header', () async {
    expect((await adapter.readCapability(identity)).v2Available, true);
    final request = requests.single;
    expect(request.method, 'GET');
    expect(
      request.url.toString(),
      'https://fixture.invalid/rest/v1/rpc/attendance_capability',
    );
    expect(request.body, '');
    expect(request.headers['Authorization'], 'Bearer fictional-pinned-token');
    expect(request.headers['apikey'], 'fictional-publishable-key');
    expect(
      request.headers.containsKey('x-chantipoint-attendance-epoch'),
      false,
    );
    expect(request.followRedirects, false);
  });

  for (final gate in [1, 2]) {
    test(
      'availability check denies gate 1, accepts only matching gate 2: $gate',
      () async {
        handle = (_) async => http.Response(capability(gate: gate), 200);
        if (gate == 1) {
          await expectLater(
            adapter.requireV2Capability(identity),
            throwsA(failure(AttendanceHttpFailureKind.capabilityUnavailable)),
          );
        } else {
          await adapter.requireV2Capability(identity);
        }
      },
    );
  }
  for (final text in [
    capability(epoch: journalOtherId),
    '{"capability_version":1,"deployment_epoch":null,"write_contract":null,"v2_available":false}',
  ]) {
    test(
      'wrong or missing deployment cannot supply its own expected identity: $text',
      () async {
        handle = (_) async => http.Response(text, 200);
        await expectLater(
          adapter.readCapability(identity),
          throwsA(failure(AttendanceHttpFailureKind.capabilityUnavailable)),
        );
        expect(authority.expectedEpoch, h.binding.environmentId);
      },
    );
  }
  for (final status in [301, 401, 403, 404, 500]) {
    test('HTTP $status is never capability or an empty success', () async {
      handle = (_) async => http.Response('private fictional error', status);
      await expectLater(
        adapter.readCapability(identity),
        throwsA(failure(AttendanceHttpFailureKind.http)),
      );
      expect(requests.length, 1);
    });
  }
  test('network failure is safe and never retried', () async {
    handle = (_) async => throw http.ClientException('private fictional error');
    await expectLater(
      adapter.readCapability(identity),
      throwsA(failure(AttendanceHttpFailureKind.network)),
    );
    expect(requests.length, 1);
  });
  for (final text in ['{}', ' ' * 1025]) {
    test(
      'malformed or oversized GET result fails closed length=${text.length}',
      () async {
        handle = (_) async => http.Response(text, 200);
        await expectLater(
          adapter.readCapability(identity),
          throwsA(isA<AttendanceHttpFailure>()),
        );
      },
    );
  }
  test('wrong project scope is rejected before GET', () async {
    authority.onAcquire = (_) async =>
        authority.scope(projectUrl: Uri.parse('https://other.invalid'));
    await expectLater(
      adapter.readCapability(identity),
      throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
    );
    expect(requests, isEmpty);
  });
  for (final epoch in [null, 'old-arbitrary-identifier', journalOtherId]) {
    test(
      'untrusted/noncanonical/different scope epoch denies GET and POST: $epoch',
      () async {
        authority.expectedEpoch = epoch;
        await expectLater(
          adapter.readCapability(identity),
          throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
        );
        await expectLater(
          adapter.dispatch(identity, journalCommand(), replayOnly: true),
          throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
        );
        expect(requests, isEmpty);
      },
    );
  }
  for (final moment in ['acquisition', 'response']) {
    for (final change in ['logout', 'same-user-relogin', 'account-switch']) {
      test(
        '$change during $moment invalidates capability, never publishes stale result',
        () async {
          final entered = Completer<void>();
          final resume = Completer<void>();
          if (moment == 'acquisition') {
            authority.onAcquire = (_) async {
              final pinned = authority.scope();
              entered.complete();
              await resume.future;
              return pinned;
            };
          } else {
            handle = (_) async {
              entered.complete();
              await resume.future;
              return http.Response(capability(), 200);
            };
          }
          final expectation = expectLater(
            adapter.readCapability(identity),
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
          resume.complete();
          await expectation;
          expect(requests.length, moment == 'acquisition' ? 0 : 1);
        },
      );
    }
  }
  test(
    'a previous matching snapshot is not reused after epoch rotation',
    () async {
      await adapter.requireV2Capability(identity);
      handle = (_) async =>
          http.Response(capability(epoch: journalOtherId), 200);
      await expectLater(
        adapter.requireV2Capability(identity),
        throwsA(failure(AttendanceHttpFailureKind.capabilityUnavailable)),
      );
      expect(requests.length, 2);
      expect(identity.binding.environmentId, h.binding.environmentId);
    },
  );
  for (final problem in ['gate1', 'rotation', 'network', 'logout']) {
    test(
      'pending original command and binding retained on $problem during recovery',
      () async {
        final original = recordAt(JournalPhase.uncertain);
        h.inject(original);
        final before = JournalCodec.encode(original);
        adapter = SupabaseAttendanceOperationTransport(
          authority: authority,
          client: client,
          beforeAttendanceWrite: (identity) =>
              adapter.requireV2Capability(identity),
        );
        handle = (_) async {
          if (problem == 'network') {
            throw http.ClientException('private fixture');
          }
          if (problem == 'logout') authority.authorized = false;
          return http.Response(
            capability(
              gate: problem == 'gate1' ? 1 : 2,
              epoch: problem == 'rotation' ? journalOtherId : null,
            ),
            200,
          );
        };
        final core = AttendanceOperationCoordinator(
          storage: h.storage,
          transport: adapter,
          canonical: adapter,
        );
        final context = h.issuer.context();
        await core.replay(context);
        expect(JournalCodec.encode(h.record!), before);
        expect(requests.every((request) => request.method == 'GET'), true);
        expect(context.releaseCalls, 1);
      },
    );
  }
  test('auth invalidation in async capability hook prevents POST', () async {
    adapter = SupabaseAttendanceOperationTransport(
      authority: authority,
      client: client,
      beforeAttendanceWrite: (_) async {
        authority.authorized = false;
      },
    );
    await expectLater(
      adapter.dispatch(identity, journalCommand(), replayOnly: false),
      throwsA(failure(AttendanceHttpFailureKind.contextInvalidated)),
    );
    expect(requests, isEmpty);
  });

  test(
    'old non-UUID bindings remain readable and byte-exact but cannot dispatch',
    () async {
      final binding = journalBinding(
        environment: 'historical-deployment-label',
      );
      final original = JournalRecord.absent(binding)
          .prepare(journalCommand())
          .markMayHaveSent();
      final bytes = JournalCodec.encode(original);
      final decoded = JournalCodec.decode(bytes, binding).record!;
      expect(JournalCodec.encode(decoded), bytes);
      h.issuer.relogin(asBinding: binding);
      authority.expectedEpoch = binding.environmentId;
      final captured = AttendanceOperationIdentity(
        binding,
        h.issuer.generation,
      );
      await expectLater(
        adapter.dispatch(captured, decoded.command!, replayOnly: true),
        throwsA(failure(AttendanceHttpFailureKind.scopeMismatch)),
      );
      expect(JournalCodec.encode(decoded), bytes);
      expect(requests, isEmpty);
    },
  );

  test('server rejection after matching capability preserves original epoch and uncertainty', () async {
    final original = recordAt(JournalPhase.uncertain);
    h.inject(original);
    adapter = SupabaseAttendanceOperationTransport(
      authority: authority,
      client: client,
      beforeAttendanceWrite: (identity) =>
          adapter.requireV2Capability(identity),
    );
    handle = (request) async => request.method == 'GET'
        ? http.Response(capability(), 200)
        : http.Response('private fictional epoch rejection', 400);
    final core = AttendanceOperationCoordinator(
      storage: h.storage,
      transport: adapter,
      canonical: adapter,
    );
    await core.replay(h.issuer.context());
    expect(JournalCodec.encode(h.record!), JournalCodec.encode(original));
    expect(requests.map((request) => request.method), ['GET', 'POST']);
    expect(
      requests.last.headers['x-chantipoint-attendance-epoch'],
      original.binding.environmentId,
    );
    expect(
      jsonDecode(requests.last.body),
      original.command!.rpcParameters(replayOnly: true),
    );
  });
}
