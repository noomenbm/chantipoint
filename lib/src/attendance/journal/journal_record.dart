import 'journal_command.dart';
import 'journal_json.dart';

enum JournalPhase {
  empty,
  prepared,
  mayHaveSent,
  uncertain,
  confirmed,
  blocked,
}

extension JournalPhaseName on JournalPhase {
  String get wire => this == JournalPhase.mayHaveSent ? 'may_have_sent' : name;
}

enum JournalBlockReason {
  hashConflict,
  serverRejected,
  authorizationRequired,
  manualReview,
}

class JournalBlock {
  const JournalBlock(this.reason, this.previousPhase);
  final JournalBlockReason reason;
  final JournalPhase previousPhase;
  Map<String, dynamic> toJson() => {
    'code': reason.name,
    'previous_phase': previousPhase.wire,
  };
  factory JournalBlock.fromJson(Map<String, dynamic> json) {
    journalFields(json, {'code', 'previous_phase'});
    return JournalBlock(
      journalEnum(json['code'], JournalBlockReason.values),
      _phase(json['previous_phase']),
    );
  }
}

class JournalMigration {
  JournalMigration({
    required String sourceBasename,
    required String sourceSha256,
    required String legacyOwner,
    required String bindingApprovalRef,
    this.plaintextCleanupComplete = false,
  }) : sourceBasename = journalText(sourceBasename),
       sourceSha256 = journalText(sourceSha256, max: 64),
       legacyOwner = journalText(legacyOwner),
       bindingApprovalRef = journalText(bindingApprovalRef) {
    if (!RegExp(r'^attendance_[A-Za-z0-9_-]+\.json$')
            .hasMatch(sourceBasename) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceSha256)) {
      invalidJournal();
    }
  }
  final String sourceBasename, sourceSha256, legacyOwner, bindingApprovalRef;
  final bool plaintextCleanupComplete;
  Map<String, dynamic> toJson() => {
    'source_basename': sourceBasename,
    'source_sha256': sourceSha256,
    'legacy_owner': legacyOwner,
    'binding_approval_ref': bindingApprovalRef,
    'plaintext_cleanup': plaintextCleanupComplete ? 'complete' : 'pending',
  };
  factory JournalMigration.fromJson(Map<String, dynamic> json) {
    journalFields(json, {
      'source_basename',
      'source_sha256',
      'legacy_owner',
      'binding_approval_ref',
      'plaintext_cleanup',
    });
    if (!const {'pending', 'complete'}.contains(json['plaintext_cleanup'])) {
      invalidJournal();
    }
    return JournalMigration(
      sourceBasename: journalText(json['source_basename']),
      sourceSha256: journalText(json['source_sha256']),
      legacyOwner: journalText(json['legacy_owner']),
      bindingApprovalRef: journalText(json['binding_approval_ref']),
      plaintextCleanupComplete: json['plaintext_cleanup'] == 'complete',
    );
  }
  JournalMigration completed() => JournalMigration(
    sourceBasename: sourceBasename,
    sourceSha256: sourceSha256,
    legacyOwner: legacyOwner,
    bindingApprovalRef: bindingApprovalRef,
    plaintextCleanupComplete: true,
  );
}

class JournalRecord {
  const JournalRecord._({
    required this.binding,
    required this.revision,
    required this.phase,
    this.command,
    this.confirmation,
    this.block,
    this.migration,
  });
  final JournalBinding binding;
  final int revision;
  final JournalPhase phase;
  final JournalCommand? command;
  final JournalConfirmation? confirmation;
  final JournalBlock? block;
  final JournalMigration? migration;
  bool get writeMayHaveStarted => const {
    JournalPhase.mayHaveSent,
    JournalPhase.uncertain,
    JournalPhase.confirmed,
  }.contains(phase == JournalPhase.blocked ? block!.previousPhase : phase);

  /// Revision zero is an in-memory representation of absent storage only.
  factory JournalRecord.absent(JournalBinding binding) =>
      JournalRecord._(binding: binding, revision: 0, phase: JournalPhase.empty);

  Map<String, dynamic> toJson() => {
    'journal_format': 2,
    'revision': revision,
    'binding': binding.toJson(),
    'phase': phase.wire,
    'command': command?.toJson(),
    'write_may_have_started': writeMayHaveStarted,
    'confirmation': confirmation?.toJson(),
    'block': block?.toJson(),
    'migration': migration?.toJson(),
  };

