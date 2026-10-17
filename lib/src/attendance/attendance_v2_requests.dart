import 'location_evidence.dart';

enum CheckoutNoteAction { preserve, replace, clear }

/// NULL and empty text are different. No trimming or Unicode normalization.
class CheckoutNoteIntent {
  const CheckoutNoteIntent.preserve()
    : action = CheckoutNoteAction.preserve,
      text = null;
  const CheckoutNoteIntent.replace(String this.text)
    : action = CheckoutNoteAction.replace;
  const CheckoutNoteIntent.clear()
    : action = CheckoutNoteAction.clear,
      text = null;

  final CheckoutNoteAction action;
  final String? text;
}

/// Explicit inputs only: this layer generates no key, clock time or GPS fix.
/// This is not a journal codec and cannot be saved by the version-1 store.
class CheckInV2Request {
  const CheckInV2Request({
    required this.idempotencyKey,
    this.deviceObservedAt,
    this.siteDescription,
    this.evidence = const LocationEvidence(),
  });

  final String idempotencyKey;
  final DateTime? deviceObservedAt;
  final String? siteDescription;
  final LocationEvidence evidence;

  Map<String, dynamic> toRpcParameters({bool replayOnly = false}) =>
      Map.unmodifiable({
        'p_idempotency_key': idempotencyKey,
        'p_device_observed_at': deviceObservedAt?.toUtc().toIso8601String(),
        'p_site_description': siteDescription,
        ...evidence.toRpcParameters(),
        'p_replay_only': replayOnly,
      });
}

class CheckOutV2Request {
  const CheckOutV2Request({
    required this.workSessionId,
    required this.idempotencyKey,
    this.deviceObservedAt,
    this.evidence = const LocationEvidence(),
    this.noteIntent = const CheckoutNoteIntent.preserve(),
  });

  final String workSessionId;
  final String idempotencyKey;
  final DateTime? deviceObservedAt;
  final LocationEvidence evidence;
  final CheckoutNoteIntent noteIntent;

  Map<String, dynamic> toRpcParameters({bool replayOnly = false}) =>
      Map.unmodifiable({
        'p_work_session_id': workSessionId,
        'p_idempotency_key': idempotencyKey,
        'p_device_observed_at': deviceObservedAt?.toUtc().toIso8601String(),
        ...evidence.toRpcParameters(),
        'p_replay_only': replayOnly,
        'p_note_action': noteIntent.action.name,
        'p_employee_note': noteIntent.text,
      });
}
