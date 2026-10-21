// Fictional host simulations only: this RAM store is NOT secure/durable storage.
import 'dart:async';
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_operation_coordinator.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_verifier.dart';
import 'package:chantipoint/src/attendance/notes/session_note_coordinator.dart';
import 'package:chantipoint/src/attendance/notes/session_note_ports.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:chantipoint/src/attendance/supabase_attendance_operation_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fake_attendance_operation_ports.dart';
import 'fake_attendance_request_authority.dart';
import 'journal_fixtures.dart';
import 'memory_journal_storage.dart';

// Exact-byte HOST SIMULATION, not native sync or power-loss evidence.
class _NoteAttendanceVerifier implements JournalVerifier {
  _NoteAttendanceVerifier(this.disk);
  final MemoryJournalDisk disk;
  @override
  Future<JournalIssue?> verify(
    JournalBinding binding,
    List<int> expectedRecord,
  ) async {
    final actual = disk.snapshot(binding);
    return actual != null && jsonEncode(actual) == jsonEncode(expectedRecord)
        ? null
        : JournalIssue.storageFailure;
  }
}

Map<String, dynamic> noteReceiptJson(
  SessionNoteCommand command, {
  String? reason,
}) => {
  'note_contract_version': 1,
  'operation_key': command.key,
  'employee_profile_id': command.identity.binding.profileId,
  'company_id': command.identity.binding.companyId,
  'session_id': command.sessionId,
  'request_fingerprint': 'a' * 64,
  'outcome': reason == null ? 'applied' : 'not_applied',
  'reason': reason,
  'settled_at': '2026-10-21T14:15:16.123456+00:00',
};

class NoteMemoryDisk {
  final records = <String, List<int>>{};
  final marked = <String>{};
}

class NoteMemoryStorage implements SessionNoteStorage {
  NoteMemoryStorage(this.disk);
  final NoteMemoryDisk disk;
  final events = <String>[];
  String? fault;
  SessionNotePhase? faultPhase;
  Future<void> Function(SessionNoteRecord)? beforeCas;
  Future<void> Function(SessionNoteRecord)? afterCas;
  Future<void> Function(SessionNoteRecord)? onVerify;
  void fail(String stage, SessionNotePhase phase) {
    fault = stage;
    faultPhase = phase;
  }

  void _check(String stage, SessionNoteRecord? record) {
    if (fault == stage && (record == null || faultPhase == record.phase)) {
      fault = null;
      throw const JournalException(JournalIssue.storageFailure);
    }
  }

  @override
  Future<SessionNoteRecord?> read(JournalBinding binding) async {
    _check('read', null);
    final bytes = disk.records[binding.storageIdentity];
    if (bytes == null && disk.marked.contains(binding.storageIdentity)) {
      throw const JournalException(JournalIssue.unreadable);
    }
    return bytes == null ? null : SessionNoteRecord.decode(bytes, binding);
  }

  @override
  Future<void> compareAndSwap(
    SessionNoteRecord before,
    SessionNoteRecord next,
  ) async {
    await beforeCas?.call(next);
    _check('before', next);
    final actual = await read(before.binding);
    if ((actual?.revision ?? 0) != before.revision ||
        actual?.command?.key != before.command?.key ||
        next.revision != before.revision + 1) {
      throw const JournalException(JournalIssue.revisionConflict);
    }
    disk.marked.add(before.binding.storageIdentity);
    disk.records[before.binding.storageIdentity] = List.of(next.bytes);
    events.add('write:${next.phase.name}');
    await afterCas?.call(next);
    _check('after', next);
  }

  @override
  Future<void> verify(SessionNoteRecord record) async {
    _check('verify', record);
    await onVerify?.call(record);
    final actual = await read(record.binding);
    if (actual == null ||
        jsonEncode(actual.toJson()) != jsonEncode(record.toJson())) {
      throw const JournalException(JournalIssue.revisionConflict);
    }
    events.add('verify:${record.phase.name}');
  }
}

class SessionNoteFixture {
  final operations = FictionalAttendanceOperations();
  final disk = NoteMemoryDisk();
  late final store = NoteMemoryStorage(disk);
  late final authority = FictionalRequestAuthority(operations.issuer);
  final contexts = <FictionalAttendanceContext>[];
  final requests = <http.Request>[];
  final server = <String, ({String parameters, String receipt})>{};
  final serverNotes = <String, String?>{};
  bool loseBeforeCommit = false, loseAfterCommit = false;
  Future<void> Function(http.Request)? beforeResponse;
  http.Response Function(http.Request, String)? response;
  late final client = MockClient((request) async {
    requests.add(request);
    if (loseBeforeCommit) {
      loseBeforeCommit = false;
      throw StateError('fictional transport failure');
    }
    final p = jsonDecode(request.body) as Map<String, dynamic>;
    final key = p['p_operation_key'] as String;
    final replay = p['p_replay_only'] == true;
    final frozen = jsonEncode({...p, 'p_replay_only': false});
    final existing = server[key];
    if (existing != null && existing.parameters != frozen) {
      return http.Response('private fixture conflict', 409);
    }
    final command = SessionNoteCommand.fromJson(operations.binding, {
      'captured_generation': 1,
      'parameters_json': frozen,
    });
    final result =
        existing?.receipt ??
        jsonEncode(
          noteReceiptJson(command, reason: replay ? 'replay_fenced' : null),
        );
    if (existing == null) {
      server[key] = (parameters: frozen, receipt: result);
      if (!replay) serverNotes[command.sessionId] = command.text;
    }
    await beforeResponse?.call(request);
    if (loseAfterCommit) {
      loseAfterCommit = false;
      throw StateError('fictional lost response');
    }
    return response?.call(request, result) ?? http.Response(result, 200);
  });
  late final transport = SupabaseAttendanceOperationTransport(
    authority: authority,
    client: client,
  );
  late final coordinator = newCoordinator();
  SessionNoteCoordinator newCoordinator({NoteMemoryStorage? storage}) =>
      SessionNoteCoordinator(
        storage: storage ?? store,
        transport: transport,
        canonical: operations.canonical,
        attendance: AttendanceOperationCoordinator(
          storage: operations.storage,
          transport: operations.transport,
          canonical: operations.canonical,
          verifier: _NoteAttendanceVerifier(operations.disk),
        ),
        issueContext: context,
      );
  FictionalAttendanceContext context() {
    final ctx = operations.issuer.context();
    contexts.add(ctx);
    return ctx;
  }

  SessionNoteCommand command({
    String key = 'fictional-session-note-001',
    String? text = '  Réparation é terminée.  ',
    String session = journalSessionId,
    CheckoutNoteIntent? intent,
  }) => SessionNoteCommand.capture(
    identity: AttendanceOperationIdentity(
      operations.issuer.binding,
      operations.issuer.generation,
    ),
    sessionId: session,
    operationKey: key,
    note:
        intent ??
        (text == null
            ? const CheckoutNoteIntent.clear()
            : CheckoutNoteIntent.replace(text)),
  );
  Future<NoteOperationResult> save([SessionNoteCommand? command]) =>
      coordinator.save(context(), command ?? this.command());
  SessionNoteRecord? get record {
    final bytes = disk.records[operations.binding.storageIdentity];
    return bytes == null
        ? null
        : SessionNoteRecord.decode(bytes, operations.binding);
  }

  void close() => client.close();
}
