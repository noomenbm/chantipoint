// Fictional host simulation ONLY: RAM is not encrypted/durable Android storage;
// issuer/contexts establish no production auth, global ownership or fencing.
import 'package:chantipoint/src/attendance/attendance_models.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';

import 'journal_fixtures.dart';
import 'memory_journal_storage.dart';

class FictionalAttendanceIssuer {
  FictionalAttendanceIssuer(this.binding);
  JournalBinding binding;
  int generation = 1;
  void relogin({JournalBinding? asBinding}) {
    binding = asBinding ?? binding;
    generation++;
  }

  FictionalAttendanceContext context() => FictionalAttendanceContext(this);
}

class FictionalAttendanceContext implements AttendanceOperationContext {
  FictionalAttendanceContext(this.issuer)
    : identity = AttendanceOperationIdentity(issuer.binding, issuer.generation);
  final FictionalAttendanceIssuer issuer;
  @override
  final AttendanceOperationIdentity identity;
  bool callerDisposed = false;
  bool released = false;
  int releaseCalls = 0;
  Future<void> Function()? onRelease;
  @override
  bool get isCurrent =>
      !callerDisposed &&
      issuer.generation == identity.generation &&
      issuer.binding.matches(identity.binding);
  @override
  Future<void> release() async {
    releaseCalls++;
    await onRelease?.call();
    released = true;
  }
}

class FictionalOperationStorage implements JournalStorage {
  FictionalOperationStorage(this.disk, this.events)
    : delegate = MemoryJournalStorage(disk);
  final MemoryJournalDisk disk;
  final MemoryJournalStorage delegate;
  final List<String> events;
  final faults = <JournalPhase, JournalFault>{};
  int reads = 0;
  final attempts = <JournalRecord>[];
  Future<void> Function()? afterRead;
  Future<void> Function(JournalRecord)? beforeCas;
  Future<void> Function(JournalRecord)? afterCas;
  @override
  Future<JournalStorageRead> read(JournalBinding binding) async {
    reads++;
    events.add('read');
    final result = await delegate.read(binding);
    await afterRead?.call();
    return result;
  }

  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    final record = JournalCodec.decode(replacement, binding).record!;
    attempts.add(record);
    events.add('cas:${record.phase.name}');
    await beforeCas?.call(record);
    final fault = faults.remove(record.phase);
    if (fault != null) disk.failNext(fault);
    final issue = await delegate.compareAndSwap(
      binding: binding,
      expectedRevision: expectedRevision,
      expectedKey: expectedKey,
      replacement: replacement,
    );
    await afterCas?.call(record);
    return issue;
  }
}

class FictionalAttendanceTransport implements AttendanceOperationTransport {
  FictionalAttendanceTransport(this.events);
  final List<String> events;
  final calls =
      <
        ({
          AttendanceOperationIdentity identity,
          JournalCommand command,
          bool replayOnly,
        })
      >[];
  Future<AttendanceTransportReply> Function(JournalCommand, bool)? onDispatch;
  @override
  Future<AttendanceTransportReply> dispatch(
    AttendanceOperationIdentity identity,
    JournalCommand command, {
    required bool replayOnly,
  }) async {
    events.add(replayOnly ? 'dispatch:replay' : 'dispatch:write');
    calls.add((identity: identity, command: command, replayOnly: replayOnly));
    return await onDispatch?.call(command, replayOnly) ??
        AttendanceTransportReply.acknowledged(
          JournalJson.encode(journalReceipt(command, replay: replayOnly)),
        );
  }
}

class FictionalCanonicalReader implements AttendanceCanonicalReader {
  FictionalCanonicalReader(this.events);
  final List<String> events;
  final calls = <({AttendanceOperationIdentity identity, String sessionId})>[];
  WorkSession? result = journalSession();
  Future<WorkSession?> Function()? onRead;
  @override
  Future<WorkSession?> readSession(
    AttendanceOperationIdentity identity,
    String sessionId,
  ) async {
    events.add('canonical');
    calls.add((identity: identity, sessionId: sessionId));
    return onRead == null ? result : await onRead!();
  }
}

class FictionalAttendanceOperations {
  FictionalAttendanceOperations({JournalBinding? binding})
    : binding = binding ?? journalBinding();
  final JournalBinding binding;
  final events = <String>[];
  final disk = MemoryJournalDisk();
  late final issuer = FictionalAttendanceIssuer(binding);
  late final storage = FictionalOperationStorage(disk, events);
  late final transport = FictionalAttendanceTransport(events);
  late final canonical = FictionalCanonicalReader(events);
  late final coordinator = newCoordinator();
  AttendanceOperationCoordinator newCoordinator() =>
      AttendanceOperationCoordinator(
        storage: storage,
        transport: transport,
        canonical: canonical,
      );
  JournalRecord? get record {
    final bytes = disk.snapshot(binding);
    return bytes == null ? null : JournalCodec.decode(bytes, binding).record;
  }

  void inject(JournalRecord record) =>
      disk.inject(record.binding, JournalCodec.encode(record));
}
