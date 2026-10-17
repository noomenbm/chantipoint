import 'dart:convert';

import '../attendance_models.dart';
import '../attendance_receipt.dart';
import '../attendance_v2_requests.dart';
import '../location_evidence.dart';
import 'journal_json.dart';

class JournalBinding {
  JournalBinding({
    required String environmentId,
    required String baseUrl,
    required String authUserId,
    required String companyId,
    required String profileId,
  }) : environmentId = journalText(environmentId, max: 128),
       baseUrl = journalText(baseUrl, max: 512),
       authUserId = _uuid(authUserId),
       companyId = _uuid(companyId),
       profileId = _uuid(profileId) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)))) {
      invalidJournal();
    }
  }
  final String environmentId, baseUrl, authUserId, companyId, profileId;

  Map<String, dynamic> toJson() => {
    'environment_id': environmentId,
    'supabase_base_url': baseUrl,
    'auth_user_id': authUserId,
    'company_id': companyId,
    'employee_profile_id': profileId,
  };
  factory JournalBinding.fromJson(Map<String, dynamic> json) {
    journalFields(json, {
      'environment_id',
      'supabase_base_url',
      'auth_user_id',
      'company_id',
      'employee_profile_id',
    });
    return JournalBinding(
      environmentId: journalText(json['environment_id']),
      baseUrl: journalText(json['supabase_base_url'], max: 512),
      authUserId: journalText(json['auth_user_id']),
      companyId: journalText(json['company_id']),
      profileId: journalText(json['employee_profile_id']),
    );
  }
  // In-memory routing only, never a filename/log. Native uses framed UTF-8/SHA-256.
  String get storageIdentity =>
      jsonEncode([environmentId, baseUrl, authUserId, companyId, profileId]);
  bool matches(JournalBinding other) =>
      storageIdentity == other.storageIdentity;
}

String _uuid(Object? value) {
  final text = journalText(value, max: 36);
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(text)) {
    invalidJournal();
  }
  return text;
}

/// Validate a fixed ISO instant without allowing DateTime's overflow repair.
/// The original string remains authoritative; this function never replaces it.
DateTime journalTimestamp(Object? value) {
  final text = journalText(value, max: 40);
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(text);
  if (match == null) invalidJournal();
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(match.group(4)!) > 23 ||
      int.parse(match.group(5)!) > 59 ||
      int.parse(match.group(6)!) > 59) {
    invalidJournal();
  }
  final zone = match.group(7)!;
  if (zone != 'Z' &&
      (int.parse(zone.substring(1, 3)) > 23 ||
          int.parse(zone.substring(4)) > 59)) {
    invalidJournal();
  }
  return DateTime.parse(text).toUtc();
}

enum JournalProtocol { legacyV1, attendanceV2 }

extension JournalProtocolName on JournalProtocol {
  String get wire => this == JournalProtocol.legacyV1
      ? 'legacy-v1'
      : 'attendance-v2-final-notes';
}

String journalOperation(AttendanceCommandKind kind) =>
    kind == AttendanceCommandKind.checkIn ? 'check_in' : 'check_out';

class JournalCommand {
  JournalCommand._(
    this.protocol,
    this.operation,
    this.key,
    this.parametersJson,
    this.parameters,
  );
  final JournalProtocol protocol;
  final AttendanceCommandKind operation;
  final String key, parametersJson;
  final Map<String, dynamic> parameters;
  String get rpc =>
      '${journalOperation(operation)}${protocol == JournalProtocol.attendanceV2 ? '_v2' : ''}';

  factory JournalCommand.parameters({
    required JournalProtocol protocol,
    required AttendanceCommandKind operation,
    required Map<String, dynamic> parameters,
  }) => JournalCommand.frozen(
    protocol: protocol,
    operation: operation,
    parametersJson: JournalJson.encode(
      parameters,
      limit: JournalJson.payloadLimit,
    ),
  );

  factory JournalCommand.legacy(AttendanceCommand command) =>
      JournalCommand.parameters(
        protocol: JournalProtocol.legacyV1,
        operation: command.kind,
        parameters: command.payload,
      );
  factory JournalCommand.checkInV2(CheckInV2Request request) =>
      JournalCommand.parameters(
        protocol: JournalProtocol.attendanceV2,
        operation: AttendanceCommandKind.checkIn,
        parameters: request.toRpcParameters(),
      );
  factory JournalCommand.checkOutV2(CheckOutV2Request request) =>
      JournalCommand.parameters(
        protocol: JournalProtocol.attendanceV2,
        operation: AttendanceCommandKind.checkOut,
        parameters: request.toRpcParameters(),
      );

