// Used exclusively by tool/remote_development_activation.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../attendance/attendance_capability.dart';
import '../attendance/journal/android_journal_storage.dart';
import '../attendance/journal/journal_command.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_session_evidence.dart';
import '../auth/authorized_user.dart';
import '../auth/supabase_auth_repository.dart';
import '../config/supabase_environment_config.dart';
import 'activation_controller.dart';

final class AndroidActivationPorts implements ActivationPorts {
  AndroidActivationPorts(this.auth, this.repository, this.client, this.config);
  final AuthController auth;
  final SupabaseAuthRepository repository;
  final SupabaseClient client;
  final SupabaseEnvironmentConfig config;
  final _http = http.Client();
  static const _native = MethodChannel(AndroidJournalStorage.channelName);
  static const _documents = MethodChannel(
    'chantipoint/development_activation_documents',
  );

  @override
  ActivationOwner currentOwner() {
    final user = auth.state.user;
    final session = client.auth.currentSession;
    final approval = repository.attendanceAuthorization;
    if (auth.isDisposed ||
        auth.state.status != AuthStatus.authenticated ||
        user == null ||
        !user.roles.contains(AuthorizedRole.employee) ||
        session == null ||
        approval == null ||
        !identical(user, approval.user) ||
        !approval.employeeAuthorized ||
        !approval.session.sameLogin(AuthSessionEvidence(session))) {
      throw const FormatException();
    }
    final evidence = AuthSessionEvidence(session);
    final login = evidence.loginSessionId;
    if (login == null ||
        (evidence.expiresAt != null &&
            evidence.expiresAt! * 1000 <=
                DateTime.now().millisecondsSinceEpoch)) {
      throw const FormatException();
    }
    return ActivationOwner(
      JournalBinding(
        environmentId: config.attendanceEnvironmentId,
        baseUrl: config.url,
        authUserId: evidence.authUserId,
        companyId: user.companyId,
        profileId: user.profileId,
      ),
      login,
    );
  }

  @override
  Future<void> verifyDeployment(ActivationOwner owner) async {
    await auth.revalidateOnResume();
    if (!owner.matches(currentOwner())) throw const FormatException();
    final token = client.auth.currentSession!.accessToken;
    final response = await _http
        .get(
          Uri.parse('${config.url}/rest/v1/rpc/attendance_capability'),
          headers: {
            'apikey': config.publishableKey,
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (!owner.matches(currentOwner()) || response.statusCode != 200) {
      throw const FormatException();
    }
    final capability = AttendanceCapability.parse(response.body);
    if (!capability.v2Available ||
        capability.deploymentEpoch != config.attendanceEnvironmentId) {
      throw const FormatException();
    }
  }

  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}/development-enrollment-request.json',
  );

  @override
  Future<Uint8List?> readRequest() async {
    final file = await _file();
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || await file.length() > 4096) {
      throw const FormatException();
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 4096) throw const FormatException();
    return bytes;
  }

  @override
  Future<void> writeNewRequest(Uint8List bytes) async {
    final old = await readRequest();
    if (old != null) {
      if (!_equal(old, bytes)) throw const FormatException();
      return;
    }
    await (await _file()).writeAsBytes(bytes, flush: true);
    final saved = await readRequest();
    if (saved == null || !_equal(saved, bytes)) throw const FormatException();
  }

  bool _equal(Uint8List a, Uint8List b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => a[i] == b[i]);

  @override
  Future<Uint8List> prepare(
    JournalBinding binding,
    String approval,
    String maintenance,
  ) async {
    final value = await _native.invokeMapMethod<String, Object?>(
      'prepareDevelopmentEnrollmentV1',
      {
        'api_version': 1,
        'binding': binding.toJson(),
        'approval_ref': approval,
        'maintenance_ref': maintenance,
      },
    );
    if (value == null || value.length != 1 || value['payload'] is! Uint8List) {
      throw const FormatException();
    }
    return value['payload'] as Uint8List;
  }

  @override
  Future<bool> exportRequest(Uint8List bytes) async {
    final value = await _documents.invokeMapMethod<String, Object?>(
      'saveRequest',
      {'api_version': 1, 'payload': bytes},
    );
    if (value == null ||
        value.length != 1 ||
        !{'saved', 'cancelled'}.contains(value['status'])) {
      throw const FormatException();
    }
    return value['status'] == 'saved';
  }

  @override
  Future<Uint8List?> chooseSignature() async {
    final value = await _documents.invokeMapMethod<String, Object?>(
      'chooseSignature',
      {'api_version': 1},
    );
    if (value?.length == 1 && value?['status'] == 'cancelled') return null;
    if (value?.length != 2 ||
        value?['status'] != 'selected' ||
        value?['signature'] is! Uint8List) {
      throw const FormatException();
    }
    return value!['signature'] as Uint8List;
  }

  @override
  Future<void> install(
    JournalBinding binding,
    Uint8List payload,
    Uint8List signature,
    Uint8List emptyRecord,
  ) async {
    final value = await _native.invokeMapMethod<String, Object?>(
      'installDevelopmentEnrollmentV1',
      {
        'api_version': 1,
        'binding': binding.toJson(),
        'payload': payload,
        'signature': signature,
        'operator_public_key': config.developmentAttendanceOperatorPublicKey,
        'empty_record': emptyRecord,
      },
    );
    if (value?.length != 1 || value?['status'] != 'installed') {
      throw const FormatException();
    }
  }

  @override
  Future<void> verifyInstalled(JournalBinding binding) async {
    final value = await _native.invokeMapMethod<String, Object?>(
      'readDevelopmentEnrollmentV1',
      {
        'api_version': 1,
        'binding': binding.toJson(),
        'operator_public_key': config.developmentAttendanceOperatorPublicKey,
      },
    );
    if (value?.length != 3 ||
        value?['status'] != 'approved' ||
        value?['binding'] is! Map ||
        !binding.matches(
          JournalBinding.fromJson(
            Map<String, dynamic>.from(value!['binding'] as Map),
          ),
        )) {
      throw const FormatException();
    }
  }

  void close() => _http.close();
}
