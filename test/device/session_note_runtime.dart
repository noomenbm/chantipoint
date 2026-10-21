// Fictional native storage/MethodChannel checks. No HTTP, Supabase or device GPS.
import 'dart:convert';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/notes/android_session_note_storage.dart';
import 'package:chantipoint/src/attendance/notes/session_note_record.dart';
import 'package:flutter/services.dart';

import '../support/journal_fixtures.dart';
import '../support/session_note_fixture.dart' show noteReceiptJson;

const _control = MethodChannel('chantipoint/journal_test_control');
const _notes = AndroidSessionNoteStorage();
JournalBinding _binding(String name) =>
    journalBinding(environment: 'note-runtime-$name');
SessionNoteRecord _pending(String name) {
  final binding = _binding(name);
  return SessionNoteRecord.absent(binding).prepare(
    SessionNoteCommand.capture(
      identity: AttendanceOperationIdentity(binding, 17),
      sessionId: journalSessionId,
      operationKey: 'fictional-runtime-note-$name',
      note: const CheckoutNoteIntent.replace('  Réparation é terminée.  '),
    ),
  );
}

Future<Object?> _fixture(
  String method,
  JournalBinding binding, [
  Map<String, Object?> extra = const {},
]) => _control.invokeMethod(method, {'binding': binding.toJson(), ...extra});
void _require(bool value) {
  if (!value) throw StateError('Fictional note runtime assertion failed');
}

Future<SessionNoteRecord> _seed(String name, {bool terminal = false}) async {
  var record = _pending(name);
  await _notes.compareAndSwap(SessionNoteRecord.absent(record.binding), record);
  if (terminal) {
    final next = record.confirm(
      SessionNoteReceipt.parse(
        jsonEncode(noteReceiptJson(record.command!)),
        record.command!,
      ),
    );
    await _notes.compareAndSwap(record, next);
    record = next;
  }
  await _notes.verify(record);
  return record;
}

Future<void> _blocked(Future<Object?> Function() work) async {
  try {
    await work();
  } on JournalException {
    return;
  } on PlatformException {
    return;
  }
  throw StateError('Expected blocked fictional note operation');
}

typedef RuntimeCheck = Future<void> Function(String, Future<void> Function());

