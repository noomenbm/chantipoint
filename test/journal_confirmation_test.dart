import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

void main() {
  for (final protocol in JournalProtocol.values) {
    for (final operation in AttendanceCommandKind.values) {
      test(
        '$protocol $operation accepts original/replay receipts and rejects wrong protocol',
        () {
          final command = journalCommand(
            protocol: protocol,
            operation: operation,
          );
          final sending = recordAt(JournalPhase.mayHaveSent, command: command);
          for (final replay in [false, true]) {
            final confirmed = sending.confirm(
              journalConfirmation(command, replay: replay),
            );
            expect(
              JournalCodec.decode(
                JournalCodec.encode(confirmed),
                journalBinding(),
              ).record!.confirmation!.data,
              journalReceipt(command, replay: replay),
            );
          }
          expect(
            () => JournalConfirmation(
              command: command,
              dataJson: jsonEncode(journalReceipt(command)),
              source: protocol == JournalProtocol.attendanceV2
                  ? JournalConfirmationSource.rpcV1
                  : JournalConfirmationSource.rpcV2,
            ),
            throwsA(isA<JournalException>()),
          );
        },
      );
    }
  }
  for (final patch in [
    {'status': 'not_found'},
    {'status': 'idempotency_key_conflict'},
    {'contract_version': 1},
    {'contract_version': 2.0},
    {'event_id': null},
    {'event_id': 'invalid'},
    {'session_id': null},
    {'session_id': 'invalid'},
    {'review_status': null},
    {'location_outcome': null},
    {'started_at': 'now'},
    {'started_at': '2026-02-30T12:00:00Z'},
    {'ended_at': '2026-10-17T15:00:00Z'},
    {'lifecycle_status': 'closed_manual'},
    {'location_context': 'somewhere'},
    {'employee_note': 'unrequested text'},
  ]) {
    test(
      'malformed v2 acknowledgement variant ${patch.keys.first}/${patch.values.first} cannot become confirmed',
      () {
        final command = journalCommand();
        expect(
          () => JournalConfirmation(
            source: JournalConfirmationSource.rpcV2,
            command: command,
            dataJson: jsonEncode({...journalReceipt(command), ...patch}),
          ),
          throwsA(anything),
        );
      },
    );
  }
  for (final patch in [
    {'classification': 'elsewhere'},
    {'classification': 'external_worksite'},
    {'reason_code': 'x' * 81},
    {'reason_code': ''},
    {'policy_version': ''},
    {'unexpected': null},
  ]) {
    test('invalid operation outcome ${patch.keys.first} is rejected', () {
      final command = journalCommand();
      final row = journalReceipt(command);
      row['location_outcome'] = {
        ...row['location_outcome'] as Map<String, dynamic>,
        ...patch,
      };
      expect(
        () => JournalConfirmation(
          source: JournalConfirmationSource.rpcV2,
          command: command,
          dataJson: jsonEncode(row),
        ),
        throwsA(anything),
      );
    });
  }
  test('checkout validates target identity while preserving independent departure outcome', () {
    final command = journalCommand(operation: AttendanceCommandKind.checkOut);
    final row = journalReceipt(command);
    row['location_outcome'] = {
      'classification': 'location_unverified',
      'reason_code': 'permission_denied',
      'policy_version': 'dev-v1',
    };
    final confirmation = JournalConfirmation(
      source: JournalConfirmationSource.rpcV2,
      command: command,
      dataJson: jsonEncode(row),
    );
    expect(confirmation.data['location_context'], 'factory');
    expect(
      (confirmation.data['location_outcome'] as Map)['classification'],
      'location_unverified',
    );
    row['session_id'] = journalOtherId;
    expect(
      () => JournalConfirmation(
        source: JournalConfirmationSource.rpcV2,
        command: command,
        dataJson: jsonEncode(row),
      ),
      throwsA(anything),
    );
  });
  test('check-in replay after closure retains advanced lifecycle without rewriting request', () {
    final command = journalCommand();
    final original = command.parametersJson;
    final row = journalReceipt(command, replay: true);
    row['lifecycle_status'] = 'closed_manual';
    row['ended_at'] = '2026-10-17T22:00:00+00:00';
    final confirmed = recordAt(JournalPhase.uncertain).confirm(
      JournalConfirmation(
        source: JournalConfirmationSource.rpcV2,
        command: command,
        dataJson: jsonEncode(row),
      ),
    );
    expect(confirmed.command!.parametersJson, original);
    expect(confirmed.confirmation!.data['lifecycle_status'], 'closed_manual');
  });
  test('revision exhaustion blocks instead of overflowing or resetting', () {
    final original = recordAt(JournalPhase.prepared).toJson();
    final record = JournalRecord.fromJson({
      ...original,
      'revision': JournalJson.maxInteger,
    });
    expect(
      () => record.markMayHaveSent(),
      throwsA(
        isA<JournalException>().having(
          (e) => e.issue,
          'issue',
          JournalIssue.revisionConflict,
        ),
      ),
    );
    expect(record.command!.key, journalKey);
  });
  test('malformed stored confirmation is blocked, preserving the original stored bytes', () {
    final row = recordAt(JournalPhase.confirmed).toJson();
    (row['confirmation'] as Map)['data_json'] = '{"status":"not_found"}';
    final bytes = utf8.encode(jsonEncode(row));
    final original = List<int>.of(bytes);
    final decoded = JournalCodec.decode(bytes, journalBinding());
    expect(decoded.isBlocked, isTrue);
    expect(decoded.isAbsent, isFalse);
    expect(bytes, original);
  });
}
