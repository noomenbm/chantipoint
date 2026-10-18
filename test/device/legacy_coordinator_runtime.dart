// Fictional isolated coordinator composition only. No live writer or network.
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/android_legacy_migration.dart';
import 'package:chantipoint/src/attendance/journal/android_legacy_migration_coordinator.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/journal/legacy_journal_import.dart';
import 'package:chantipoint/src/attendance/journal/legacy_migration_coordinator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../support/fictional_migration_context.dart';
import '../support/journal_fixtures.dart';
import '../support/legacy_migration_fixtures.dart';
import 'legacy_migration_runtime.dart' show RuntimeCheck;

const _control = MethodChannel('chantipoint/journal_test_control');
const _native = AndroidLegacyMigration();
const _storage = AndroidJournalStorage();
void _require(bool value) {
  if (!value) throw StateError('Coordinator runtime assertion failed.');
}

Future<Object?> _fixture(
  String method,
  JournalBinding b, [
  Map<String, Object?> extra = const {},
]) => _control.invokeMethod<Object?>(method, {'binding': b.toJson(), ...extra});
Future<void> _write(LegacyBindingApproval approval) async {
  await _fixture('legacyFixture', approval.binding, {
    'operation': 'write',
    'suffix': '',
    'bytes': Uint8List.fromList(approval.approvedSource),
  });
}

Future<void> _original(JournalRecord expected) async {
  final read = await _storage.read(expected.binding);
  _require(
    read.issue == null && listEquals(read.bytes, JournalCodec.encode(expected)),
  );
  final counts =
      await _fixture('sourceDescriptorCounts', expected.binding) as Map;
  _require(counts['source'] == 0 && counts['artifacts'] == 0);
}

LegacyMigrationCoordinator _coordinator({
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
  LegacyMigrationBackend backend = const AndroidLegacyMigrationBackend(),
}) => LegacyMigrationCoordinator(
  backend: backend,
  contexts: FictionalMigrationContexts(
    (b) => migrationApproval(b, operation: operation),
  ),
);
JournalRecord _complete(
  int slot, {
  AttendanceCommandKind operation = AttendanceCommandKind.checkIn,
  bool confirmed = false,
}) {
  final b = migrationBinding(slot);
  return migrationRecord(
    b,
    operation: operation,
    confirmed: confirmed,
  ).markLegacyCleanupComplete(
    migrationApproval(b, operation: operation).metadata.sourceSha256,
  );
}

Future<void> coordinatorFreshChecks(RuntimeCheck run) async {
  await run(
    'coordinator native validation preflight and normal-context rejection',
    () async {
      await _native.requireIsolatedExecution();
      _require(
        await _fixture('normalPreflightRejected', migrationBinding(10)) == true,
      );
    },
  );
  for (final entry in [
    (10, AttendanceCommandKind.checkIn),
    (11, AttendanceCommandKind.checkOut),
  ]) {
    await run(
      'coordinator complete original ${entry.$2.name} with uncertain phase retained',
      () async {
        final b = migrationBinding(entry.$1);
        await _write(migrationApproval(b, operation: entry.$2));
        final result = await _coordinator(operation: entry.$2).migrate(b);
        _require(result.outcome == LegacyMigrationOutcome.completed);
        await _original(_complete(entry.$1, operation: entry.$2));
        _require((await _native.inspect(b)).source.bytes == null);
        // Completed metadata is verification-only, never pending-cleanup authority.
        await _native.verifyCompleted(b, JournalCodec.encode(result.record!));
        try {
          await _native.cleanup(
            b,
            JournalCodec.encode(result.record!),
            await _native.inspect(b),
          );
          throw StateError('Completed cleanup unexpectedly accepted.');
        } on JournalException catch (error) {
          _require(error.issue == JournalIssue.illegalTransition);
        }
      },
    );
  }
  for (final entry in [(12, 'target_sync'), (13, 'source_sync')]) {
    await run(
      'coordinator staged restart at ${entry.$2} leaves original pending import',
      () async {
        final b = migrationBinding(entry.$1);
        await _write(migrationApproval(b));
        await _fixture('migrationFault', b, {'stage': entry.$2});
        final result = await _coordinator().migrate(b);
        _require(result.outcome == LegacyMigrationOutcome.retryable);
        await _original(migrationRecord(b));
        _require(
          ((await _native.inspect(b)).source.bytes == null) == (entry.$1 == 13),
        );
      },
    );
  }
  await run('coordinator reported committed completion failure needs fresh completed barrier', () async {
    final b = migrationBinding(14);
    await _write(migrationApproval(b));
    await _fixture('migrationFault', b, {'stage': 'completed_sync'});
    final result = await _coordinator(
      backend: _ReportedCompletionFailure(
        const AndroidLegacyMigrationBackend(),
      ),
    ).migrate(b);
    _require(result.outcome == LegacyMigrationOutcome.retryable);
    await _original(_complete(14));
    // A readable completed record is retained, but not reported durable here.
  });
  await run(
    'coordinator retains independently validated fictional confirmation',
    () async {
      final b = migrationBinding(15);
      final approval = migrationApproval(b);
      await _write(approval);
      final parsed = LegacyJournalImport.prepare(
        approval.approvedSource,
        approval: approval,
      );
      const journal = CommandJournal(_storage);
      final imported = await journal.importLegacy(
        b,
        parsed.command!,
        parsed.metadata!,
        expectedRevision: 0,
        expectedKey: null,
      );
      _require(imported.issue == null);
      final confirmed = await journal.confirm(
        b,
        journalConfirmation(parsed.command!, replay: true),
        expectedRevision: imported.record!.revision,
        expectedKey: parsed.command!.key,
      );
      _require(confirmed.issue == null);
      _require(
        (await _coordinator().migrate(b)).outcome ==
            LegacyMigrationOutcome.completed,
      );
      await _original(_complete(15, confirmed: true));
    },
  );
  await run(
    'coordinator completed source reappearance stays blocked without deletion',
    () async {
      final b = migrationBinding(10);
      await _write(migrationApproval(b));
      _require(
        (await _coordinator().migrate(b)).outcome ==
            LegacyMigrationOutcome.blocked,
      );
      await _original(_complete(10));
      _require((await _native.inspect(b)).source.bytes != null);
      await _fixture('legacyFixture', b, {'operation': 'delete', 'suffix': ''});
    },
  );
}

