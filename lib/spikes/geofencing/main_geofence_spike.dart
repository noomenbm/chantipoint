import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart' as native;

import 'geofence_spike_store.dart';
import 'geofence_state_machine.dart';

@pragma('vm:entry-point')
Future<void> geofenceSpikeBackgroundCallback(
  native.GeofenceCallbackParams params,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  await GeofenceSpikeStore().recordNativeCallback(
    params,
    callbackReceivedAtUtc: DateTime.now().toUtc(),
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GeofenceSpikeApp());
}

class GeofenceSpikeApp extends StatelessWidget {
  const GeofenceSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChantiPoint - Spike géorepérage',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const GeofenceSpikeScreen(),
    );
  }
}

class GeofenceSpikeScreen extends StatefulWidget {
  const GeofenceSpikeScreen({super.key});

  @override
  State<GeofenceSpikeScreen> createState() => _GeofenceSpikeScreenState();
}

class _GeofenceSpikeScreenState extends State<GeofenceSpikeScreen> {
  final GeofenceSpikeStore _store = GeofenceSpikeStore();

  bool _nativeInitialized = false;
  bool _busy = false;
  bool _locationServicesEnabled = false;
  LocationPermission? _locationPermission;
  Position? _currentPosition;
  GeofenceSpikeSnapshot _snapshot = GeofenceSpikeSnapshot.inactive();
  List<GeofenceDiagnosticEvent> _events = <GeofenceDiagnosticEvent>[];
  List<String> _registeredGeofenceIds = <String>[];
  int _radiusMeters = 100;
  String _statusMessage = 'Prototype prêt.';

  @override
  void initState() {
    super.initState();
    unawaited(_refreshDiagnostics());
  }

  Future<void> _refreshDiagnostics() async {
    await _runBusy(() async {
      await _ensureNativeInitialized();
      await _store.evaluateGracePeriod(DateTime.now().toUtc());
      final locationServicesEnabled =
          await Geolocator.isLocationServiceEnabled();
      final locationPermission = await Geolocator.checkPermission();
      final snapshot = await _store.loadSnapshot();
      final events = await _store.loadEvents();
      final registeredIds = await native.NativeGeofenceManager.instance
          .getRegisteredGeofenceIds();

      if (!mounted) {
        return;
      }
      setState(() {
        _locationServicesEnabled = locationServicesEnabled;
        _locationPermission = locationPermission;
        _snapshot = snapshot;
        _events = events;
        _registeredGeofenceIds = registeredIds;
        _statusMessage =
            'Diagnostics actualisés sans nouvelle position GPS.';
      });
    });
  }

  Future<void> _registerGeofence() async {
    await _runBusy(() async {
      await _ensureNativeInitialized();

      final permissionsOk = await _ensureLocationPermissions();
      if (!permissionsOk) {
        return;
      }

      final servicesEnabled = await Geolocator.isLocationServiceEnabled();
      if (!servicesEnabled) {
        await _store.markMonitoringUnavailable(
          nowUtc: DateTime.now().toUtc(),
          reason: 'Services de localisation désactivés.',
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _locationServicesEnabled = false;
          _statusMessage = 'Les services de localisation sont désactivés. Activez-les avant de lancer le test.';
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition();
      final nowUtc = DateTime.now().toUtc();
      final sessionId = 'geo-spike-${nowUtc.microsecondsSinceEpoch}';
      final geofenceId = '$sessionId-r$_radiusMeters';

      await native.NativeGeofenceManager.instance.removeAllGeofences();
      await _store.startSession(
        sessionId: sessionId,
        geofenceId: geofenceId,
        nowUtc: nowUtc,
      );

      final geofence = native.Geofence(
        id: geofenceId,
        location: native.Location(
          latitude: position.latitude,
          longitude: position.longitude,
        ),
        radiusMeters: _radiusMeters.toDouble(),
        triggers: const <native.GeofenceEvent>{
          native.GeofenceEvent.enter,
          native.GeofenceEvent.exit,
        },
        iosSettings: const native.IosGeofenceSettings(initialTrigger: false),
        androidSettings: const native.AndroidGeofenceSettings(
          initialTriggers: <native.GeofenceEvent>{},
          expiration: Duration(hours: 12),
          notificationResponsiveness: Duration(minutes: 1),
        ),
      );

      try {
        await native.NativeGeofenceManager.instance.createGeofence(
          geofence,
          geofenceSpikeBackgroundCallback,
        );
      } catch (error) {
        await _store.markMonitoringUnavailable(
          nowUtc: DateTime.now().toUtc(),
          reason: 'Échec de création du géorepérage: $error',
        );
        rethrow;
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _currentPosition = position;
        _locationServicesEnabled = true;
        _statusMessage =
            'Géorepérage enregistré à ${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}.';
      });
      await _refreshDiagnostics();
    });
  }

  Future<void> _stopGeofence() async {
    await _runBusy(() async {
      await _ensureNativeInitialized();
      final snapshot = await _store.loadSnapshot();
      final geofenceId = snapshot.geofenceId;

      if (geofenceId != null) {
        try {
          await native.NativeGeofenceManager.instance.removeGeofenceById(
            geofenceId,
          );
        } catch (_) {
          await native.NativeGeofenceManager.instance.removeAllGeofences();
        }
      } else {
        await native.NativeGeofenceManager.instance.removeAllGeofences();
      }

      await _store.stopSession(
        nowUtc: DateTime.now().toUtc(),
        reason: 'Test arrêté; géorepérage supprimé.',
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Test arrêté et géorepérage supprimé.';
      });
      await _refreshDiagnostics();
    });
  }

