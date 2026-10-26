import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../../auth/auth_controller.dart';
import '../../auth/authorized_user.dart';
import '../../auth/supabase_auth_repository.dart';
import '../../config/supabase_environment_config.dart';
import '../android_foreground_location.dart';
import '../attendance_action_capture.dart';
import '../attendance_auth_owner.dart';
import '../attendance_capability.dart';
import '../attendance_operation_coordinator.dart';
import '../attendance_operation_transport.dart';
import '../attendance_request_authority.dart';
import '../employee_attendance_workflow.dart';
import '../foreground_location.dart';
import '../journal/android_journal_storage.dart';
import '../journal/android_journal_verifier.dart';
import '../journal/android_legacy_migration.dart';
import '../journal/command_journal.dart';
import '../journal/journal_verifier.dart';
import '../notes/android_session_note_storage.dart';
import '../notes/session_note_ports.dart';
import '../notes/session_note_coordinator.dart';
import '../scoped_attendance_active_session_reader.dart';
import '../supabase_attendance_operation_transport.dart';
import 'attendance_integration_guard.dart';
import 'development_attendance_authority.dart';

typedef EmployeeAttendanceWorkflowFactory = EmployeeAttendanceWorkflow Function(
  AuthorizedUser user,
);

/// Application lifetime, never a screen-owned client/owner/coordinator. Main has
/// No legacy writer. Attendance and notes share durable checkout exclusion.
final class NormalAttendanceComposition {
  NormalAttendanceComposition({
    required this.auth,
    required SupabaseAuthRepository repository,
    required SupabaseEnvironmentConfig config,
    http.Client? client,
    JournalStorage? storage,
    JournalVerifier? verifier,
    SessionNoteStorage? notes,
    LegacyAttendanceInspection? inspectLegacy,
    ForegroundLocationAcquisition Function()? locationFactory,
    AttendanceCutoverAuthority? cutover,
    AttendanceSessionProjection? projection,
    DevelopmentEnrollmentEvidence? developmentEnrollment,
  }) : client = client ?? http.Client(),
       _locationFactory =
           locationFactory ??
           (() =>
               ForegroundLocationService(const AndroidForegroundLocation())) {
    String? configurationMessage;
    try {
      final environment = config.attendanceEnvironmentId;
      if (!isAttendanceEpoch(environment)) {
        throw const AttendanceIntegrationFailure(
          'Missing trusted deployment identity',
        );
      }
      owner = AttendanceAuthOwner(
        auth: auth,
        repository: repository,
        deployment: AttendanceTrustedDeployment(
          environmentId: environment,
          projectUrl: Uri.parse(config.url),
          publishableKey: config.publishableKey,
        ),
      );
    } catch (_) {
      configurationMessage =
          'Le pointage attend une configuration de déploiement validée. '
          'Aucune entrée, sortie ou reprise ne sera envoyée. L’historique reste accessible.';
    }
    // Explicitly approved local development integration. Selecting a verifier
    // grants NOTHING: signed native approval, current auth and gate 2 must pass.
    final configuredDevelopment =
        kDebugMode &&
        !kIsWeb &&
        owner != null &&
        isDevelopmentOperatorPublicKey(
          config.developmentAttendanceOperatorPublicKey,
        );
    final development = cutover == null && configuredDevelopment
        ? DevelopmentAttendanceAuthority(
            enrollment:
                developmentEnrollment ??
                AndroidDevelopmentEnrollment(
                  operatorPublicKey:
                      config.developmentAttendanceOperatorPublicKey,
                ),
            isCurrent: (identity) => owner?.isCurrent(identity) ?? false,
            requireCapability: (identity) =>
                transport.requireV2Capability(identity),
          )
        : null;
    final sessionProjection =
        projection ??
        (development != null
            ? AttendanceSessionProjection.v2
            : AttendanceSessionProjection.legacy);
    guard = AttendanceIntegrationGuard(
      configurationMessage: configurationMessage,
      cutover: cutover ?? development ?? const UnapprovedAttendanceCutover(),
      verifyDevice: development?.verify,
      inspectLegacy:
          inspectLegacy ??
          (binding) async =>
              (await AndroidLegacyMigration().inspect(binding)).source,
      notes: notes ?? const AndroidSessionNoteStorage(),
      enrichedSessions: sessionProjection == AttendanceSessionProjection.v2,
      noteRecoveryEnabled: true,
      requireCapability: (identity) => transport.requireV2Capability(identity),
    );
    transport = SupabaseAttendanceOperationTransport(
      authority: owner ?? const _UnavailableAuthority(),
      client: this.client,
      projection: sessionProjection,
      beforeAttendanceWrite: guard.beforeAction,
      authorizeWrite: (identity, path) {
        if (path != '/rest/v1/rpc/check_in_v2' &&
            path != '/rest/v1/rpc/check_out_v2' &&
            path != '/rest/v1/rpc/save_employee_note_v2') {
          throw const AttendanceIntegrationFailure(
            'L’enregistrement de note reste désactivé.',
          );
        }
        guard.requireApproval(identity);
      },
    );
    active = ScopedAttendanceActiveSessionReader(transport: transport);
    coordinator = AttendanceOperationCoordinator(
      storage: storage ?? const AndroidJournalStorage(),
      transport: transport,
      canonical: transport,
      verifier: verifier ?? const AndroidJournalVerifier(),
    );
    noteCoordinator = SessionNoteCoordinator(
      storage: guard.notes,
      transport: transport,
      canonical: transport,
      attendance: coordinator,
      issueContext: () {
        if (_closed || owner == null) {
          throw const AttendanceIntegrationFailure(
            'Autorisation indisponible.',
          );
        }
        return owner!.issueContext();
      },
      requireV2: true,
    );
  }
  final AuthController auth;
  final http.Client client;
  final ForegroundLocationAcquisition Function() _locationFactory;
  AttendanceAuthOwner? owner;
  late final AttendanceIntegrationGuard guard;
  late final SupabaseAttendanceOperationTransport transport;
  late final ScopedAttendanceActiveSessionReader active;
  late final AttendanceOperationCoordinator coordinator;
  late final SessionNoteCoordinator noteCoordinator;
  final _workflows = <EmployeeAttendanceWorkflow>{};
  bool _closed = false;
  Future<void>? _closing;