  factory JournalCommand.frozen({
    required JournalProtocol protocol,
    required AttendanceCommandKind operation,
    required String parametersJson,
  }) {
    final params = journalObject(
      JournalJson.decodeText(parametersJson, limit: JournalJson.payloadLimit),
    );
    final checkIn = operation == AttendanceCommandKind.checkIn;
    const common = {'p_idempotency_key', 'p_device_observed_at'};
    const evidence = {
      'p_latitude',
      'p_longitude',
      'p_accuracy_meters',
      'p_location_observed_at',
      'p_permission',
      'p_services_enabled',
      'p_location_result',
      'p_provider',
      'p_replay_only',
    };
    final legacy = protocol == JournalProtocol.legacyV1;
    journalFields(params, {
      ...common,
      if (!legacy) ...evidence,
      if (checkIn) ...{
        if (legacy) 'p_location_context',
        'p_site_description',
      } else ...{
        'p_work_session_id',
        if (!legacy) ...{'p_note_action', 'p_employee_note'},
      },
    });
    final key = journalText(params['p_idempotency_key'], max: 160);
    if (key.runes.length < 8 || key.trim() != key) invalidJournal();
    if (!checkIn) _uuid(params['p_work_session_id']);
    final action = params['p_device_observed_at'];
    if (action != null) journalTimestamp(action);
    if (legacy) {
      // Preserve the original v1 decoder and its hashing/payload semantics.
      AttendanceCommand.fromJson({
        'version': 1,
        'kind': operation.name,
        'payload': params,
      });
    } else {
      if (params['p_replay_only'] != false) invalidJournal();
      if (checkIn && params['p_site_description'] != null) {
        journalText(params['p_site_description'], max: 500, empty: true);
      }
      for (final field in ['p_latitude', 'p_longitude', 'p_accuracy_meters']) {
        final value = params[field];
        if (value != null && (value is! num || !value.isFinite)) {
          invalidJournal();
        }
      }
      if (params['p_location_observed_at'] != null) {
        journalTimestamp(params['p_location_observed_at']);
      }
      void diagnostic(String field, Iterable<String> allowed) {
        if (params[field] != null && !allowed.contains(params[field])) {
          invalidJournal();
        }
      }

      diagnostic(
        'p_permission',
        LocationPermissionState.values.map((e) => e.sqlValue),
      );
      diagnostic(
        'p_location_result',
        LocationAcquisitionResult.values.map((e) => e.sqlValue),
      );
      diagnostic('p_provider', LocationProvider.values.map((e) => e.sqlValue));
      if (params['p_services_enabled'] != null &&
          params['p_services_enabled'] is! bool) {
        invalidJournal();
      }
      if (!checkIn) {
        final note = params['p_employee_note'];
        if (note != null) journalText(note, max: 1000, empty: true);
        if (!const {
              'preserve',
              'replace',
              'clear',
            }.contains(params['p_note_action']) ||
            (params['p_note_action'] == 'replace'
                ? note == null
                : note != null)) {
          invalidJournal();
        }
      }
    }
    return JournalCommand._(
      protocol,
      operation,
      key,
      parametersJson,
      Map.unmodifiable(params),
    );
  }

  Map<String, dynamic> toJson() => {
    'protocol': protocol.wire,
    'operation': journalOperation(operation),
    'idempotency_key': key,
    'parameters_json': parametersJson,
  };
  factory JournalCommand.fromJson(Map<String, dynamic> json) {
    journalFields(json, {
      'protocol',
      'operation',
      'idempotency_key',
      'parameters_json',
    });
    final protocol = JournalProtocol.values
        .where((e) => e.wire == json['protocol'])
        .firstOrNull;
    if (protocol == null) {
      throw const JournalException(JournalIssue.unsupportedFormat);
    }
    final operation = AttendanceCommandKind.values
        .where((e) => journalOperation(e) == json['operation'])
        .firstOrNull;
    if (operation == null) invalidJournal();
    if (json['parameters_json'] is! String) invalidJournal();
    final command = JournalCommand.frozen(
      protocol: protocol,
      operation: operation,
      parametersJson: json['parameters_json'] as String,
    );
    if (command.key != json['idempotency_key']) invalidJournal();
    return command;
  }

  /// Same semantic values, including numeric type/sign and exact timestamps;
  /// formatting/key-order differences in an imported JSON object are harmless.
  bool sameRequest(JournalCommand other) {
    if (protocol != other.protocol ||
        operation != other.operation ||
        key != other.key) {
      return false;
    }
    for (final entry in parameters.entries) {
      if (!other.parameters.containsKey(entry.key) ||
          JournalJson.encode(entry.value) !=
              JournalJson.encode(other.parameters[entry.key])) {
        return false;
      }
    }
    return parameters.length == other.parameters.length;
  }

