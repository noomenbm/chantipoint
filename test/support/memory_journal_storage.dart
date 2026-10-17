import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';

enum JournalFault { beforeRead, afterRead, beforeWrite, afterWrite, readback }

/// TEST SIMULATION ONLY. These bytes are NOT encrypted and are NOT durable.
/// Sharing this object simulates restart, never actual Android disk recovery.
class MemoryJournalDisk {
  final Map<String, List<int>> _records = {};
  final Map<String, JournalIssue> readIssues = {};
  final List<JournalFault> _faults = [];
  int writes = 0;
  void failNext(JournalFault point) => _faults.add(point);
  bool _fails(JournalFault point) {
    if (_faults.isEmpty || _faults.first != point) return false;
    _faults.removeAt(0);
    return true;
  }

  void inject(JournalBinding binding, List<int> bytes) =>
      _records[binding.storageIdentity] = List.of(bytes);
  List<int>? snapshot(JournalBinding binding) {
    final bytes = _records[binding.storageIdentity];
    return bytes == null ? null : List.of(bytes);
  }
}

class MemoryJournalStorage implements JournalStorage {
  MemoryJournalStorage(this.disk);
  final MemoryJournalDisk disk;

  @override
  Future<JournalStorageRead> read(JournalBinding binding) async {
    if (disk._fails(JournalFault.beforeRead)) {
      return const JournalStorageRead.failure(JournalIssue.storageFailure);
    }
    final problem = disk.readIssues[binding.storageIdentity];
    if (problem != null) return JournalStorageRead.failure(problem);
    final bytes = disk.snapshot(binding);
    if (disk._fails(JournalFault.afterRead)) {
      return const JournalStorageRead.failure(JournalIssue.storageFailure);
    }
    return bytes == null
        ? const JournalStorageRead.absent()
        : JournalStorageRead.bytes(bytes);
  }

  @override
  Future<JournalIssue?> compareAndSwap({
    required JournalBinding binding,
    required int expectedRevision,
    required String? expectedKey,
    required List<int> replacement,
  }) async {
    // No await between inspection and replacement: a deterministic atomic CAS
    // shared by every simulated backend instance, not an Android guarantee.
    if (disk._fails(JournalFault.beforeWrite)) {
      return JournalIssue.storageFailure;
    }
    final issue = disk.readIssues[binding.storageIdentity];
    if (issue != null) return issue;
    final current = disk.snapshot(binding);
    final decoded = current == null
        ? const JournalReadResult.absent()
        : JournalCodec.decode(current, binding);
    if (decoded.issue != null) return decoded.issue;
    if ((decoded.record?.revision ?? 0) != expectedRevision ||
        decoded.record?.command?.key != expectedKey) {
      return JournalIssue.revisionConflict;
    }
    final next = JournalCodec.decode(replacement, binding);
    if (next.issue != null) return next.issue;
    if (next.record?.revision != expectedRevision + 1) {
      return JournalIssue.revisionConflict;
    }
    disk.inject(binding, replacement);
    disk.writes++;
    if (disk._fails(JournalFault.afterWrite) ||
        disk._fails(JournalFault.readback)) {
      return JournalIssue.storageFailure;
    }
    final readback = disk.snapshot(binding)!;
    if (readback.length != replacement.length ||
        Iterable<int>.generate(readback.length)
            .any((i) => readback[i] != replacement[i])) {
      return JournalIssue.storageFailure;
    }
    return null;
  }
}
