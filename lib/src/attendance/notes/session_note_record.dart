import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../attendance_operation_transport.dart';
import '../attendance_v2_requests.dart';
import '../journal/journal_command.dart';
import '../journal/journal_json.dart';

String _uuid(Object? value) {
  final text = journalText(value, max: 36);
  if (!RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
      .hasMatch(text)) {
    invalidJournal();
  }
  return text;
}

/// Immutable note intent, never an attendance JournalCommand. No credentials.
final class SessionNoteCommand {
  SessionNoteCommand._(
    this.identity,
    this.parametersJson,
    this.contractVersion,
  ) {
    if (contractVersion != 1 && contractVersion != 2) invalidJournal();
    journalInteger(identity.generation, min: 1);
    final p = parameters;
    journalFields(p, {
      'p_work_session_id',
      'p_operation_key',
      'p_note_action',
      'p_employee_note',
      'p_replay_only',
    });
    _uuid(p['p_work_session_id']);
    final key = journalText(p['p_operation_key'], max: 160);
    if (key.runes.length < 8 ||
        key.startsWith(' ') ||
        key.endsWith(' ') ||
        p['p_replay_only'] != false) {
      invalidJournal();
    }
    if (p['p_note_action'] == 'replace') {
      journalText(p['p_employee_note'], max: 1000, empty: true);
    } else if (p['p_note_action'] != 'clear' || p['p_employee_note'] != null) {
      invalidJournal();
    }
  }
  factory SessionNoteCommand.capture({
    required AttendanceOperationIdentity identity,
    required String sessionId,
    required String operationKey,
    required CheckoutNoteIntent note,
    int contractVersion = 1,
  }) => SessionNoteCommand._(
    identity,
    JournalJson.encode({
      'p_work_session_id': sessionId,
      'p_operation_key': operationKey,
      'p_note_action': note.action.name,
      'p_employee_note': note.text,
      'p_replay_only': false,
    }, limit: JournalJson.payloadLimit),
    contractVersion,
  );
  final AttendanceOperationIdentity identity;
  final int contractVersion;
  final String parametersJson;
  Map<String, dynamic> get parameters => journalObject(
    JournalJson.decodeText(parametersJson, limit: JournalJson.payloadLimit),
  );
  String get sessionId => parameters['p_work_session_id'] as String;
  String get key => parameters['p_operation_key'] as String;
  String? get text => parameters['p_employee_note'] as String?;
  String body({required bool replayOnly}) => replayOnly
      ? JournalJson.encode({
          ...parameters,
          'p_replay_only': true,
        }, limit: JournalJson.payloadLimit)
      : parametersJson;
  Map<String, dynamic> toJson() => {
    if (contractVersion != 1) 'note_protocol': contractVersion,
    'captured_generation': identity.generation,
    'parameters_json': parametersJson,
  };
  factory SessionNoteCommand.fromJson(
    JournalBinding binding,
    Map<String, dynamic> json,
  ) {
    journalFields(json, {
      'captured_generation',
      'parameters_json',
      if (json.containsKey('note_protocol')) 'note_protocol',
    });
    if (json.containsKey('note_protocol') &&
        (json['note_protocol'] is! int || json['note_protocol'] != 2)) {
      invalidJournal();
    }
    return SessionNoteCommand._(
      AttendanceOperationIdentity(
        binding,
        journalInteger(json['captured_generation'], min: 1),
      ),
      journalText(json['parameters_json'], max: JournalJson.payloadLimit),
      json.containsKey('note_protocol') ? 2 : 1,
    );
  }
  bool same(SessionNoteCommand other) =>
      identity.binding.matches(other.identity.binding) &&
      identity.generation == other.identity.generation &&
      contractVersion == other.contractVersion &&
      parametersJson == other.parametersJson;
}

enum SessionNoteOutcome { applied, notApplied }

/// Original JSON, checked against the frozen request. The trusted server compares
/// its opaque PostgreSQL fingerprint; clients do not recreate jsonb::text hashing.
final class SessionNoteReceipt {
  SessionNoteReceipt._(this.json, this.outcome, this.reason);
  final String json;
  final SessionNoteOutcome outcome;
  final String? reason;
  factory SessionNoteReceipt.parse(String text, SessionNoteCommand command) {
    final r = journalObject(
      JournalJson.decodeText(text, limit: JournalJson.payloadLimit),
    );
    journalFields(r, {
      if (command.contractVersion == 2) 'deployment_epoch',
      'note_contract_version',
      'operation_key',
      'employee_profile_id',
      'company_id',
      'session_id',
      'request_fingerprint',
      'outcome',
      'reason',
      'settled_at',
    });
    if (r['note_contract_version'] is! int ||
        r['note_contract_version'] != command.contractVersion ||
        (command.contractVersion == 2 &&
            r['deployment_epoch'] != command.identity.binding.environmentId) ||
        r['operation_key'] != command.key ||
        r['employee_profile_id'] != command.identity.binding.profileId ||
        r['company_id'] != command.identity.binding.companyId ||
        r['session_id'] != command.sessionId ||
        r['request_fingerprint'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$')
            .hasMatch(r['request_fingerprint'] as String)) {
      invalidJournal();
    }
    journalTimestamp(r['settled_at']);
    final applied = r['outcome'] == 'applied' && r['reason'] == null;
    final rejected =
        r['outcome'] == 'not_applied' &&
        const {'replay_fenced', 'session_closed'}.contains(r['reason']);
    if (!applied && !rejected) invalidJournal();
    return SessionNoteReceipt._(
      text,
      applied ? SessionNoteOutcome.applied : SessionNoteOutcome.notApplied,
      r['reason'] as String?,
    );
  }
}

enum SessionNotePhase { empty, pending, terminal, checkout }

/// Durable exclusion reference only; full attendance intent/receipt stays in C3.
final class SessionNoteCheckout {
  SessionNoteCheckout({
    required this.sessionId,
    required this.key,
    required this.generation,
    required this.commandSha256,
  }) {
    _uuid(sessionId);
    journalText(key, max: 160);
    journalInteger(generation, min: 1);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(commandSha256)) invalidJournal();
  }
  final String sessionId, key;
  final int generation;
  final String commandSha256;
  static String fingerprint(JournalCommand command) => sha256
      .convert(utf8.encode(JournalJson.encode(command.toJson())))
      .toString();
  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'idempotency_key': key,
    'captured_generation': generation,
    'command_sha256': commandSha256,
  };
  factory SessionNoteCheckout.fromJson(Map<String, dynamic> json) {
    journalFields(json, {
      'session_id',
      'idempotency_key',
      'captured_generation',
      'command_sha256',
    });
    return SessionNoteCheckout(
      sessionId: _uuid(json['session_id']),
      key: journalText(json['idempotency_key'], max: 160),
      generation: journalInteger(json['captured_generation'], min: 1),
      commandSha256: journalText(json['command_sha256'], max: 64),
    );
  }
}

