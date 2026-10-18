import 'package:flutter/services.dart';

import 'android_journal_storage.dart';
import 'android_legacy_migration.dart';
import 'command_journal.dart';
import 'journal_command.dart';
import 'legacy_migration_coordinator.dart';

/// Real isolated composition; not instantiated by the live application.
class AndroidLegacyMigrationBackend implements LegacyMigrationBackend {
  const AndroidLegacyMigrationBackend({
    this.channel = const MethodChannel(AndroidJournalStorage.channelName),
  });
  final MethodChannel channel;
  AndroidLegacyMigration get _native =>
      AndroidLegacyMigration(channel: channel);

  @override
  Future<void> requireIsolatedExecution() => _native.requireIsolatedExecution();
  @override
  LegacyMigrationBackend scoped(void Function() checkValid) =>
      AndroidLegacyMigrationBackend(
        channel: _ContextChannel(channel, checkValid),
      );
  @override
  JournalStorage get storage => AndroidJournalStorage(channel: channel);
  @override
  Future<AndroidLegacySourceInspection> inspect(JournalBinding binding) =>
      _native.inspect(binding);
  @override
  Future<void> cleanup(
    JournalBinding binding,
    List<int> record,
    AndroidLegacySourceInspection source,
  ) => _native.cleanup(binding, record, source);
  @override
  Future<void> verifyCompleted(JournalBinding binding, List<int> record) =>
      _native.verifyCompleted(binding, record);
}

/// Guards internal read/recovery/retry calls without changing general journal
/// storage or the live controller. Context validity is checked even on errors.
final class _ContextChannel extends MethodChannel {
  _ContextChannel(this.delegate, this.check) : super(delegate.name);
  final MethodChannel delegate;
  final void Function() check;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    check();
    try {
      return await delegate.invokeMethod<T>(method, arguments);
    } finally {
      check();
    }
  }
}
