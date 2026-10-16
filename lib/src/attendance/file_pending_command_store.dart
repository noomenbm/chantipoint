import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'attendance_models.dart';
import 'attendance_repository.dart';

/// One flushed intent per employee, persisted before any RPC is sent.
/// Temporary files are never treated as sent commands; only renamed records are.
class FilePendingCommandStore implements PendingCommandStore {
  FilePendingCommandStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<File> _file(String owner) async {
    final root = await _directory();
    final name = base64Url.encode(utf8.encode(owner)).replaceAll('=', '');
    return File('${root.path}${Platform.pathSeparator}attendance_$name.json');
  }

  Future<AttendanceCommand?> _read(File file, String owner) async {
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['owner'] != owner) {
      throw const FormatException('Wrong journal owner');
    }
    return AttendanceCommand.fromJson(json);
  }

  @override
  Future<AttendanceCommand?> read(String owner) => _serial(() async {
    try {
      return await _read(await _file(owner), owner);
    } catch (_) {
      throw const AttendanceFailure(AttendanceFailureKind.storage);
    }
  });

  @override
  Future<void> save(String owner, AttendanceCommand command) =>
      _serial(() async {
        try {
          final file = await _file(owner);
          final existing = await _read(file, owner);
          if (existing != null) {
            if (jsonEncode(existing.toJson()) == jsonEncode(command.toJson())) {
              return;
            }
            throw const FormatException('Unresolved journal already exists');
          }
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(
            jsonEncode({...command.toJson(), 'owner': owner}),
            flush: true,
          );
          await temporary.rename(file.path);
        } catch (_) {
          throw const AttendanceFailure(AttendanceFailureKind.storage);
        }
      });

  @override
  Future<void> clear(String owner, String expectedKey) => _serial(() async {
    try {
      final file = await _file(owner);
      final current = await _read(file, owner);
      if (current != null && current.key == expectedKey) await file.delete();
    } catch (_) {
      throw const AttendanceFailure(AttendanceFailureKind.storage);
    }
  });
}
