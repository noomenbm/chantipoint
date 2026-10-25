import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../attendance_operation_transport.dart';
import '../journal/android_journal_storage.dart';
import '../journal/journal_command.dart';
import '../journal/journal_json.dart';
import 'attendance_integration_guard.dart';

abstract interface class DevelopmentEnrollmentEvidence {
  Future<void> verify(JournalBinding binding);
}

/// Structural P-256 SPKI check. Native additionally validates the point/key and
/// every approval signature. This is configuration validation, never approval.
bool isDevelopmentOperatorPublicKey(String value) {
  try {
    if (value.isEmpty || value.length > 512) return false;
    final bytes = base64.decode(value);
    const prefix = <int>[
      0x30,
      0x59,
      0x30,
      0x13,
      0x06,
      0x07,
      0x2a,
      0x86,
      0x48,
      0xce,
      0x3d,
      0x02,
      0x01,
      0x06,
      0x08,
      0x2a,
      0x86,
      0x48,
      0xce,
      0x3d,
      0x03,
      0x01,
      0x07,
      0x03,
      0x42,
      0x00,
      0x04,
    ];
    return bytes.length == 91 &&
        base64.encode(bytes) == value &&
        List.generate(
          prefix.length,
          (i) => bytes[i] == prefix[i],
        ).every((v) => v);
  } catch (_) {
    return false;
  }
}

/// Verification only. No enrollment, initialization, deletion or sidecar repair.
final class AndroidDevelopmentEnrollment
    implements DevelopmentEnrollmentEvidence {
  const AndroidDevelopmentEnrollment({
    required this.operatorPublicKey,
    this.channel = const MethodChannel(AndroidJournalStorage.channelName),
  });
  final String operatorPublicKey;
  final MethodChannel channel;
  @override
  Future<void> verify(JournalBinding binding) async {
    try {
      if (kIsWeb ||
          defaultTargetPlatform != TargetPlatform.android ||
          operatorPublicKey.isEmpty ||
          operatorPublicKey.length > 512) {
        throw const FormatException();
      }
      final value = await channel.invokeMethod<Object?>(
        'readDevelopmentEnrollmentV1',
        {
          'api_version': 1,
          'binding': binding.toJson(),
          'operator_public_key': operatorPublicKey,
        },
      );
      if (value is! Map ||
          value.length != 3 ||
          value['status'] != 'approved' ||
          value['binding'] is! Map) {
        throw const FormatException();
      }
      if (!JournalBinding.fromJson(
        Map<String, dynamic>.from(value['binding'] as Map),
      ).matches(binding)) {
        throw const FormatException();
      }
      journalText(value['approval_ref'], max: 128);
    } catch (_) {
      throw const AttendanceIntegrationFailure(
        DevelopmentAttendanceAuthority.denied,
      );
    }
  }
}

/// Application-lifetime development issuer. Requires signed, durable native
/// evidence AND a fresh capability; neither configuration nor file absence grants.
final class DevelopmentAttendanceAuthority
    implements AttendanceCutoverAuthority {
  DevelopmentAttendanceAuthority({
    required this.enrollment,
    required this.isCurrent,
    required this.requireCapability,
  });
  final DevelopmentEnrollmentEvidence enrollment;
  final bool Function(AttendanceOperationIdentity) isCurrent;
  final Future<void> Function(AttendanceOperationIdentity) requireCapability;
  AttendanceOperationIdentity? _approved;
  int _attempt = 0;
  static const denied =
      'Cet appareil n’est pas approuvé pour le nouveau pointage. '
      'Les données conservées restent intactes. L’historique reste accessible.';
  @override
  bool isApproved(AttendanceOperationIdentity identity) {
    final approved = _approved;
    return approved != null &&
        approved.generation == identity.generation &&
        approved.binding.matches(identity.binding) &&
        isCurrent(identity);
  }

  Future<void> verify(AttendanceOperationIdentity identity) async {
    final attempt = ++_attempt;
    _approved = null;
    try {
      if (!isCurrent(identity)) throw const FormatException();
      await enrollment.verify(identity.binding);
      if (!isCurrent(identity) || attempt != _attempt) {
        throw const FormatException();
      }
      await requireCapability(identity);
      if (!isCurrent(identity) || attempt != _attempt) {
        throw const FormatException();
      }
      // Recheck durable approval after asynchronous capability/credential work.
      await enrollment.verify(identity.binding);
      if (!isCurrent(identity) || attempt != _attempt) {
        throw const FormatException();
      }
      _approved = identity;
    } catch (_) {
      if (attempt == _attempt) _approved = null;
      throw const AttendanceIntegrationFailure(denied);
    }
  }
}