Future<void> coordinatorRestartChecks(RuntimeCheck run) async {
  for (final slot in [12, 13, 14]) {
    await run(
      'coordinator force-stop staged restart complete original record $slot',
      () async {
        final b = migrationBinding(slot);
        await _original(slot == 14 ? _complete(slot) : migrationRecord(b));
        // A NEW provider reestablishes fictional approval/assignment/fencing.
        final result = await _coordinator().migrate(b);
        _require(
          result.outcome ==
              (slot == 14
                  ? LegacyMigrationOutcome.noAction
                  : LegacyMigrationOutcome.completed),
        );
        await _original(_complete(slot));
        _require((await _native.inspect(b)).source.bytes == null);
      },
    );
  }
}

// Test-only reported failure AFTER real native completion CAS has settled.
// It does not simulate a kernel fsync failure or cancel submitted native work.
class _ReportedCompletionFailure implements LegacyMigrationBackend {
  _ReportedCompletionFailure(this.delegate);
  final LegacyMigrationBackend delegate;
  @override
  Future<void> requireIsolatedExecution() =>
      delegate.requireIsolatedExecution();
  @override
  LegacyMigrationBackend scoped(void Function() checkValid) =>
      _ReportedCompletionFailure(delegate.scoped(checkValid));
  @override
  JournalStorage get storage => _CompletionFailureStorage(delegate.storage);
  @override
  Future<AndroidLegacySourceInspection> inspect(JournalBinding b) =>
      delegate.inspect(b);
  @override
  Future<void> cleanup(
    JournalBinding b,
    List<int> record,
    AndroidLegacySourceInspection source,
  ) => delegate.cleanup(b, record, source);
  @override
  Future<void> verifyCompleted(JournalBinding b, List<int> record) =>
      delegate.verifyCompleted(b, record);
}

class _CompletionFailureStorage implements JournalStorage {
  _CompletionFailureStorage(this.delegate);
  final JournalStorage delegate;
  @override
  Future<JournalStorageRead> read(JournalBinding b) => delegate.read(b);
  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    final issue = await delegate.compareAndSwap(
      binding: binding,
      expectedRevision: expectedRevision,
      expectedKey: expectedKey,
      replacement: replacement,
    );
    if (issue != null) return issue;
    final record = JournalCodec.decode(replacement, binding).record!;
    return record.migration!.plaintextCleanupComplete
        ? JournalIssue.synchronizationFailure
        : null;
  }
}
