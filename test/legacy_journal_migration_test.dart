import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_migration.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

import 'support/journal_fixtures.dart';

// All supplied bytes and attestations are fictional; no files/services are used.
LegacyBindingApproval approvalFor(
  List<int> bytes, {
  JournalBinding? binding,
  String? digest,
  String? basename,
  String? owner,
  String reference = 'fictional-origin-review-1',
}) {
  final identity = binding ?? journalBinding();
  final legacyOwner = '${identity.companyId}:${identity.profileId}';
  return LegacyBindingApproval(
    binding: identity,
    approvedSource: bytes,
    metadata: JournalMigration(
      sourceBasename:
          basename ??
          'attendance_${base64Url.encode(utf8.encode(legacyOwner)).replaceAll('=', '')}.json',
      sourceSha256: digest ?? sha256.convert(bytes).toString(),
      legacyOwner: owner ?? legacyOwner,
      bindingApprovalRef: reference,
    ),
  );
}

LegacySourceSnapshot snapshotOf(List<int> bytes, {String? basename}) =>
    LegacySourceSnapshot.file(
      basename: basename ?? approvalFor(bytes).metadata.sourceBasename,
      bytes: bytes,
    );

LegacyMigrationPlan evaluate({
  required LegacySourceSnapshot source,
  required LegacyBindingApproval? approval,
  JournalBinding? binding,
  JournalReadResult target = const JournalReadResult.absent(),
  LegacyApprovalTrust trust = LegacyApprovalTrust.established,
}) => LegacyJournalMigration.evaluate(
  binding: binding ?? journalBinding(),
  source: source,
  target: target,
  approval: approval,
  approvalTrust: trust,
);

JournalRecord imported(LegacyBindingApproval approval) {
  final prepared = LegacyJournalImport.prepare(
    approval.approvedSource,
    approval: approval,
  );
  return JournalRecord.absent(approval.binding)
      .importLegacy(prepared.command!, prepared.metadata!);
}

void expectBlocked(LegacyMigrationPlan plan, JournalIssue issue) {
  expect(plan.step, LegacyMigrationStep.blocked);
  expect(plan.issue, issue);
  expect(plan.importRecord, isNull);
  expect(plan.existingRecord, isNull);
  expect(plan.requiredChecks, isEmpty);
}