  factory JournalRecord.fromJson(Map<String, dynamic> json) {
    journalFields(json, {
      'journal_format',
      'revision',
      'binding',
      'phase',
      'command',
      'write_may_have_started',
      'confirmation',
      'block',
      'migration',
    });
    if (json['journal_format'] is! int || json['journal_format'] != 2) {
      throw const JournalException(JournalIssue.unsupportedFormat);
    }
    final binding = JournalBinding.fromJson(journalObject(json['binding']));
    final revision = journalInteger(json['revision'], min: 1);
    final phase = _phase(json['phase']);
    final command = json['command'] == null
        ? null
        : JournalCommand.fromJson(journalObject(json['command']));
    final confirmation = json['confirmation'] == null
        ? null
        : command == null
        ? invalidJournal()
        : JournalConfirmation.fromJson(
            journalObject(json['confirmation']),
            command,
          );
    final block = json['block'] == null
        ? null
        : JournalBlock.fromJson(journalObject(json['block']));
    final migration = json['migration'] == null
        ? null
        : JournalMigration.fromJson(journalObject(json['migration']));
    if ((phase == JournalPhase.empty) != (command == null) ||
        (phase == JournalPhase.blocked) != (block != null) ||
        (block != null &&
            const {
              JournalPhase.empty,
              JournalPhase.blocked,
            }.contains(block.previousPhase)) ||
        ((phase == JournalPhase.confirmed ||
                block?.previousPhase == JournalPhase.confirmed) !=
            (confirmation != null)) ||
        (migration != null &&
            (migration.legacyOwner !=
                    '${binding.companyId}:${binding.profileId}' ||
                (!migration.plaintextCleanupComplete &&
                    (command?.protocol != JournalProtocol.legacyV1 ||
                        phase == JournalPhase.prepared))))) {
      invalidJournal();
    }
    final record = JournalRecord._(
      binding: binding,
      revision: revision,
      phase: phase,
      command: command,
      confirmation: confirmation,
      block: block,
      migration: migration,
    );
    if (json['write_may_have_started'] != record.writeMayHaveStarted) {
      invalidJournal();
    }
    return record;
  }

  JournalRecord _next(
    JournalPhase phase, {
    JournalCommand? command,
    JournalConfirmation? confirmation,
    JournalBlock? block,
    JournalMigration? migration,
  }) {
    if (revision >= JournalJson.maxInteger) {
      throw const JournalException(JournalIssue.revisionConflict);
    }
    return JournalRecord.fromJson(
      JournalRecord._(
        binding: binding,
        revision: revision + 1,
        phase: phase,
        command: command,
        confirmation: confirmation,
        block: block,
        migration: migration,
      ).toJson(),
    );
  }

  void _require(Set<JournalPhase> allowed) {
    if (!allowed.contains(phase)) {
      throw const JournalException(JournalIssue.illegalTransition);
    }
  }

  JournalRecord prepare(JournalCommand next) {
    _require({JournalPhase.empty});
    return _next(JournalPhase.prepared, command: next, migration: migration);
  }

  /// Only an explicitly approved legacy import may start uncertain.
  JournalRecord importLegacy(JournalCommand next, JournalMigration metadata) {
    _require({JournalPhase.empty});
    if (migration != null || next.protocol != JournalProtocol.legacyV1) {
      throw const JournalException(JournalIssue.commandConflict);
    }
    return _next(JournalPhase.uncertain, command: next, migration: metadata);
  }

  JournalRecord markMayHaveSent() {
    _require({
      JournalPhase.prepared,
      JournalPhase.uncertain,
      JournalPhase.mayHaveSent,
    });
    if (migration != null && !migration!.plaintextCleanupComplete) {
      throw const JournalException(JournalIssue.illegalTransition);
    }
    return _next(
      JournalPhase.mayHaveSent,
      command: command,
      migration: migration,
    );
  }

  JournalRecord markUncertain() {
    _require({JournalPhase.mayHaveSent});
    return _next(
      JournalPhase.uncertain,
      command: command,
      migration: migration,
    );
  }

  JournalRecord confirm(JournalConfirmation receipt) {
    _require({JournalPhase.mayHaveSent, JournalPhase.uncertain});
    if (!receipt.isForCommand(command!)) {
      throw const JournalException(JournalIssue.commandConflict);
    }
    // A confirmation object validated for another command must be revalidated.
    final checked = JournalConfirmation.fromJson(receipt.toJson(), command!);
    return _next(
      JournalPhase.confirmed,
      command: command,
      confirmation: checked,
      migration: migration,
    );
  }

  JournalRecord blockRecovery(JournalBlockReason reason) {
    _require({
      JournalPhase.prepared,
      JournalPhase.mayHaveSent,
      JournalPhase.uncertain,
      JournalPhase.confirmed,
    });
    return _next(
      JournalPhase.blocked,
      command: command,
      confirmation: confirmation,
      block: JournalBlock(reason, phase),
      migration: migration,
    );
  }

  JournalRecord compactConfirmed({
    required bool canonicalStateVerified,
    required bool confirmationConsumed,
  }) {
    _require({JournalPhase.confirmed});
    if (!canonicalStateVerified ||
        !confirmationConsumed ||
        (migration != null && !migration!.plaintextCleanupComplete)) {
      throw const JournalException(JournalIssue.illegalTransition);
    }
    return _next(JournalPhase.empty, migration: migration);
  }

  /// C2c must verify deletion/readback itself before attesting completion here.
  JournalRecord markLegacyCleanupComplete(String sourceSha256) {
    if (phase == JournalPhase.blocked ||
        migration == null ||
        migration!.plaintextCleanupComplete ||
        migration!.sourceSha256 != sourceSha256) {
      throw const JournalException(JournalIssue.illegalTransition);
    }
    return _next(
      phase,
      command: command,
      confirmation: confirmation,
      migration: migration!.completed(),
    );
  }
}

JournalPhase _phase(Object? value) {
  for (final phase in JournalPhase.values) {
    if (phase.wire == value) return phase;
  }
  invalidJournal();
}
