// Host simulation only; actual signatures/persistence are tested on Android.
import 'dart:convert';

import 'package:chantipoint/src/attendance/integration/development_attendance_authority.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';

import 'journal_fixtures.dart';

// Public P-256 generator point, no signing key or credentials.
String get fictionalOperatorPublicKey {
  const hex =
      '3059301306072a8648ce3d020106082a8648ce3d03010703420004'
      '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296'
      '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5';
  return base64.encode([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

class FictionalDevelopmentEnrollment implements DevelopmentEnrollmentEvidence {
  bool approved = false;
  JournalBinding binding = journalBinding();
  int calls = 0;
  Future<void> Function(int)? onVerify;
  @override
  Future<void> verify(JournalBinding expected) async {
    calls++;
    await onVerify?.call(calls);
    if (!approved || !binding.matches(expected)) {
      throw StateError('fictional enrollment denied');
    }
  }
}