  EmployeeAttendanceWorkflow createWorkflow(AuthorizedUser user) {
    if (_closed || !user.roles.contains(AuthorizedRole.employee)) {
      throw const AttendanceIntegrationFailure(
        'Pointage réservé aux employés autorisés.',
      );
    }
    late final EmployeeAttendanceWorkflow workflow;
    workflow = EmployeeAttendanceWorkflow(
      issueContext: () {
        if (_closed || !identical(auth.state.user, user)) {
          throw const AttendanceAuthFailure(
            AttendanceAuthFailureKind.contextInvalidated,
          );
        }
        final issuer = owner;
        if (issuer == null) {
          throw const AttendanceAuthFailure(
            AttendanceAuthFailureKind.configuration,
          );
        }
        return issuer.issueContext();
      },
      authorizationChanges: owner ?? auth,
      activeSessions: active,
      capture: AttendanceActionCapture(
        location: _locationFactory(),
        clock: const SystemAttendanceActionClock(),
        keys: SecureAttendanceActionKeys(),
      ),
      coordinator: coordinator,
      notes: noteCoordinator,
      integrationGuard: guard,
      onDisposed: () {
        unawaited(
          workflow.settled.then<void>((_) {
            _workflows.remove(workflow);
          }),
        );
      },
    );
    _workflows.add(workflow);
    return workflow;
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    final done = Completer<void>();
    _closing = done.future;
    unawaited(_close().then(done.complete, onError: done.completeError));
    return done.future;
  }

  Future<void> _close() async {
    _closed = true;
    final workflows = _workflows.toList();
    for (final workflow in workflows) {
      workflow.dispose();
    }
    final drained = owner?.close(); // Revoke now; do NOT cancel submitted work.
    await Future.wait(workflows.map((workflow) => workflow.settled));
    await drained;
    active.dispose();
    client.close();
    _workflows.clear();
  }
}

final class _UnavailableAuthority implements AttendanceRequestAuthority {
  const _UnavailableAuthority();
  @override
  bool isCurrent(AttendanceOperationIdentity identity) => false;
  @override
  Future<AttendanceRequestScope> acquire(
    AttendanceOperationIdentity identity,
  ) async => throw const AttendanceAuthFailure(
    AttendanceAuthFailureKind.configuration,
  );
}
