// Explicit operator-only entry point. Never imported by main or employee UI.
// No Supabase initialization, login, GPS or HTTP. Default is read-only inventory.
import 'dart:convert';
import 'dart:io';

import 'package:chantipoint/src/attendance/journal/android_journal_storage.dart';
import 'package:chantipoint/src/attendance/journal/command_journal.dart';
import 'package:chantipoint/src/attendance/journal/journal_command.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel(AndroidJournalStorage.channelName);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Operator commands should use a separate, externally stored define JSON file.
  // No normal app config, capability or journal can issue these approvals.
  const action = String.fromEnvironment(
    'DEVELOPMENT_ENROLLMENT_ACTION',
    defaultValue: 'inspect',
  );
  String result;
  try {
    if (action == 'inspect') {
      final value = await _channel.invokeMethod<Object?>(
        'inspectDevelopmentInventoryV1',
        {'api_version': 1},
      );
      // Only static boolean/count inventory, never contents or filenames.
      if (value is! Map || value.length != 6) throw const FormatException();
      result = jsonEncode(value);
    } else {
      final binding = JournalBinding.fromJson(
        journalObject(
          JournalJson.decode(
            utf8.encode(
              const String.fromEnvironment(
                'DEVELOPMENT_ENROLLMENT_BINDING_JSON',
              ),
            ),
          ),
        ),
      );
      final root = await getApplicationSupportDirectory();
      final payload = File('${root.path}/development-enrollment-request.json');
      final payloadType = await FileSystemEntity.type(
        payload.path,
        followLinks: false,
      );
      if (payloadType != FileSystemEntityType.file &&
          payloadType != FileSystemEntityType.notFound) {
        throw const FormatException();
      }
      if (action == 'request') {
        // This explicit action creates a Keystore install key and durable local
        // retirement marker. It is NOT read-only and never grants approval.
        final value = await _channel.invokeMethod<Object?>(
          'prepareDevelopmentEnrollmentV1',
          {
            'api_version': 1,
            'binding': binding.toJson(),
            'approval_ref': const String.fromEnvironment(
              'DEVELOPMENT_ENROLLMENT_APPROVAL_REF',
            ),
            'maintenance_ref': const String.fromEnvironment(
              'DEVELOPMENT_ENROLLMENT_MAINTENANCE_REF',
            ),
          },
        );
        if (value is! Map ||
            value.length != 1 ||
            value['payload'] is! Uint8List) {
          throw const FormatException();
        }
        final bytes = value['payload'] as Uint8List;
        if (bytes.length > 4096) throw const FormatException();
        if (await payload.exists()) {
          if (await payload.length() > 4096) throw const FormatException();
          if (base64.encode(await payload.readAsBytes()) !=
              base64.encode(bytes)) {
            throw const FormatException();
          }
        } else {
          await payload.writeAsBytes(bytes, flush: true);
        }
        result = 'Demande préparée. Aucune approbation ni requête réseau.';
      } else if (action == 'install') {
        final signature = File(
          '${root.path}/development-enrollment-signature.der',
        );
        if (await FileSystemEntity.type(signature.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FormatException();
        }
        if (await payload.length() > 4096 || await signature.length() > 128) {
          throw const FormatException();
        }
        final empty = JournalRecord.fromJson({
          ...JournalRecord.absent(binding).toJson(),
          'revision': 1,
        });
        final value = await _channel.invokeMethod<Object?>(
          'installDevelopmentEnrollmentV1',
          {
            'api_version': 1,
            'binding': binding.toJson(),
            'payload': Uint8List.fromList(await payload.readAsBytes()),
            'signature': Uint8List.fromList(await signature.readAsBytes()),
            'operator_public_key': const String.fromEnvironment(
              'DEVELOPMENT_ATTENDANCE_OPERATOR_PUBLIC_KEY',
            ),
            'empty_record': Uint8List.fromList(JournalCodec.encode(empty)),
          },
        );
        if (value is! Map ||
            value.length != 1 ||
            value['status'] != 'installed') {
          throw const FormatException();
        }
        result =
            'Approbation installée. L’activation serveur reste indépendante.';
      } else {
        throw const FormatException();
      }
    }
  } catch (_) {
    result = 'Vérification indisponible ou refusée. Toutes les preuves sont conservées.';
  }
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text(result)),
    ),
  );
}
