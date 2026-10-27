import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/development/activation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ActivationOwner owner([int id = 1]) => ActivationOwner(
  JournalBinding(
    environmentId: '10000000-0000-4000-8000-000000000001',
    baseUrl: 'https://fictional.example.test',
    authUserId: '20000000-0000-4000-8000-${id.toString().padLeft(12, '0')}',
    companyId: '30000000-0000-4000-8000-000000000001',
    profileId: '40000000-0000-4000-8000-${id.toString().padLeft(12, '0')}',
  ),
  '50000000-0000-4000-8000-${id.toString().padLeft(12, '0')}',
);

class Ports implements ActivationPorts {
  ActivationOwner current = owner();
  Uint8List? payload;
  Uint8List? signature = Uint8List.fromList([1, 2, 3]);
  Uint8List? exported;
  bool gate2 = true,
      denySignature = false,
      loseInstallAck = false,
      verified = false;
  int preparations = 0, installs = 0, writes = 0;
  Completer<void>? prepareWait;
  void Function()? afterVerify;
  Map<String, dynamic>? installedEmpty;
  @override
  ActivationOwner currentOwner() => current;
  @override
  Future<void> verifyDeployment(ActivationOwner owner) async {
    if (!gate2) throw const FormatException();
    afterVerify?.call();
  }

  @override
  Future<Uint8List?> readRequest() async => payload;
  @override
  Future<void> writeNewRequest(Uint8List bytes) async {
    if (payload != null) throw const FormatException();
    writes++;
    payload = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> prepare(
    JournalBinding binding,
    String approval,
    String maintenance,
  ) async {
    preparations++;
    await prepareWait?.future;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'enrollment_version': 1,
          'install_id': 'a' * 64,
          'package_id': 'com.example.chantipoint',
          'binding': binding.toJson(),
          'inventory_digest': 'b' * 64,
          'approval_ref': approval,
          'maintenance_ref': maintenance,
          'policy': 'certified-clean-development-v1',
        }),
      ),
    );
  }

  @override
  Future<bool> exportRequest(Uint8List bytes) async {
    exported = bytes;
    return true;
  }

  @override
  Future<Uint8List?> chooseSignature() async => signature;
  @override
  Future<void> install(
    JournalBinding binding,
    Uint8List bytes,
    Uint8List signature,
    Uint8List emptyRecord,
  ) async {
    installs++;
    if (denySignature) throw const FormatException();
    installedEmpty =
        jsonDecode(utf8.decode(emptyRecord)) as Map<String, dynamic>;
    if (loseInstallAck) {
      loseInstallAck = false;
      throw const FormatException();
    }
  }

  @override
  Future<void> verifyInstalled(JournalBinding binding) async {
    verified = true;
  }
}