  Future<void> _clearEvents() async {
    await _runBusy(() async {
      await _store.clearEvents();
      await _refreshDiagnostics();
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Historique diagnostique effacé.';
      });
    });
  }

  Future<void> _captureCurrentPosition() async {
    await _runBusy(() async {
      final permissionsOk = await _ensureForegroundLocationPermission();
      if (!permissionsOk) {
        return;
      }
      final servicesEnabled = await Geolocator.isLocationServiceEnabled();
      if (!servicesEnabled) {
        if (!mounted) {
          return;
        }
        setState(() {
          _locationServicesEnabled = false;
          _statusMessage = 'Services de localisation désactivés.';
        });
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPosition = position;
        _locationServicesEnabled = true;
        _statusMessage = 'Position GPS capturée explicitement.';
      });
    });
  }

  Future<bool> _ensureLocationPermissions() async {
    final foregroundGranted = await _ensureForegroundLocationPermission();
    if (!foregroundGranted) {
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always) {
      return true;
    }

    if (!mounted) {
      return false;
    }
    final explain = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Permission arrière-plan'),
          content: const Text(
            'Ce prototype doit recevoir les événements de géorepérage même lorsque l’application est en arrière-plan. '
            'Android exige d’abord la permission de localisation en premier plan, puis la permission “Toujours autoriser” dans les contrôles de permission.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continuer'),
            ),
          ],
        );
      },
    );

    if (!mounted || explain != true) {
      return false;
    }

    await Geolocator.openAppSettings();
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.always) {
      return true;
    }

    if (!mounted) {
      return false;
    }
    setState(() {
      _locationPermission = permission;
      _statusMessage = 'Permission de localisation en arrière-plan refusée. Ouvrez les paramètres Android et choisissez “Toujours autoriser” pour ce prototype.';
    });
    return false;
  }

  Future<bool> _ensureForegroundLocationPermission() async {
    var status = await Geolocator.checkPermission();
    if (status == LocationPermission.whileInUse ||
        status == LocationPermission.always) {
      return true;
    }
    status = await Geolocator.requestPermission();
    if (!mounted) {
      return false;
    }
    setState(() {
      _locationPermission = status;
      if (status == LocationPermission.denied) {
        _statusMessage = 'Permission de localisation en premier plan refusée.';
      } else if (status == LocationPermission.deniedForever) {
        _statusMessage = 'Permission de localisation refusée définitivement. Ouvrez les paramètres Android.';
      }
    });
    return status == LocationPermission.whileInUse ||
        status == LocationPermission.always;
  }

  Future<void> _ensureNativeInitialized() async {
    if (_nativeInitialized) {
      return;
    }
    await native.NativeGeofenceManager.instance.initialize();
    _nativeInitialized = true;
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    if (mounted) {
      setState(() {
        _busy = true;
      });
    }
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Erreur: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasActiveGeofence =
        _snapshot.geofenceId != null &&
        _registeredGeofenceIds.contains(_snapshot.geofenceId);

    return Scaffold(
      appBar: AppBar(title: const Text('Spike géorepérage Android')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshDiagnostics,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              _Banner(statusMessage: _statusMessage),
              const SizedBox(height: 12),
              _Section(
                title: 'Position et permissions',
                children: <Widget>[
                  _FactRow(
                    label: 'Dernière position capturée',
                    value: _formatPosition(_currentPosition),
                  ),
                  _FactRow(
                    label: 'Services Android',
                    value: _locationServicesEnabled ? 'Activés' : 'Désactivés',
                  ),
                  _FactRow(
                    label: 'Permission premier plan',
                    value: _formatForegroundPermission(_locationPermission),
                  ),
                  _FactRow(
                    label: 'Permission arrière-plan',
                    value: _formatBackgroundPermission(_locationPermission),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _captureCurrentPosition,
                        icon: const Icon(Icons.my_location),
                        label: const Text('Capturer la position GPS'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : Geolocator.openLocationSettings,
                        icon: const Icon(Icons.location_on),
                        label: const Text('Paramètres localisation'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : Geolocator.openAppSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Permissions Android'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Géorepérage de test',
                children: <Widget>[
                  SegmentedButton<int>(
                    segments: const <ButtonSegment<int>>[
                      ButtonSegment<int>(value: 100, label: Text('100 m')),
                      ButtonSegment<int>(value: 150, label: Text('150 m')),
                    ],
                    selected: <int>{_radiusMeters},
                    onSelectionChanged: _busy
                        ? null
                        : (selection) {
                            setState(() {
                              _radiusMeters = selection.first;
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  _FactRow(
                    label: 'Enregistrement OS',
                    value: hasActiveGeofence
                        ? 'Actif (${_snapshot.geofenceId})'
                        : 'Aucun géorepérage actif',
                  ),
                  _FactRow(
                    label: 'État de surveillance',
                    value: _snapshot.state.name,
                  ),
                  _FactRow(
                    label: 'Expiration du délai de grâce',
                    value: _formatDateTime(_snapshot.graceExpiresAtUtc),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _busy ? null : _registerGeofence,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Démarrer / enregistrer'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _stopGeofence,
                        icon: const Icon(Icons.stop),
                        label: const Text('Arrêter / supprimer'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _refreshDiagnostics,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Rafraîchir diagnostics'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _clearEvents,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Effacer diagnostics'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Historique chronologique',
                children: <Widget>[
                  if (_events.isEmpty)
                    const Text('Aucun événement diagnostique enregistré.'),
                  for (final event in _events.reversed)
                    _EventTile(event: event),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatPosition(Position? position) {
    if (position == null) {
      return 'Non capturée';
    }
    return '${position.latitude.toStringAsFixed(6)}, '
        '${position.longitude.toStringAsFixed(6)} '
        '(±${position.accuracy.toStringAsFixed(1)} m)';
  }

  String _formatForegroundPermission(LocationPermission? status) {
    if (status == null) {
      return 'Inconnue';
    }
    if (status == LocationPermission.whileInUse ||
        status == LocationPermission.always) {
      return 'Accordée';
    }
    if (status == LocationPermission.deniedForever) {
      return 'Refusée définitivement';
    }
    if (status == LocationPermission.denied) {
      return 'Refusée';
    }
    if (status == LocationPermission.unableToDetermine) {
      return 'Indéterminée';
    }
    return status.name;
  }

  String _formatBackgroundPermission(LocationPermission? status) {
    if (status == null) {
      return 'Inconnue';
    }
    if (status == LocationPermission.always) {
      return 'Accordée';
    }
    if (status == LocationPermission.whileInUse) {
      return 'Premier plan seulement';
    }
    if (status == LocationPermission.deniedForever) {
      return 'Refusée définitivement';
    }
    if (status == LocationPermission.denied) {
      return 'Refusée';
    }
    if (status == LocationPermission.unableToDetermine) {
      return 'Indéterminée';
    }
    return status.name;
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return 'Sans objet';
    }
    return '${value.toLocal()}';
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.statusMessage});

  final String statusMessage;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.primary),
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Prototype expérimental',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Écran diagnostique isolé. Ne pas utiliser pour suivre des employés ou valider une présence réelle.',
            ),
            const SizedBox(height: 8),
            Text(statusMessage),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 170,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final GeofenceDiagnosticEvent event;

  @override
  Widget build(BuildContext context) {
    final subtitle = <String>[
      'Callback: ${event.callbackReceivedAtUtc.toLocal()}',
      if (event.deviceEventAtUtc != null)
        'Événement: ${event.deviceEventAtUtc!.toLocal()}',
      if (event.latitude != null && event.longitude != null)
        'Position: ${event.latitude!.toStringAsFixed(6)}, ${event.longitude!.toStringAsFixed(6)}',
      if (event.accuracyMeters != null)
        'Précision: ±${event.accuracyMeters!.toStringAsFixed(1)} m',
      'État: ${event.stateAfter}',
      event.message,
      if (event.processingError != null) 'Erreur: ${event.processingError}',
    ];

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        event.acceptedByStateMachine ? Icons.check_circle : Icons.info_outline,
      ),
      title: Text('${event.type} - ${event.geofenceId ?? 'sans géorepérage'}'),
      subtitle: Text(subtitle.join('\n')),
    );
  }
}
