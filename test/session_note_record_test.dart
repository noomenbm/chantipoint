import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';
import 'support/session_note_fixture.dart';

void main() {
  late SessionNoteFixture f;
  setUp(() => f = SessionNoteFixture());
  tearDown(() => f.close());
  test(
    'immutable generation, binding and original parameter bytes round trip',
    () {
      final command = f.command();
      final pending = SessionNoteRecord.absent(command.identity.binding)
          .prepare(command);
      final parsed = SessionNoteRecord.decode(
        pending.bytes,
        command.identity.binding,
      );
      expect(parsed.command!.same(command), isTrue);
      expect(parsed.command!.parametersJson, command.parametersJson);
      expect(parsed.command!.text, '  Réparation é terminée.  ');
      expect(parsed.command!.identity.generation, 1);
      expect(jsonDecode(command.body(replayOnly: true)), {
        ...command.parameters,
        'p_replay_only': true,
      });
      expect(command.parameters['p_replay_only'], false);
    },
  );
  for (final length in [999, 1000, 1001]) {
    for (final combining in [false, true]) {
      test('Unicode $length code points, combining=$combining', () {
        final text = combining
            ? '${'e\u0301' * (length ~/ 2)}${length.isOdd ? 'é' : ''}'
            : '🚧' * length;
        if (length > 1000) {
          expect(() => f.command(text: text), throwsA(isA<JournalException>()));
        } else {
          expect(f.command(text: text).text, text);
        }
      });
    }
  }
  for (final text in ['', null]) {
    test('empty replacement and explicit clear differ: $text', () {
      final command = f.command(text: text);
      expect(
        command.parameters['p_note_action'],
        text == null ? 'clear' : 'replace',
      );
      expect(command.text, text);
    });
  }
  for (final text in ['\u0000', '\ud800']) {
    test('invalid Unicode/text rejected without truncation', () {
      expect(() => f.command(text: text), throwsA(isA<JournalException>()));
    });
  }
  test('standalone preserve is not a write', () {
    expect(
      () => f.command(intent: const CheckoutNoteIntent.preserve()),
      throwsA(isA<JournalException>()),
    );
  });
  for (final reason in <String?>[null, 'replay_fenced', 'session_closed']) {
    test(
      'terminal receipt $reason retains original lexical timestamp/JSON',
      () {
        final command = f.command();
        final raw =
            ' \n${jsonEncode(noteReceiptJson(command, reason: reason))}\n';
        final receipt = SessionNoteReceipt.parse(raw, command);
        expect(receipt.json, raw);
        expect(
          receipt.outcome,
          reason == null
              ? SessionNoteOutcome.applied
              : SessionNoteOutcome.notApplied,
        );
        final terminal = SessionNoteRecord.absent(command.identity.binding)
            .prepare(command)
            .confirm(receipt);
        expect(
          SessionNoteRecord.decode(
            terminal.bytes,
            command.identity.binding,
          ).receipt!.json,
          raw,
        );
      },
    );
  }
  final bad = <String, Object?>{
    'note_contract_version': 2,
    'operation_key': 'different-key',
    'employee_profile_id': journalOtherId,
    'company_id': journalOtherId,
    'session_id': journalOtherId,
    'outcome': 'not_found',
    'reason': 'unknown',
    'request_fingerprint': 'INVALID',
    'settled_at': '2026-02-30T00:00:00Z',
  };
  for (final entry in bad.entries) {
    test('reject mismatched/malformed receipt ${entry.key}', () {
      final command = f.command();
      expect(
        () => SessionNoteReceipt.parse(
          jsonEncode({...noteReceiptJson(command), entry.key: entry.value}),
          command,
        ),
        throwsA(isA<JournalException>()),
      );
    });
  }
  for (final alteration in [
    'missing',
    'extra',
    'duplicate',
    'truncated',
    'booleanVersion',
    'nonAppliedNull',
    'appliedReason',
  ]) {
    test('strict receipt shape: $alteration', () {
      final command = f.command();
      final r = noteReceiptJson(command);
      var raw = jsonEncode(r);
      switch (alteration) {
        case 'missing':
          r.remove('reason');
          raw = jsonEncode(r);
        case 'extra':
          r['employee_note'] = 'Must not appear';
          raw = jsonEncode(r);
        case 'duplicate':
          raw = raw.replaceFirst('{', '{"note_contract_version":1,');
        case 'truncated':
          raw = raw.substring(0, raw.length - 1);
        case 'booleanVersion':
          r['note_contract_version'] = true;
          raw = jsonEncode(r);
        case 'nonAppliedNull':
          r['outcome'] = 'not_applied';
          raw = jsonEncode(r);
        case 'appliedReason':
          r['reason'] = 'replay_fenced';
          raw = jsonEncode(r);
      }
      expect(
        () => SessionNoteReceipt.parse(raw, command),
        throwsA(isA<JournalException>()),
      );
    });
  }
  test('wrong environment/owner record cannot decode', () {
    final record = SessionNoteRecord.absent(f.operations.binding)
        .prepare(f.command());
    for (final binding in [
      journalBinding(environment: 'other-project'),
      journalBinding(profile: journalOtherId),
    ]) {
      expect(
        () => SessionNoteRecord.decode(record.bytes, binding),
        throwsA(isA<JournalException>()),
      );
    }
  });
  test(
    'changed command cannot replace pending or reuse terminal operation key',
    () {
      final command = f.command();
      final pending = SessionNoteRecord.absent(f.operations.binding)
          .prepare(command);
      expect(
        () => pending.prepare(f.command(key: 'new-fictional-key')),
        throwsA(isA<JournalException>()),
      );
      final terminal = pending.confirm(
        SessionNoteReceipt.parse(jsonEncode(noteReceiptJson(command)), command),
      );
      expect(
        () => terminal.prepare(f.command(text: 'Changed')),
        throwsA(isA<JournalException>()),
      );
    },
  );
}
