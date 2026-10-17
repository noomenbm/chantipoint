import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';
import 'support/memory_journal_storage.dart';

void main() {
  for (final operation in AttendanceCommandKind.values) {
    test(
      '$operation with unknown provenance remains blocked and yields no executable command',
      () {
        final result = LegacyJournalImport.prepare(
          legacySource(operation: operation),
        );
        expect(result.issue, JournalIssue.bindingRequired);
        expect(result.binding, isNull);
        expect(result.command, isNull);
      },
    );
    test(
      'approved $operation retains legacy key, timestamp and RPC parameters exactly',
      () async {
        final source = legacySource(operation: operation);
        final originalBytes = List<int>.of(source);
        final approval = legacyApproval(source);
        final result = LegacyJournalImport.prepare(source, approval: approval);
        expect(result.issue, isNull);
        expect(
          result.command!.parameters,
          (jsonDecode(utf8.decode(source)) as Map)['payload'],
        );
        expect(result.command!.key, journalKey);
        expect(source, originalBytes);
        final disk = MemoryJournalDisk();
        final journal = CommandJournal(MemoryJournalStorage(disk));
        final imported = await journal.importLegacy(
          result.binding!,
          result.command!,
          result.metadata!,
          expectedRevision: 0,
          expectedKey: null,
        );
        expect(imported.record!.phase, JournalPhase.uncertain);
        expect(imported.record!.writeMayHaveStarted, isTrue);
        expect(imported.record!.migration!.plaintextCleanupComplete, isFalse);
        final reopened = (await CommandJournal(
          MemoryJournalStorage(disk),
        ).read(result.binding!)).record!;
        expect(reopened.toJson(), imported.record!.toJson());
        expect(
          (await journal.markMayHaveSent(
            result.binding!,
            expectedRevision: reopened.revision,
            expectedKey: journalKey,
          )).issue,
          JournalIssue.illegalTransition,
        );
        // Pure attestation only. This test deletes no actual file.
        final cleaned = await journal.markLegacyCleanupComplete(
          result.binding!,
          result.metadata!.sourceSha256,
          expectedRevision: reopened.revision,
          expectedKey: journalKey,
        );
        expect(
          cleaned.record!.command!.parametersJson,
          result.command!.parametersJson,
        );
        expect(
          (await journal.markMayHaveSent(
            result.binding!,
            expectedRevision: cleaned.record!.revision,
            expectedKey: journalKey,
          )).record!.phase,
          JournalPhase.mayHaveSent,
        );
      },
    );
  }
  test('approval is pinned to exact source bytes and cannot be reused for a changed command', () {
    final source = legacySource();
    final approval = legacyApproval(source);
    final modified = utf8.encode(
      utf8.decode(source).replaceFirst(journalKey, 'fictional-changed-key'),
    );
    expect(
      LegacyJournalImport.prepare(modified, approval: approval).issue,
      JournalIssue.commandConflict,
    );
    source[0] = 0;
    expect(approval.approvedSource.first, 123);
    expect(() => approval.approvedSource[0] = 0, throwsUnsupportedError);
  });
  test('current account UUIDs cannot establish backend provenance', () {
    final source = legacySource();
    // Even a matching owner has no environment/Auth identity in a v1 record.
    expect(
      LegacyJournalImport.prepare(source).issue,
      JournalIssue.bindingRequired,
    );
    final result = LegacyJournalImport.prepare(
      source,
      approval: legacyApproval(
        source,
        binding: journalBinding(
          auth: journalOtherId,
          environment: 'explicitly-reviewed-origin',
        ),
      ),
    );
    expect(result.binding!.environmentId, 'explicitly-reviewed-origin');
    // This is an external attestation, not automatic discovery or proof by UUID.
  });
  test('mismatched company/profile approval reveals no command', () {
    final source = legacySource();
    final result = LegacyJournalImport.prepare(
      source,
      approval: legacyApproval(
        source,
        binding: journalBinding(profile: journalOtherId),
      ),
    );
    expect(result.issue, JournalIssue.identityMismatch);
    expect(result.command, isNull);
  });
  for (final patch in [
    {'version': 2},
    {'version': 1.0},
    {'owner': null},
    {'kind': 'check_in_v2'},
    {'payload': {}},
    {'unexpected': true},
  ]) {
    test('malformed/unsupported legacy record $patch stays blocked', () {
      final json = {
        ...jsonDecode(utf8.decode(legacySource())) as Map<String, dynamic>,
        ...patch,
      };
      final source = utf8.encode(jsonEncode(json));
      final result = LegacyJournalImport.prepare(
        source,
        approval: legacyApproval(source),
      );
      expect(result.issue, isNotNull);
      expect(result.command, isNull);
    });
  }
  test('legacy parser rejects duplicate keys and added GPS evidence', () {
    final text = utf8.decode(legacySource());
    expect(
      LegacyJournalImport.prepare(
        utf8.encode(
          text.replaceFirst('"version":1', '"version":1,"version":1'),
        ),
      ).issue,
      JournalIssue.corrupt,
    );
    final json = jsonDecode(text) as Map<String, dynamic>;
    (json['payload'] as Map)['p_latitude'] = 45;
    expect(
      LegacyJournalImport.prepare(utf8.encode(jsonEncode(json))).issue,
      JournalIssue.corrupt,
    );
  });
  test('legacy decoder does not repair an invalid timestamp or infer missing fields', () {
    final json =
        jsonDecode(utf8.decode(legacySource())) as Map<String, dynamic>;
    (json['payload'] as Map)['p_device_observed_at'] = '2026-02-30T10:00:00Z';
    expect(
      LegacyJournalImport.prepare(utf8.encode(jsonEncode(json))).issue,
      JournalIssue.corrupt,
    );
    (json['payload'] as Map).remove('p_device_observed_at');
    expect(
      LegacyJournalImport.prepare(utf8.encode(jsonEncode(json))).issue,
      JournalIssue.corrupt,
    );
  });
  test('unconfirmed legacy import requires the matching cleanup digest', () {
    final result = LegacyJournalImport.prepare(
      legacySource(),
      approval: legacyApproval(legacySource()),
    );
    final record = JournalRecord.absent(result.binding!)
        .importLegacy(result.command!, result.metadata!);
    expect(record.confirmation, isNull);
    expect(
      () => record.markLegacyCleanupComplete('b' * 64),
      throwsA(isA<JournalException>()),
    );
  });
  for (final operation in AttendanceCommandKind.values) {
    test(
      'legacy SELECT $operation proof is validated without inventing an RPC receipt',
      () {
        final source = legacySource(operation: operation);
        final result = LegacyJournalImport.prepare(
          source,
          approval: legacyApproval(source),
        );
        final record = JournalRecord.absent(result.binding!)
            .importLegacy(result.command!, result.metadata!);
        final out = operation == AttendanceCommandKind.checkOut;
        final row = <String, dynamic>{
          'id': journalSessionId,
          'location_context': 'factory',
          'lifecycle_status': out ? 'closed_manual' : 'active',
          'started_at': '2026-10-17T14:00:00Z',
          'ended_at': out ? '2026-10-17T22:00:00Z' : null,
          'site_description': null,
          'check_in_device_observed_at': journalTime.toIso8601String(),
          'check_out_device_observed_at': out
              ? journalTime.toIso8601String()
              : null,
        };
        JournalConfirmation confirmation(
          Map<String, dynamic> session, {
          String key = journalKey,
        }) => JournalConfirmation(
          source: JournalConfirmationSource.legacySelect,
          command: result.command!,
          dataJson: jsonEncode({'matched_key': key, 'session': session}),
        );
        final receipt = confirmation(row);
        expect(
          record.confirm(receipt).confirmation!.source,
          JournalConfirmationSource.legacySelect,
        );
        expect(receipt.data.containsKey('status'), isFalse);
        expect(
          () => confirmation(row, key: 'other-key'),
          throwsA(isA<JournalException>()),
        );
        expect(
          () => confirmation({
            ...row,
            out
                    ? 'check_out_device_observed_at'
                    : 'check_in_device_observed_at':
                '2026-10-17T14:30:01Z',
          }),
          throwsA(isA<JournalException>()),
        );
        expect(
          () => confirmation({...row, 'location_context': 'external_worksite'}),
          throwsA(isA<JournalException>()),
        );
        if (out) {
          expect(
            () => confirmation({...row, 'id': journalOtherId}),
            throwsA(isA<JournalException>()),
          );
          expect(
            () => confirmation({
              ...row,
              'lifecycle_status': 'active',
              'ended_at': null,
            }),
            throwsA(isA<JournalException>()),
          );
        } else {
          expect(
            () => confirmation({...row, 'site_description': 'changed'}),
            throwsA(isA<JournalException>()),
          );
        }
      },
    );
  }
  test('completed migration metadata allows later v2 commands without resurrecting legacy input', () {
    final source = legacySource();
    final imported = LegacyJournalImport.prepare(
      source,
      approval: legacyApproval(source),
    );
    final pending = JournalRecord.absent(imported.binding!)
        .importLegacy(imported.command!, imported.metadata!);
    final confirmed = pending.confirm(journalConfirmation(imported.command!));
    expect(
      () => confirmed.compactConfirmed(
        canonicalStateVerified: true,
        confirmationConsumed: true,
      ),
      throwsA(isA<JournalException>()),
    );
    final cleaned = confirmed.markLegacyCleanupComplete(
      imported.metadata!.sourceSha256,
    );
    final empty = cleaned.compactConfirmed(
      canonicalStateVerified: true,
      confirmationConsumed: true,
    );
    expect(empty.migration!.sourceSha256, imported.metadata!.sourceSha256);
    final v2 = empty.prepare(journalCommand(key: 'fictional-new-v2-key'));
    final restored = JournalCodec.decode(
      JournalCodec.encode(v2),
      imported.binding!,
    );
    expect(restored.issue, isNull);
    expect(restored.record!.command!.protocol, JournalProtocol.attendanceV2);
    expect(restored.record!.migration!.plaintextCleanupComplete, isTrue);
    expect(
      () => empty.importLegacy(imported.command!, imported.metadata!),
      throwsA(isA<JournalException>()),
    );
  });
  for (final phase in JournalPhase.values) {
    test('legacy import into $phase only permits an empty slot', () {
      final source = legacySource();
      final result = LegacyJournalImport.prepare(
        source,
        approval: legacyApproval(source),
      );
      final current = recordAt(phase);
      if (phase == JournalPhase.empty) {
        expect(
          current.importLegacy(result.command!, result.metadata!).phase,
          JournalPhase.uncertain,
        );
      } else {
        expect(
          () => current.importLegacy(result.command!, result.metadata!),
          throwsA(isA<JournalException>()),
        );
      }
    });
  }
}