final class SessionNoteRecord {
  const SessionNoteRecord._(
    this.binding,
    this.revision,
    this.phase,
    this.command,
    this.receipt,
    this.checkout,
  );
  factory SessionNoteRecord.absent(JournalBinding binding) =>
      SessionNoteRecord._(binding, 0, SessionNotePhase.empty, null, null, null);
  final JournalBinding binding;
  final int revision;
  final SessionNotePhase phase;
  final SessionNoteCommand? command;
  final SessionNoteReceipt? receipt;
  final SessionNoteCheckout? checkout;
  Map<String, dynamic> toJson() => {
    'note_format': 1,
    'revision': revision,
    'binding': binding.toJson(),
    'phase': phase.name,
    'command': command?.toJson(),
    'receipt_json': receipt?.json,
    'checkout': checkout?.toJson(),
  };
  List<int> get bytes => utf8.encode(JournalJson.encode(toJson()));
  factory SessionNoteRecord.decode(List<int> bytes, JournalBinding expected) {
    final j = journalObject(JournalJson.decode(bytes));
    journalFields(j, {
      'note_format',
      'revision',
      'binding',
      'phase',
      'command',
      'receipt_json',
      'checkout',
    });
    if (j['note_format'] is! int || j['note_format'] != 1) invalidJournal();
    final binding = JournalBinding.fromJson(journalObject(j['binding']));
    if (!binding.matches(expected)) {
      throw const JournalException(JournalIssue.identityMismatch);
    }
    final command = j['command'] == null
        ? null
        : SessionNoteCommand.fromJson(binding, journalObject(j['command']));
    final receipt = j['receipt_json'] == null
        ? null
        : command == null
        ? invalidJournal()
        : SessionNoteReceipt.parse(
            journalText(j['receipt_json'], max: JournalJson.payloadLimit),
            command,
          );
    final checkout = j['checkout'] == null
        ? null
        : SessionNoteCheckout.fromJson(journalObject(j['checkout']));
    final phase = journalEnum(j['phase'], SessionNotePhase.values);
    if ((phase == SessionNotePhase.checkout) != (checkout != null) ||
        (phase == SessionNotePhase.empty &&
            (command != null || receipt != null)) ||
        (phase == SessionNotePhase.pending &&
            (command == null || receipt != null)) ||
        (phase == SessionNotePhase.terminal &&
            (command == null || receipt == null)) ||
        (phase == SessionNotePhase.checkout &&
            (command == null) != (receipt == null))) {
      invalidJournal();
    }
    return SessionNoteRecord._(
      binding,
      journalInteger(j['revision'], min: 1),
      phase,
      command,
      receipt,
      checkout,
    );
  }
  SessionNoteRecord _next(
    SessionNotePhase phase,
    SessionNoteCommand? command,
    SessionNoteReceipt? receipt,
    SessionNoteCheckout? checkout,
  ) => SessionNoteRecord.decode(
    SessionNoteRecord._(
      binding,
      revision + 1,
      phase,
      command,
      receipt,
      checkout,
    ).bytes,
    binding,
  );
  SessionNoteRecord prepare(SessionNoteCommand next) {
    if (!const {
          SessionNotePhase.empty,
          SessionNotePhase.terminal,
        }.contains(phase) ||
        !binding.matches(next.identity.binding) ||
        command?.key == next.key) {
      invalidJournal();
    }
    return _next(SessionNotePhase.pending, next, null, null);
  }

  SessionNoteRecord confirm(SessionNoteReceipt next) {
    if (phase != SessionNotePhase.pending) invalidJournal();
    return _next(
      SessionNotePhase.terminal,
      command,
      SessionNoteReceipt.parse(next.json, command!),
      null,
    );
  }

  SessionNoteRecord reserveCheckout(SessionNoteCheckout next) {
    if (!const {
      SessionNotePhase.empty,
      SessionNotePhase.terminal,
    }.contains(phase)) {
      invalidJournal();
    }
    return _next(SessionNotePhase.checkout, command, receipt, next);
  }

  SessionNoteRecord releaseCheckout() {
    if (phase != SessionNotePhase.checkout) invalidJournal();
    return _next(
      command == null ? SessionNotePhase.empty : SessionNotePhase.terminal,
      command,
      receipt,
      null,
    );
  }
}
