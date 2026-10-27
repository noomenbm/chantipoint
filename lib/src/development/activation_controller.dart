// Separate operator utility only. Never imported by the employee application.
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../attendance/journal/journal_command.dart';
import '../attendance/journal/command_journal.dart';
import '../attendance/journal/journal_json.dart';
import '../attendance/journal/journal_record.dart';

final class ActivationOwner {
  const ActivationOwner(this.binding, this.loginId);
  final JournalBinding binding;
  final String loginId;
  bool matches(ActivationOwner other) =>
      binding.matches(other.binding) && loginId == other.loginId;
}

abstract interface class ActivationPorts {
  ActivationOwner currentOwner();
  Future<void> verifyDeployment(ActivationOwner owner);
  Future<Uint8List?> readRequest();
  Future<void> writeNewRequest(Uint8List bytes);
  Future<Uint8List> prepare(
    JournalBinding binding,
    String approval,
    String maintenance,
  );
  Future<bool> exportRequest(Uint8List bytes);
  Future<Uint8List?> chooseSignature();
  Future<void> install(
    JournalBinding binding,
    Uint8List payload,
    Uint8List signature,
    Uint8List emptyRecord,
  );
  Future<void> verifyInstalled(JournalBinding binding);
}

final class DevelopmentActivationController extends ChangeNotifier {
  DevelopmentActivationController(this.ports, {required this.maintenanceRef});
  final ActivationPorts ports;
  final String maintenanceRef;
  bool busy = false;
  ActivationOwner? _requestOwner, _installedOwner;
  String? _message;
  ActivationOwner? _messageOwner;
  Uint8List? _signature;
  ActivationOwner? _signatureOwner;
  bool _disposed = false;
  bool _matchesCurrent(ActivationOwner? owner) {
    try {
      return !_disposed && owner != null && owner.matches(ports.currentOwner());
    } catch (_) {
      return false;
    }
  }

  bool get requestReady => _matchesCurrent(_requestOwner);
  bool get installed => _matchesCurrent(_installedOwner);
  bool get signatureReady =>
      _signature != null && _matchesCurrent(_signatureOwner);
  String? get message => _matchesCurrent(_messageOwner) ? _message : null;

  void _check(ActivationOwner owner) {
    if (_disposed || !owner.matches(ports.currentOwner())) {
      throw const FormatException();
    }
  }

  Future<void> _run(Future<void> Function(ActivationOwner owner) action) async {
    if (busy || _disposed) return;
    busy = true;
    _message = null;
    _messageOwner = null;
    notifyListeners();
    try {
      final owner = ports.currentOwner();
      _messageOwner = owner;
      await action(owner);
      _check(owner);
    } catch (_) {
      if (!_disposed) {
        _message =
            'Activation non confirmée. Les données sont conservées. '
            'Réessayez avec le même compte et le même fichier, ou contactez le développeur.';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void _validate(Uint8List payload, ActivationOwner owner) {
    final data = journalObject(JournalJson.decode(payload, limit: 4096));
    journalFields(data, {
      'enrollment_version',
      'install_id',
      'package_id',
      'binding',
      'inventory_digest',
      'approval_ref',
      'maintenance_ref',
      'policy',
    });
    if (data['enrollment_version'] != 1 ||
        data['policy'] != 'certified-clean-development-v1' ||
        data['maintenance_ref'] != maintenanceRef ||
        !owner.binding.matches(
          JournalBinding.fromJson(journalObject(data['binding'])),
        ) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(journalText(data['install_id'])) ||
        !RegExp(r'^[0-9a-f]{64}$')
            .hasMatch(journalText(data['inventory_digest'])) ||
        !{
          'com.example.chantipoint',
          'com.example.chantipoint.enrollmentvalidation',
        }.contains(data['package_id'])) {
      throw const FormatException();
    }
    journalText(data['approval_ref'], max: 128);
  }

  Future<Uint8List> _load(ActivationOwner owner) async {
    final payload = await ports.readRequest();
    _check(owner);
    if (payload == null) throw const FormatException();
    _validate(payload, owner);
    return payload;
  }

  Future<void> prepare() => _run((owner) async {
    await ports.verifyDeployment(owner);
    _check(owner);
    var payload = await ports.readRequest();
    _check(owner);
    if (payload == null) {
      final random = Random.secure();
      final ref =
          'beta-activation-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
      payload = await ports.prepare(owner.binding, ref, maintenanceRef);
      _check(owner);
      _validate(payload, owner);
      await ports.writeNewRequest(payload);
      _check(owner);
    }
    _validate(payload, owner);
    _requestOwner = owner;
    _message = 'Demande préparée. Enregistrez le fichier et transmettez-le au développeur.';
  });

  Future<void> export() => _run((owner) async {
    final payload = await _load(owner);
    final saved = await ports.exportRequest(payload);
    _check(owner);
    _message = saved
        ? 'Demande enregistrée. Une approbation signée reste nécessaire.'
        : 'Enregistrement annulé.';
  });

  Future<void> choose() => _run((owner) async {
    await _load(owner);
    final signature = await ports.chooseSignature();
    _check(owner);
    if (signature == null) {
      _message = 'Sélection annulée.';
      return;
    }
    if (signature.isEmpty || signature.length > 128) {
      throw const FormatException();
    }
    _signature = Uint8List.fromList(signature);
    _signatureOwner = owner;
    _message = 'Fichier sélectionné. Vous pouvez demander la vérification de l’activation.';
  });

  Future<void> install() => _run((owner) async {
    final signature = _signature;
    if (signature == null || _signatureOwner?.matches(owner) != true) {
      throw const FormatException();
    }
    await ports.verifyDeployment(owner);
    _check(owner);
    final payload = await _load(owner);
    final empty = JournalRecord.fromJson({
      ...JournalRecord.absent(owner.binding).toJson(),
      'revision': 1,
    });
    await ports.install(
      owner.binding,
      payload,
      signature,
      Uint8List.fromList(JournalCodec.encode(empty)),
    );
    _check(owner);
    await ports.verifyInstalled(owner.binding);
    _check(owner);
    _installedOwner = owner;
    _signature = null;
    _signatureOwner = null;
    _message =
        'Appareil activé. Installez maintenant l’application ChantiPoint '
        'fournie par le développeur, sans désinstaller cet outil.';
  });

  @override
  void dispose() {
    _disposed = true;
    _signature = null;
    super.dispose();
  }
}
