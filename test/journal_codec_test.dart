import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

void main() {
  test(
    'JSON limits accept the exact byte boundary and reject the next byte',
    () {
      final exact = '"${'x' * (JournalJson.payloadLimit - 2)}"';
      expect(
        JournalJson.decodeText(exact, limit: JournalJson.payloadLimit),
        'x' * (JournalJson.payloadLimit - 2),
      );
      expect(
        JournalJson.encode(
          'x' * (JournalJson.payloadLimit - 2),
          limit: JournalJson.payloadLimit,
        ),
        exact,
      );
      expect(
        () =>
            JournalJson.decodeText('$exact ', limit: JournalJson.payloadLimit),
        throwsA(isA<JournalException>()),
      );
      expect(
        () => JournalJson.encode(
          'x' * (JournalJson.payloadLimit - 1),
          limit: JournalJson.payloadLimit,
        ),
        throwsA(isA<JournalException>()),
      );
      final excessiveNodes = List.generate(40, (_) => List.filled(60, 0));
      expect(
        () => JournalJson.encode(excessiveNodes),
        throwsA(isA<JournalException>()),
      );
      expect(
        () => JournalJson.decodeText(jsonEncode(excessiveNodes)),
        throwsA(isA<JournalException>()),
      );
    },
  );
  test('all absent evidence/action fields remain explicit NULL with no clock or fix generated', () {
    final command = JournalCommand.checkInV2(
      const CheckInV2Request(
        idempotencyKey: journalKey,
        evidence: LocationEvidence(
          permission: null,
          result: null,
          provider: null,
        ),
      ),
    );
    final restored = JournalCommand.fromJson(command.toJson());
    expect(restored.parameters.length, 12);
    for (final entry in restored.parameters.entries) {
      if (!const {'p_idempotency_key', 'p_replay_only'}.contains(entry.key)) {
        expect(entry.value, isNull, reason: entry.key);
      }
    }
    expect(restored.parametersJson, command.parametersJson);
  });
  for (final protocol in JournalProtocol.values) {
    for (final operation in AttendanceCommandKind.values) {
      test(
        '$protocol $operation preserves the complete frozen request and receipt',
        () {
          final command = journalCommand(
            protocol: protocol,
            operation: operation,
          );
          final record = recordAt(JournalPhase.confirmed, command: command);
          final result = JournalCodec.decode(
            JournalCodec.encode(record),
            journalBinding(),
          );
          expect(result.issue, isNull);
          expect(result.record!.toJson(), record.toJson());
          expect(
            result.record!.command!.parametersJson,
            command.parametersJson,
          );
          expect(result.record!.command!.key, command.key);
          expect(
            command.rpc,
            '${journalOperation(operation)}${protocol == JournalProtocol.attendanceV2 ? '_v2' : ''}',
          );
          expect(
            result.record!.confirmation!.dataJson,
            record.confirmation!.dataJson,
          );
          expect(
            command.parameters.length,
            protocol == JournalProtocol.legacyV1
                ? operation == AttendanceCommandKind.checkIn
                      ? 4
                      : 3
                : operation == AttendanceCommandKind.checkIn
                ? 12
                : 14,
          );
        },
      );
    }
  }
  for (final phase in JournalPhase.values) {
    test('round trip $phase', () {
      final record = recordAt(phase);
      expect(
        JournalCodec.decode(
          JournalCodec.encode(record),
          journalBinding(),
        ).record!.toJson(),
        record.toJson(),
      );
    });
  }
  for (final note in [
    const CheckoutNoteIntent.preserve(),
    const CheckoutNoteIntent.clear(),
    const CheckoutNoteIntent.replace(''),
    const CheckoutNoteIntent.replace('  e\u0301 🚧\n  '),
  ]) {
    test('checkout preserves ${note.action}/${note.text}', () {
      final command = journalCommand(
        operation: AttendanceCommandKind.checkOut,
        note: note,
      );
      final decoded = JournalCommand.fromJson(command.toJson());
      expect(decoded.parameters['p_note_action'], note.action.name);
      expect(decoded.parameters['p_employee_note'], note.text);
      expect(decoded.parametersJson, command.parametersJson);
    });
  }
  test('explicit NULLs, diagnostics, offset timestamps and decimal tokens stay exact', () {
    var text = journalCommand().parametersJson;
    text = text
        .replaceFirst('45.123456789', '4.5123456789e1')
        .replaceFirst('"precise"', 'null')
        .replaceFirst('"fused"', 'null')
        .replaceFirst('true', 'null')
        .replaceFirst('12.345', '-0.0')
        .replaceAll('2026-10-17T14:30:00.000Z', '2026-10-17T10:30:00-04:00');
    final command = JournalCommand.frozen(
      protocol: JournalProtocol.attendanceV2,
      operation: AttendanceCommandKind.checkIn,
      parametersJson: text,
    );
    final stored = recordAt(JournalPhase.prepared, command: command);
    final restored = JournalCodec.decode(
      JournalCodec.encode(stored),
      journalBinding(),
    ).record!.command!;
    expect(restored.parametersJson, text);
    expect(restored.parameters['p_permission'], isNull);
    expect(restored.parameters['p_provider'], isNull);
    expect(restored.parameters['p_services_enabled'], isNull);
    expect(
      (restored.parameters['p_accuracy_meters'] as double).isNegative,
      isTrue,
    );
    expect(restored.rpcParameters(replayOnly: true), {
      ...restored.parameters,
      'p_replay_only': true,
    });
  });
  test('caller mutation and returned maps cannot change request or acknowledgement', () {
    final params = Map<String, dynamic>.of(journalCommand().parameters);
    final command = JournalCommand.parameters(
      protocol: JournalProtocol.attendanceV2,
      operation: AttendanceCommandKind.checkIn,
      parameters: params,
    );
    params['p_idempotency_key'] = 'different-key';
    expect(command.key, journalKey);
    expect(
      () => command.parameters['p_idempotency_key'] = 'different-key',
      throwsUnsupportedError,
    );
    expect(
      () => command.rpcParameters()['p_latitude'] = 0,
      throwsUnsupportedError,
    );
    final receipt = journalConfirmation(command);
    expect(() => receipt.data['status'] = 'closed', throwsUnsupportedError);
    expect(
      () => (receipt.data['location_outcome'] as Map)['classification'] = 'x',
      throwsUnsupportedError,
    );
    final json = recordAt(JournalPhase.prepared).toJson();
    (json['command'] as Map)['parameters_json'] = '{}';
    expect(command.key, journalKey);
  });
  for (final text in [
    '{"a":1,"a":2}',
    r'{"a":1,"\u0061":2}',
    '{"x":{"a":null,"a":true}}',
    '{"a":1,}',
    '[1,]',
    'true false',
    '01',
    '+1',
    'NaN',
    'Infinity',
    '1e999',
    '1e-999',
    '1.0000000000000001',
    '9007199254740992',
    '-0',
    r'"\ud800"',
    r'"\udc00"',
    r'"\x00"',
    '${'[' * 14}0${']' * 14}',
  ]) {
    test('bounded parser rejects malformed/ambiguous input $text', () {
      expect(
        () => JournalJson.decodeText(text),
        throwsA(isA<JournalException>()),
      );
    });
  }
  for (final text in [
    '1.00',
    '1e2',
    '-0.0',
    '5e-324',
    '1.7976931348623157e308',
    r'{"a":"\ud83d\udea7"}',
  ]) {
    test('bounded parser accepts supported representation $text', () {
      expect(() => JournalJson.decodeText(text), returnsNormally);
    });
  }
  test(
    'invalid UTF8 and surrogate strings are rejected without replacement',
    () {
      expect(
        () => JournalJson.decode([0xff]),
        throwsA(isA<JournalException>()),
      );
      expect(() => JournalJson.decode([256]), throwsA(isA<JournalException>()));
      expect(
        () => JournalJson.encode(String.fromCharCode(0xd800)),
        throwsA(isA<JournalException>()),
      );
      expect(
        () => JournalJson.encode(double.nan),
        throwsA(isA<JournalException>()),
      );
    },
  );
  test('byte limits include UTF8 and nested request/confirmation JSON', () {
    expect(
      () => JournalJson.decodeText(' ' * JournalJson.recordLimit),
      throwsA(isA<JournalException>()),
    );
    expect(
      () => JournalJson.encode('é' * (JournalJson.recordLimit ~/ 2)),
      throwsA(isA<JournalException>()),
    );
    expect(
      () => JournalCommand.frozen(
        protocol: JournalProtocol.attendanceV2,
        operation: AttendanceCommandKind.checkIn,
        parametersJson:
            '${journalCommand().parametersJson}${' ' * JournalJson.payloadLimit}',
      ),
      throwsA(isA<JournalException>()),
    );
    expect(
      () => JournalConfirmation(
        source: JournalConfirmationSource.rpcV2,
        dataJson:
            '${jsonEncode(journalReceipt(journalCommand()))}${' ' * JournalJson.payloadLimit}',
        command: journalCommand(),
      ),
      throwsA(isA<JournalException>()),
    );
    expect(
      JournalCodec.decode(
        List.filled(JournalJson.recordLimit + 1, 32),
        journalBinding(),
      ).issue,
      JournalIssue.corrupt,
    );
  });
  for (final field in [
    'journal_format',
    'revision',
    'binding',
    'phase',
    'command',
    'write_may_have_started',
    'confirmation',
    'block',
    'migration',
  ]) {
    test('missing envelope field $field is blocked, never absent', () {
      final json = recordAt(JournalPhase.prepared).toJson()..remove(field);
      final result = JournalCodec.decode(
        utf8.encode(jsonEncode(json)),
        journalBinding(),
      );
      expect(result.isBlocked, isTrue);
      expect(result.isAbsent, isFalse);
    });
  }
  for (final patch in [
    {'journal_format': 3},
    {'journal_format': 2.0},
    {'phase': 'sending'},
    {'revision': 0},
    {'revision': 1.0},
    {'write_may_have_started': true},
    {'confirmation': {}},
    {'block': {}},
    {'unexpected': null},
    {'command': null},
  ]) {
    test('inconsistent envelope $patch is blocked', () {
      final json = {...recordAt(JournalPhase.prepared).toJson(), ...patch};
      expect(
        JournalCodec.decode(
          utf8.encode(jsonEncode(json)),
          journalBinding(),
        ).isBlocked,
        isTrue,
      );
    });
  }
  for (final binding in [
    journalBinding(environment: 'different-deployment'),
    journalBinding(url: 'https://different.invalid'),
    journalBinding(auth: journalOtherId),
    journalBinding(company: journalOtherId),
    journalBinding(profile: journalOtherId),
  ]) {
    test('complete binding isolates ${binding.storageIdentity}', () {
      final result = JournalCodec.decode(
        JournalCodec.encode(recordAt(JournalPhase.prepared)),
        binding,
      );
      expect(result.issue, JournalIssue.identityMismatch);
      expect(result.record, isNull);
    });
  }
  for (final url in [
    'https://fixture.invalid/rest/v1/',
    'https://fixture.invalid/',
    'https://user:password@fixture.invalid',
    'https://fixture.invalid?q=x',
    'https://fixture.invalid#x',
    'http://fixture.invalid',
  ]) {
    test('ambiguous backend origin is rejected $url', () {
      expect(() => journalBinding(url: url), throwsA(isA<JournalException>()));
    });
  }
  test(
    'explicit loopback development origin is supported without inference',
    () {
      expect(
        journalBinding(url: 'http://127.0.0.1:54321').baseUrl,
        'http://127.0.0.1:54321',
      );
    },
  );
  for (final patch in [
    {'p_replay_only': null},
    {'p_replay_only': true},
    {'p_permission': 'always'},
    {'p_provider': 'vendor'},
    {'p_location_result': 'error'},
    {'p_services_enabled': 1},
    {'p_latitude': '45'},
    {'p_site_description': 'x' * 501},
    {'p_device_observed_at': '2026-02-30T12:00:00Z'},
    {'p_location_observed_at': '2026-10-17T24:00:00Z'},
    {'p_device_observed_at': 'now'},
    {'p_idempotency_key': ' key-1234'},
    {'p_unknown': null},
  ]) {
    test('invalid v2 request $patch is rejected', () {
      expect(
        () => JournalCommand.parameters(
          protocol: JournalProtocol.attendanceV2,
          operation: AttendanceCommandKind.checkIn,
          parameters: {...journalCommand().parameters, ...patch},
        ),
        throwsA(isA<JournalException>()),
      );
    });
  }
  for (final patch in [
    {'p_note_action': 'replace', 'p_employee_note': null},
    {'p_note_action': 'preserve', 'p_employee_note': ''},
    {'p_note_action': 'clear', 'p_employee_note': 'text'},
    {'p_note_action': null},
    {'p_note_action': 'append'},
    {'p_note_action': 'replace', 'p_employee_note': '🚧' * 1001},
  ]) {
    test('invalid final note intent $patch is rejected', () {
      expect(
        () => JournalCommand.parameters(
          protocol: JournalProtocol.attendanceV2,
          operation: AttendanceCommandKind.checkOut,
          parameters: {
            ...journalCommand(operation: AttendanceCommandKind.checkOut)
                .parameters,
            ...patch,
          },
        ),
        throwsA(isA<JournalException>()),
      );
    });
  }
  test('Unicode limits count code points, not UTF16 units or graphemes', () {
    final note = '${'🚧' * 998}e\u0301';
    expect(
      journalCommand(
        operation: AttendanceCommandKind.checkOut,
        note: CheckoutNoteIntent.replace(note),
      ).parameters['p_employee_note'],
      note,
    );
    expect(
      () => journalCommand(
        operation: AttendanceCommandKind.checkOut,
        note: CheckoutNoteIntent.replace('${note}x'),
      ),
      throwsA(isA<JournalException>()),
    );
    final params = {
      ...journalCommand().parameters,
      'p_site_description': '🚧' * 500,
    };
    expect(
      JournalCommand.parameters(
        protocol: JournalProtocol.attendanceV2,
        operation: AttendanceCommandKind.checkIn,
        parameters: params,
      ).parameters,
      params,
    );
  });
  for (final patch in [
    {'protocol': 'v3'},
    {'operation': 'update_employee_note'},
    {'idempotency_key': 'different-key'},
    {'parameters_json': '{}'},
    {'extra': true},
  ]) {
    test('invalid command envelope $patch blocks recovery', () {
      final row = recordAt(JournalPhase.prepared).toJson();
      row['command'] = {...journalCommand().toJson(), ...patch};
      expect(
        JournalCodec.decode(
          utf8.encode(jsonEncode(row)),
          journalBinding(),
        ).isBlocked,
        isTrue,
      );
    });
  }
}