  Map<String, dynamic> rpcParameters({bool replayOnly = false}) {
    if (replayOnly && protocol == JournalProtocol.legacyV1) {
      throw const JournalException(JournalIssue.illegalTransition);
    }
    return Map.unmodifiable({
      ...parameters,
      if (protocol == JournalProtocol.attendanceV2) 'p_replay_only': replayOnly,
    });
  }
}

enum JournalConfirmationSource { rpcV1, rpcV2, legacySelect }

class JournalConfirmation {
  JournalConfirmation._(this.source, this.dataJson, this._command);
  final JournalConfirmationSource source;
  final String dataJson;
  final JournalCommand _command;
  bool isForCommand(JournalCommand command) => _command.sameRequest(command);
  Map<String, dynamic> get data => _freeze(
    journalObject(
      JournalJson.decodeText(dataJson, limit: JournalJson.payloadLimit),
    ),
  );

  factory JournalConfirmation({
    required JournalConfirmationSource source,
    required String dataJson,
    required JournalCommand command,
  }) {
    final row = journalObject(
      JournalJson.decodeText(dataJson, limit: JournalJson.payloadLimit),
    );
    final checkIn = command.operation == AttendanceCommandKind.checkIn;
    if (source == JournalConfirmationSource.legacySelect) {
      if (command.protocol != JournalProtocol.legacyV1) invalidJournal();
      journalFields(row, {'matched_key', 'session'});
      if (row['matched_key'] != command.key) invalidJournal();
      final session = journalObject(row['session']);
      _uuid(session['id']);
      journalFields(session, {
        'id',
        'location_context',
        'lifecycle_status',
        'started_at',
        'ended_at',
        'site_description',
        'check_in_device_observed_at',
        'check_out_device_observed_at',
      });
      _sessionTimes(session);
      for (final field in [
        'check_in_device_observed_at',
        'check_out_device_observed_at',
      ]) {
        if (session[field] != null) {
          journalTimestamp(session[field]);
        }
      }
      final observed =
          session[checkIn
              ? 'check_in_device_observed_at'
              : 'check_out_device_observed_at'];
      if (journalTimestamp(observed) !=
              journalTimestamp(command.parameters['p_device_observed_at']) ||
          (checkIn && session['site_description'] != null)) {
        invalidJournal();
      }
      final parsed = WorkSession.fromJson(session);
      if (!parsed.isFactory ||
          (!checkIn &&
              (parsed.id != command.parameters['p_work_session_id'] ||
                  parsed.isActive))) {
        invalidJournal();
      }
    } else {
      final v2 = command.protocol == JournalProtocol.attendanceV2;
      if ((source == JournalConfirmationSource.rpcV2) != v2) invalidJournal();
      journalFields(row, {
        'status',
        'session_id',
        'lifecycle_status',
        'location_context',
        'started_at',
        'ended_at',
        if (v2) ...{
          'contract_version',
          'review_status',
          'event_id',
          'location_outcome',
        },
      });
      _sessionTimes(row);
      _uuid(row['session_id']);
      if (v2) {
        _uuid(row['event_id']);
        final outcome = journalObject(row['location_outcome']);
        journalFields(outcome, {
          'classification',
          'reason_code',
          'policy_version',
        });
        journalText(outcome['policy_version']);
        if (outcome['reason_code'] != null) {
          journalText(outcome['reason_code'], max: 80);
        }
      }
      final receipt = AttendanceReceipt.fromJson(row);
      final session = receipt.session;
      if (!receipt.isAcknowledged ||
          session == null ||
          (checkIn && receipt.status == AttendanceReceiptStatus.closed) ||
          (!checkIn &&
              (receipt.status == AttendanceReceiptStatus.created ||
                  session.isActive ||
                  session.id != command.parameters['p_work_session_id'])) ||
          (!v2 && !session.isFactory) ||
          (v2 &&
              checkIn &&
              receipt.locationOutcome!.classification !=
                  session.locationContext)) {
        invalidJournal();
      }
    }
    return JournalConfirmation._(source, dataJson, command);
  }

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'data_json': dataJson,
  };
  factory JournalConfirmation.fromJson(
    Map<String, dynamic> json,
    JournalCommand command,
  ) {
    journalFields(json, {'source', 'data_json'});
    if (json['data_json'] is! String) invalidJournal();
    return JournalConfirmation(
      source: journalEnum(json['source'], JournalConfirmationSource.values),
      dataJson: json['data_json'] as String,
      command: command,
    );
  }
}

void _sessionTimes(Map<String, dynamic> row) {
  journalTimestamp(row['started_at']);
  if (row['ended_at'] != null) journalTimestamp(row['ended_at']);
}

Map<String, dynamic> _freeze(Map<String, dynamic> map) => Map.unmodifiable(
  map.map(
    (key, value) =>
        MapEntry(key, value is Map<String, dynamic> ? _freeze(value) : value),
  ),
);