Future<void> noteFreshChecks(RuntimeCheck run) async {
  await run(
    'note encrypted pending, full readback and no-backup namespace',
    () async {
      final record = await _seed('pending');
      _require(
        utf8.decode((await _notes.read(record.binding))!.bytes) ==
            utf8.decode(record.bytes),
      );
      final location = await _fixture('noteAtRest', record.binding, {
        'note': record.command!.text,
      }) as Map;
      _require(
        location['no_backup'] == true &&
            location['separate_directory'] == true &&
            location['plaintext_found'] == false,
      );
    },
  );
  await run('note terminal raw receipt persists separately', () async {
    await _seed('terminal', terminal: true);
  });
  await run('note checkout reservation persists', () async {
    final b = _binding('checkout');
    final record = SessionNoteRecord.absent(b).reserveCheckout(
      SessionNoteCheckout(
        sessionId: journalSessionId,
        key: journalKey,
        generation: 17,
        commandSha256: 'b' * 64,
      ),
    );
    await _notes.compareAndSwap(SessionNoteRecord.absent(b), record);
    await _notes.verify(record);
  });
  await run(
    'note native CAS rejects stale overwrite and immutable change',
    () async {
      final record = await _seed('cas');
      await _blocked(
        () => _notes.compareAndSwap(
          SessionNoteRecord.absent(record.binding),
          record,
        ),
      );
      final changed = SessionNoteRecord.absent(record.binding).prepare(
        SessionNoteCommand.capture(
          identity: record.command!.identity,
          sessionId: journalOtherId,
          operationKey: record.command!.key,
          note: const CheckoutNoteIntent.replace('Changed command'),
        ),
      );
      const channel = MethodChannel(AndroidSessionNoteStorage.channelName);
      final invalid = {...changed.toJson(), 'revision': 2};
      await _blocked(
        () => channel.invokeMethod('compareAndSwap', {
          'api_version': 1,
          'binding': record.binding.toJson(),
          'expected_revision': 1,
          'expected_key': record.command!.key,
          'replacement': Uint8List.fromList(utf8.encode(jsonEncode(invalid))),
        }),
      );
      await _notes.verify(record);
    },
  );
  for (final stage in [
    'note_after_finish',
    'note_readback',
    'record_file_sync',
    'record_directory_sync',
    'record_readback',
  ]) {
    await run(
      'note injected $stage retains complete recoverable record',
      () async {
        final name = 'fault-$stage';
        final record = await _seed(name);
        await _fixture('noteFault', record.binding, {'stage': stage});
        if (stage.startsWith('note_')) {
          final terminal = record.confirm(
            SessionNoteReceipt.parse(
              jsonEncode(noteReceiptJson(record.command!)),
              record.command!,
            ),
          );
          await _blocked(() => _notes.compareAndSwap(record, terminal));
          await _notes.verify(terminal);
        } else {
          await _blocked(() => _notes.verify(record));
          await _notes.verify(record);
        }
      },
    );
  }
  await run(
    'note first initialization failure blocks silent empty reinitialization',
    () async {
      final record = _pending('init-failure');
      await _fixture('noteFault', record.binding, {
        'stage': 'note_before_write',
      });
      await _blocked(
        () => _notes.compareAndSwap(
          SessionNoteRecord.absent(record.binding),
          record,
        ),
      );
      await _blocked(() => _notes.read(record.binding));
    },
  );
  await run('note tamper blocks without deleting ciphertext', () async {
    final record = await _seed('tamper');
    await _fixture('noteTamper', record.binding);
    final before = await _fixture('noteSnapshot', record.binding);
    await _blocked(() => _notes.read(record.binding));
    _require(before == await _fixture('noteSnapshot', record.binding));
  });
  await run(
    'note interrupted AtomicFile write retains ambiguous artifacts',
    () async {
      final record = await _seed('interrupted');
      await _fixture('noteInterruptedWrite', record.binding);
      final before = await _fixture('noteSnapshot', record.binding);
      await _blocked(() => _notes.read(record.binding));
      _require(before == await _fixture('noteSnapshot', record.binding));
    },
  );
  await run('note missing key fails closed and preserves files', () async {
    final record = await _seed('missing-key');
    await _fixture('noteDeleteKey', record.binding);
    final before = await _fixture('noteSnapshot', record.binding);
    await _blocked(() => _notes.read(record.binding));
    _require(before == await _fixture('noteSnapshot', record.binding));
  });
  await run(
    'note removed ciphertext with retained key cannot become absence',
    () async {
      final record = await _seed('missing-file');
      await _fixture('noteRemoveBase', record.binding);
      await _blocked(() => _notes.read(record.binding));
      await _blocked(
        () => _notes.compareAndSwap(
          SessionNoteRecord.absent(record.binding),
          record,
        ),
      );
    },
  );
  await run('note schema cannot enter attendance journal channel', () async {
    final record = _pending('cross-schema');
    const channel = MethodChannel(AndroidJournalStorage.channelName);
    await _blocked(
      () => channel.invokeMethod('compareAndSwap', {
        'api_version': 1,
        'binding': record.binding.toJson(),
        'expected_revision': 0,
        'expected_key': null,
        'replacement': Uint8List.fromList(record.bytes),
      }),
    );
    _require(
      (await const AndroidJournalStorage().read(record.binding)).bytes == null,
    );
  });
}

Future<void> noteRestartChecks(RuntimeCheck run) async {
  for (final terminal in [false, true]) {
    final name = terminal ? 'terminal' : 'pending';
    await run(
      'note $name restart matches COMPLETE original command/binding/generation/receipt',
      () async {
        var expected = _pending(name);
        if (terminal) {
          expected = expected.confirm(
            SessionNoteReceipt.parse(
              jsonEncode(noteReceiptJson(expected.command!)),
              expected.command!,
            ),
          );
        }
        final actual = (await _notes.read(expected.binding))!;
        _require(utf8.decode(actual.bytes) == utf8.decode(expected.bytes));
        await _notes.verify(expected);
      },
    );
  }
  await run('note checkout ownership survives force stop', () async {
    final b = _binding('checkout');
    final expected = SessionNoteRecord.absent(b).reserveCheckout(
      SessionNoteCheckout(
        sessionId: journalSessionId,
        key: journalKey,
        generation: 17,
        commandSha256: 'b' * 64,
      ),
    );
    _require(
      utf8.decode((await _notes.read(b))!.bytes) == utf8.decode(expected.bytes),
    );
    await _notes.verify(expected);
  });
  for (final name in [
    'interrupted',
    'missing-key',
    'missing-file',
    'init-failure',
  ]) {
    await run('note $name restart remains blocked without cleanup', () async {
      await _blocked(() => _notes.read(_binding(name)));
    });
  }
}