void main() {
  late Ports ports;
  late DevelopmentActivationController controller;
  setUp(() {
    ports = Ports();
    controller = DevelopmentActivationController(
      ports,
      maintenanceRef: 'reviewed-maintenance',
    );
  });
  tearDown(() => controller.dispose());

  test('prepare/export never approves; explicit signed install uses empty checkpoint', () async {
    await controller.prepare();
    final original = List<int>.of(ports.payload!);
    await controller.export();
    expect(ports.exported, orderedEquals(original));
    expect(ports.installs, 0);
    expect(controller.installed, isFalse);
    await controller.choose();
    expect(ports.installs, 0);
    await controller.install();
    expect(controller.installed, isTrue);
    expect(ports.verified, isTrue);
    expect(ports.installedEmpty!['revision'], 1);
    expect(ports.installedEmpty!['phase'], 'empty');
    expect(ports.payload, orderedEquals(original));
    expect(controller.message, startsWith('Appareil activé.'));
    // Even the same employee's new login must not inherit an old success UI.
    ports.current = ActivationOwner(ports.current.binding, 'new-login-session');
    expect(controller.installed, isFalse);
    expect(controller.message, isNull);
  });
  test(
    'restart/retry preserves exact original request and reference',
    () async {
      await controller.prepare();
      final original = List<int>.of(ports.payload!);
      await controller.prepare();
      await controller.export();
      expect(ports.preparations, 1);
      expect(ports.writes, 1);
      expect(ports.exported, orderedEquals(original));
    },
  );
  test('gate 1 cannot prepare or install', () async {
    ports.gate2 = false;
    await controller.prepare();
    expect(ports.preparations, 0);
    expect(ports.payload, isNull);
  });
  test('owner change after deployment await cannot prepare', () async {
    ports.afterVerify = () => ports.current = owner(2);
    await controller.prepare();
    expect(ports.preparations, 0);
  });
  test(
    'owner change during native request cannot persist or export it',
    () async {
      ports.prepareWait = Completer<void>();
      final pending = controller.prepare();
      await Future<void>.delayed(Duration.zero);
      ports.current = owner(2);
      ports.prepareWait!.complete();
      await pending;
      expect(ports.writes, 0);
      expect(controller.requestReady, isFalse);
      expect(ports.exported, isNull);
    },
  );
  test('concurrent preparation does not create competing requests', () async {
    ports.prepareWait = Completer<void>();
    final first = controller.prepare();
    await controller.prepare();
    ports.prepareWait!.complete();
    await first;
    expect(ports.preparations, 1);
    expect(ports.writes, 1);
  });
  test(
    'wrong-owner retained request is never overwritten or exported',
    () async {
      await controller.prepare();
      final original = List<int>.of(ports.payload!);
      ports.current = owner(2);
      await controller.prepare();
      await controller.export();
      expect(controller.requestReady, isFalse);
      expect(ports.payload, orderedEquals(original));
      expect(ports.writes, 1);
      expect(ports.exported, isNull);
    },
  );
  test(
    'corrupt/duplicate retained request stays retained and denies',
    () async {
      ports.payload = Uint8List.fromList(
        utf8.encode('{"enrollment_version":1,"enrollment_version":1}'),
      );
      final original = List<int>.of(ports.payload!);
      await controller.prepare();
      expect(controller.requestReady, isFalse);
      expect(ports.preparations, 0);
      expect(ports.payload, orderedEquals(original));
    },
  );
  test('picker cancellation does not install or claim success', () async {
    await controller.prepare();
    ports.signature = null;
    await controller.choose();
    await controller.install();
    expect(ports.installs, 0);
    expect(controller.installed, isFalse);
  });
  test('oversize imported signature denied before native install', () async {
    await controller.prepare();
    ports.signature = Uint8List(129);
    await controller.choose();
    await controller.install();
    expect(ports.installs, 0);
  });
  test(
    'account switch invalidates staged signature and success display',
    () async {
      await controller.prepare();
      await controller.choose();
      ports.current = owner(2);
      expect(controller.signatureReady, isFalse);
      expect(controller.message, isNull);
      await controller.install();
      expect(ports.installs, 0);
    },
  );
  test(
    'native signature failure retains request and allows correct file retry',
    () async {
      await controller.prepare();
      final original = List<int>.of(ports.payload!);
      await controller.choose();
      ports.denySignature = true;
      await controller.install();
      expect(controller.installed, isFalse);
      ports.denySignature = false;
      await controller.choose();
      await controller.install();
      expect(controller.installed, isTrue);
      expect(ports.payload, orderedEquals(original));
    },
  );
  test('lost native install acknowledgement retries exact request and never resets', () async {
    await controller.prepare();
    final original = List<int>.of(ports.payload!);
    await controller.choose();
    ports.loseInstallAck = true;
    await controller.install();
    expect(controller.installed, isFalse);
    await controller.install();
    expect(controller.installed, isTrue);
    expect(ports.installs, 2);
    expect(ports.writes, 1);
    expect(ports.payload, orderedEquals(original));
  });
}