void main() {
  for (final vector in {
    '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  }.entries) {
    test('source SHA-256 matches known vector ${vector.key.length} bytes', () {
      expect(snapshotOf(utf8.encode(vector.key)).sourceSha256, vector.value);
    });
  }

  test(
    'snapshot bytes, digest and artifact set cannot change after capture',
    () {
      final bytes = legacySource();
      final original = List<int>.of(bytes);
      final artifacts = {LegacySourceArtifact.temporary};
      final snapshot = LegacySourceSnapshot.file(
        basename: approvalFor(bytes).metadata.sourceBasename,
        bytes: bytes,
        artifacts: artifacts,
      );
      final digest = snapshot.sourceSha256;
      bytes[0] = 0;
      artifacts.clear();
      expect(snapshot.bytes, original);
      expect(snapshot.sourceSha256, digest);
      expect(snapshot.artifacts, {LegacySourceArtifact.temporary});
      expect(() => snapshot.bytes![0] = 0, throwsUnsupportedError);
      expect(() => snapshot.artifacts.clear(), throwsUnsupportedError);
    },
  );

  for (final bytes in [
    List<int>.filled(JournalJson.recordLimit + 1, 32),
    [-1],
    [256],
  ]) {
    test(
      'snapshot rejects invalid/oversized bytes before hashing (${bytes.length})',
      () {
        expect(
          () => LegacySourceSnapshot.file(
            basename: 'attendance_fixture.json',
            bytes: bytes,
          ),
          throwsA(
            isA<JournalException>().having(
              (e) => e.issue,
              'issue',
              JournalIssue.corrupt,
            ),
          ),
        );
      },
    );
  }
  test(
    'maximum bounded snapshot is accepted but malformed content is blocked',
    () {
      final snapshot = snapshotOf(
        List<int>.filled(JournalJson.recordLimit, 32),
      );
      expect(snapshot.bytes!.length, JournalJson.recordLimit);
      expectBlocked(
        evaluate(source: snapshot, approval: null),
        JournalIssue.corrupt,
      );
    },
  );

  test('absent source and target require no migration or approval', () {
    final plan = evaluate(
      source: LegacySourceSnapshot.absent(),
      approval: null,
    );
    expect(plan.step, LegacyMigrationStep.noAction);
    expect(plan.importRecord, isNull);
    expect(plan.existingRecord, isNull);
    expect(plan.requiredChecks, isEmpty);
  });

  test(
    'absent source does not turn an unrelated valid target into an import',
    () {
      final current = recordAt(JournalPhase.prepared);
      final plan = evaluate(
        source: LegacySourceSnapshot.absent(),
        approval: null,
        target: JournalReadResult.stored(current),
      );
      expect(plan.step, LegacyMigrationStep.noAction);
      expect(plan.existingRecord, same(current));
      expect(plan.importRecord, isNull);
    },
  );

  for (final operation in AttendanceCommandKind.values) {
    group(operation.name, () {
      late List<int> bytes;
      late LegacyBindingApproval approval;
      late LegacySourceSnapshot snapshot;
      setUp(() {
        bytes = legacySource(operation: operation);
        approval = approvalFor(bytes);
        snapshot = snapshotOf(bytes);
      });

      test('verified source proposes uncertain import with original complete command', () {
        final plan = evaluate(source: snapshot, approval: approval);
        final expected = imported(approval);
        expect(plan.step, LegacyMigrationStep.importLegacy);
        expect(plan.issue, isNull);
        expect(plan.importRecord!.toJson(), expected.toJson());
        expect(
          plan.importRecord!.command!.rpc,
          operation == AttendanceCommandKind.checkIn ? 'check_in' : 'check_out',
        );
        expect(
          plan.importRecord!.command!.parameters,
          (jsonDecode(utf8.decode(bytes)) as Map)['payload'],
        );
        expect(plan.importRecord!.command!.key, journalKey);
        expect(plan.importRecord!.phase, JournalPhase.uncertain);
        expect(plan.importRecord!.writeMayHaveStarted, isTrue);
        expect(plan.importRecord!.confirmation, isNull);
        expect(
          plan.importRecord!.migration!.sourceSha256,
          snapshot.sourceSha256,
        );
        expect(plan.importRecord!.migration!.plaintextCleanupComplete, isFalse);
        expect(plan.requiredChecks, LegacyMigrationCheck.values.toSet());
        expect(() => plan.requiredChecks.clear(), throwsUnsupportedError);
        expect(
          () => plan.importRecord!.markMayHaveSent(),
          throwsA(isA<JournalException>()),
        );
      });

      test('eligible existing empty target keeps CAS revision lineage', () {
        final empty = JournalRecord.fromJson({
          ...JournalRecord.absent(journalBinding()).toJson(),
          'revision': 9,
        });
        final plan = evaluate(
          source: snapshot,
          approval: approval,
          target: JournalReadResult.stored(empty),
        );
        expect(plan.step, LegacyMigrationStep.importLegacy);
        expect(plan.existingRecord, same(empty));
        expect(plan.importRecord!.revision, 10);
        expect(empty.revision, 9);
        expect(empty.phase, JournalPhase.empty);
      });

      test(
        'missing approval yields no executable import despite matching owner',
        () {
          final plan = evaluate(source: snapshot, approval: null);
          expect(plan.step, LegacyMigrationStep.bindingRequired);
          expect(plan.issue, JournalIssue.bindingRequired);
          expect(plan.importRecord, isNull);
          expect(plan.existingRecord, isNull);
        },
      );

      test('unverified attestation is insufficient and trust defaults to unverified', () {
        final plan = LegacyJournalMigration.evaluate(
          binding: journalBinding(),
          source: snapshot,
          target: const JournalReadResult.absent(),
          approval: approval,
        );
        expect(plan.step, LegacyMigrationStep.bindingRequired);
        expect(plan.importRecord, isNull);
        expect(
          evaluate(
            source: snapshot,
            approval: approval,
            trust: LegacyApprovalTrust.unverified,
          ).step,
          LegacyMigrationStep.bindingRequired,
        );
      });

      test('well-shaped false digest cannot approve the source', () {
        expectBlocked(
          evaluate(
            source: snapshot,
            approval: approvalFor(bytes, digest: 'a' * 64),
          ),
          JournalIssue.commandConflict,
        );
      });

      for (final whitespaceOnly in [false, true]) {
        test(
          'changed source is blocked (whitespace only: $whitespaceOnly)',
          () {
            final changed = utf8.encode(
              whitespaceOnly
                  ? '${utf8.decode(bytes)}\n'
                  : utf8
                        .decode(bytes)
                        .replaceFirst(journalKey, 'fictional-other-key'),
            );
            expectBlocked(
              evaluate(source: snapshotOf(changed), approval: approval),
              JournalIssue.commandConflict,
            );
            // Even a digest matching today's bytes cannot bypass the exact byte
            // pin in the original attestation.
            final mismatchedPin = LegacyBindingApproval(
              binding: approval.binding,
              metadata: approvalFor(changed).metadata,
              approvedSource: bytes,
            );
            expectBlocked(
              evaluate(source: snapshotOf(changed), approval: mismatchedPin),
              JournalIssue.commandConflict,
            );
          },
        );
      }

      test('original timestamp string is not canonicalized by import', () {
        final changed = utf8.encode(
          utf8
              .decode(bytes)
              .replaceFirst(
                '2026-10-17T14:30:00.000Z',
                '2026-10-17T14:30:00.000000Z',
              ),
        );
        final plan = evaluate(
          source: snapshotOf(changed),
          approval: approvalFor(changed),
        );
        expect(plan.step, LegacyMigrationStep.importLegacy);
        expect(
          plan.importRecord!.command!.parameters['p_device_observed_at'],
          '2026-10-17T14:30:00.000000Z',
        );
      });

      for (final binding in [
        journalBinding(auth: journalOtherId),
        journalBinding(company: journalOtherId),
        journalBinding(profile: journalOtherId),
        journalBinding(environment: 'fictional-other-generation'),
        journalBinding(url: 'https://other-fixture.invalid'),
      ]) {
        test(
          'approval must match every expected binding field ${binding.storageIdentity}',
          () {
            expectBlocked(
              evaluate(
                source: snapshot,
                approval: approvalFor(bytes, binding: binding),
              ),
              JournalIssue.identityMismatch,
            );
          },
        );
        test(
          'target must match every expected binding field ${binding.storageIdentity}',
          () {
            final other = JournalRecord.fromJson({
              ...JournalRecord.absent(binding).toJson(),
              'revision': 1,
            });
            expectBlocked(
              evaluate(
                source: snapshot,
                approval: approval,
                target: JournalReadResult.stored(other),
              ),
              JournalIssue.identityMismatch,
            );
          },
        );
      }

      test('source owner mismatch cannot be repaired by a matching approval/context', () {
        final other = journalBinding(profile: journalOtherId);
        final otherApproval = approvalFor(bytes, binding: other);
        expectBlocked(
          evaluate(
            source: snapshotOf(
              bytes,
              basename: otherApproval.metadata.sourceBasename,
            ),
            approval: otherApproval,
            binding: other,
          ),
          JournalIssue.identityMismatch,
        );
      });
      test('approval legacy owner must match source and full binding', () {
        expectBlocked(
          evaluate(
            source: snapshot,
            approval: approvalFor(bytes, owner: 'fictional-wrong-owner'),
          ),
          JournalIssue.identityMismatch,
        );
      });
      test('actual basename must match approval', () {
        expectBlocked(
          evaluate(
            source: snapshotOf(bytes, basename: 'attendance_wrong.json'),
            approval: approval,
          ),
          JournalIssue.commandConflict,
        );
      });
      test('agreement on a wrong basename is still blocked', () {
        expectBlocked(
          evaluate(
            source: snapshotOf(bytes, basename: 'attendance_wrong.json'),
            approval: approvalFor(bytes, basename: 'attendance_wrong.json'),
          ),
          JournalIssue.commandConflict,
        );
      });

      for (final sourcePresent in [true, false]) {
        for (final confirmed in [false, true]) {
          test(
            'pending resumption retains complete original record (source: $sourcePresent, confirmed: $confirmed)',
            () {
              var current = imported(approval);
              if (confirmed) {
                current = current.confirm(
                  journalConfirmation(current.command!, replay: true),
                );
              }
              final original = JournalCodec.encode(current);
              final plan = evaluate(
                source: sourcePresent
                    ? snapshot
                    : LegacySourceSnapshot.absent(),
                approval: approval,
                target: JournalReadResult.stored(current),
              );
              expect(plan.step, LegacyMigrationStep.resumeCleanup);
              expect(plan.importRecord, isNull);
              expect(plan.existingRecord, same(current));
              expect(JournalCodec.encode(plan.existingRecord!), original);
              expect(
                plan.existingRecord!.confirmation,
                same(current.confirmation),
              );
              expect(plan.requiredChecks, {
                LegacyMigrationCheck.writerFencing,
                LegacyMigrationCheck.globalSourceBinding,
                if (sourcePresent)
                  LegacyMigrationCheck.sourceSnapshotVerification,
                LegacyMigrationCheck.durableTargetVerification,
                if (sourcePresent) LegacyMigrationCheck.checkedPlaintextCleanup,
                LegacyMigrationCheck.durableSourceAbsenceVerification,
                LegacyMigrationCheck.cleanupCompletionCompareAndSwap,
              });
              expect(
                plan.existingRecord!.migration!.plaintextCleanupComplete,
                isFalse,
              );
              expect(
                () => current.markMayHaveSent(),
                throwsA(isA<JournalException>()),
              );
            },
          );
        }
        test(
          'pending import still requires established approval when source present: $sourcePresent',
          () {
            for (final suppliedApproval in <LegacyBindingApproval?>[
              null,
              approval,
            ]) {
              final plan = evaluate(
                source: sourcePresent
                    ? snapshot
                    : LegacySourceSnapshot.absent(),
                approval: suppliedApproval,
                trust: LegacyApprovalTrust.unverified,
                target: JournalReadResult.stored(imported(approval)),
              );
              expect(plan.step, LegacyMigrationStep.bindingRequired);
              expect(plan.importRecord, isNull);
              expect(plan.existingRecord, isNull);
            }
          },
        );
      }

      test('absent source revalidates approved bytes/digest instead of trusting metadata', () {
        expectBlocked(
          evaluate(
            source: LegacySourceSnapshot.absent(),
            approval: approvalFor(bytes, digest: 'a' * 64),
            target: JournalReadResult.stored(imported(approval)),
          ),
          JournalIssue.commandConflict,
        );
      });

      test('same key with different original timestamp is a conflict', () {
        final current = imported(approval);
        final original = JournalCodec.encode(current);
        final changed = utf8.encode(
          utf8.decode(bytes).replaceFirst('14:30:00', '14:30:01'),
        );
        expectBlocked(
          evaluate(
            source: snapshotOf(changed),
            approval: approvalFor(changed),
            target: JournalReadResult.stored(current),
          ),
          JournalIssue.commandConflict,
        );
        expect(JournalCodec.encode(current), original);
      });

      test('same key and migration identity cannot hide a different frozen command', () {
        final current = imported(approval);
        final json = current.toJson();
        json['command'] = {
          ...current.command!.toJson(),
          'parameters_json': current.command!.parametersJson.replaceFirst(
            '14:30:00',
            '14:30:01',
          ),
        };
        final changed = JournalRecord.fromJson(json);
        expectBlocked(
          evaluate(
            source: snapshot,
            approval: approval,
            target: JournalReadResult.stored(changed),
          ),
          JournalIssue.commandConflict,
        );
      });

      test('existing frozen JSON is never rewritten to make it match', () {
        final current = imported(approval);
        final different = JournalRecord.fromJson({
          ...current.toJson(),
          'command': {
            ...current.command!.toJson(),
            'parameters_json': '${current.command!.parametersJson}\n',
          },
        });
        expect(different.command!.sameRequest(current.command!), isTrue);
        expectBlocked(
          evaluate(
            source: snapshot,
            approval: approval,
            target: JournalReadResult.stored(different),
          ),
          JournalIssue.commandConflict,
        );
        expect(different.command!.parametersJson.endsWith('\n'), isTrue);
      });

      test(
        'same command without matching migration history is not adopted',
        () {
          final current = JournalRecord.absent(journalBinding())
              .prepare(imported(approval).command!);
          expectBlocked(
            evaluate(
              source: snapshot,
              approval: approval,
              target: JournalReadResult.stored(current),
            ),
            JournalIssue.commandConflict,
          );
        },
      );

      for (final field in [
        'source_basename',
        'source_sha256',
        'binding_approval_ref',
      ]) {
        test('pending migration identity conflict in $field is blocked', () {
          final current = imported(approval);
          final metadata = {
            ...current.migration!.toJson(),
            field: switch (field) {
              'source_basename' => 'attendance_other.json',
              'source_sha256' => 'b' * 64,
              _ => 'fictional-other-approval',
            },
          };
          final changed = JournalRecord.fromJson({
            ...current.toJson(),
            'migration': metadata,
          });
          expectBlocked(
            evaluate(
              source: snapshot,
              approval: approval,
              target: JournalReadResult.stored(changed),
            ),
            JournalIssue.commandConflict,
          );
        });
      }

      test(
        'different operation with same key/migration identity is blocked',
        () {
          final current = imported(approval);
          final otherOperation = operation == AttendanceCommandKind.checkIn
              ? AttendanceCommandKind.checkOut
              : AttendanceCommandKind.checkIn;
          final changed = JournalRecord.fromJson({
            ...current.toJson(),
            'command': journalCommand(
              protocol: JournalProtocol.legacyV1,
              operation: otherOperation,
            ).toJson(),
          });
          expectBlocked(
            evaluate(
              source: snapshot,
              approval: approval,
              target: JournalReadResult.stored(changed),
            ),
            JournalIssue.commandConflict,
          );
        },
      );

      for (final compacted in [false, true]) {
        test(
          'completed migration with absent source is no-op (compacted: $compacted)',
          () {
            var current = imported(approval);
            current = current
                .confirm(journalConfirmation(current.command!))
                .markLegacyCleanupComplete(approval.metadata.sourceSha256);
            if (compacted) {
              current = current.compactConfirmed(
                canonicalStateVerified: true,
                confirmationConsumed: true,
              );
              current = current.prepare(
                journalCommand(key: 'fictional-later-v2-key'),
              );
            }
            final original = JournalCodec.encode(current);
            for (final suppliedApproval in <LegacyBindingApproval?>[
              null,
              approval,
            ]) {
              final plan = evaluate(
                source: LegacySourceSnapshot.absent(),
                approval: suppliedApproval,
                target: JournalReadResult.stored(current),
              );
              expect(plan.step, LegacyMigrationStep.noAction);
              expect(plan.existingRecord, same(current));
              expect(plan.importRecord, isNull);
              expect(plan.requiredChecks, isEmpty);
              expect(JournalCodec.encode(current), original);
            }
            expectBlocked(
              evaluate(
                source: snapshot,
                approval: approval,
                target: JournalReadResult.stored(current),
              ),
              JournalIssue.commandConflict,
            );
          },
        );
      }

      test('completed empty tombstone cannot import another source', () {
        var current = imported(approval);
        current = current
            .confirm(journalConfirmation(current.command!))
            .markLegacyCleanupComplete(approval.metadata.sourceSha256)
            .compactConfirmed(
              canonicalStateVerified: true,
              confirmationConsumed: true,
            );
        expectBlocked(
          evaluate(
            source: snapshot,
            approval: approval,
            target: JournalReadResult.stored(current),
          ),
          JournalIssue.commandConflict,
        );
      });

      test(
        'completed metadata cannot hide a conflicting supplied approval',
        () {
          final current = imported(approval)
              .markLegacyCleanupComplete(approval.metadata.sourceSha256);
          expectBlocked(
            evaluate(
              source: LegacySourceSnapshot.absent(),
              approval: approvalFor(
                bytes,
                reference: 'fictional-conflicting-approval',
              ),
              target: JournalReadResult.stored(current),
            ),
            JournalIssue.commandConflict,
          );
        },
      );

      test(
        'blocked pending target is preserved, not unblocked for cleanup',
        () {
          final current = imported(approval)
              .blockRecovery(JournalBlockReason.manualReview);
          final original = JournalCodec.encode(current);
          expectBlocked(
            evaluate(
              source: snapshot,
              approval: approval,
              target: JournalReadResult.stored(current),
            ),
            JournalIssue.illegalTransition,
          );
          expect(JournalCodec.encode(current), original);
        },
      );
    });
  }

  for (final artifact in LegacySourceArtifact.values) {
    for (final sourcePresent in [false, true]) {
      test(
        '$artifact blocks with finalized source present: $sourcePresent',
        () {
          final bytes = legacySource();
          final source = sourcePresent
              ? LegacySourceSnapshot.file(
                  basename: approvalFor(bytes).metadata.sourceBasename,
                  bytes: bytes,
                  artifacts: {artifact},
                )
              : LegacySourceSnapshot.absent(artifacts: {artifact});
          expectBlocked(
            evaluate(source: source, approval: approvalFor(bytes)),
            JournalIssue.unreadable,
          );
        },
      );
    }
  }
  for (final malformed in [
    <int>[],
    utf8.encode('{'),
    utf8.encode(
      utf8
          .decode(legacySource())
          .replaceFirst('"version":1', '"version":1,"version":1'),
    ),
    utf8.encode(
      utf8.decode(legacySource()).replaceFirst('2026-10-17', '2026-02-30'),
    ),
    [255],
  ]) {
    test(
      'malformed source stays blocked with and without approval (${malformed.length})',
      () {
        for (final approval in <LegacyBindingApproval?>[
          null,
          approvalFor(malformed),
        ]) {
          expectBlocked(
            evaluate(source: snapshotOf(malformed), approval: approval),
            JournalIssue.corrupt,
          );
        }
      },
    );
  }
  test('unsupported source version is blocked without repair', () {
    final bytes = utf8.encode(
      utf8.decode(legacySource()).replaceFirst('"version":1', '"version":2'),
    );
    expectBlocked(
      evaluate(source: snapshotOf(bytes), approval: approvalFor(bytes)),
      JournalIssue.unsupportedFormat,
    );
  });
  test('unreadable source is not interpreted as absence', () {
    expectBlocked(
      evaluate(source: LegacySourceSnapshot.unreadable(), approval: null),
      JournalIssue.unreadable,
    );
  });
  for (final issue in JournalIssue.values) {
    test(
      'storage issue $issue prevents all migration without resetting state',
      () {
        final bytes = legacySource();
        expectBlocked(
          evaluate(
            source: snapshotOf(bytes),
            approval: approvalFor(bytes),
            target: JournalReadResult.blocked(issue),
          ),
          issue,
        );
        expectBlocked(
          evaluate(
            source: LegacySourceSnapshot.absent(),
            approval: null,
            target: JournalReadResult.blocked(issue),
          ),
          issue,
        );
      },
    );
  }
  test('stored revision zero is invalid, not an eligible empty target', () {
    final bytes = legacySource();
    expectBlocked(
      evaluate(
        source: snapshotOf(bytes),
        approval: approvalFor(bytes),
        target: JournalReadResult.stored(
          JournalRecord.absent(journalBinding()),
        ),
      ),
      JournalIssue.corrupt,
    );
  });
}
