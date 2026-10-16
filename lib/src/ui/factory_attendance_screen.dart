import 'dart:async';

import 'package:flutter/material.dart';

import '../attendance/attendance_controller.dart';
import '../time/business_time.dart';

class FactoryAttendanceScreen extends StatefulWidget {
  const FactoryAttendanceScreen({super.key, required this.controller});
  final AttendanceController controller;

  @override
  State<FactoryAttendanceScreen> createState() =>
      _FactoryAttendanceScreenState();
}

class _FactoryAttendanceScreenState extends State<FactoryAttendanceScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refresh());
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final state = controller.state;
        final active = state.active;
        final completed = state.completed;
        final busy =
            state.status == AttendanceStatus.loading ||
            state.status == AttendanceStatus.submitting;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pointage à l’usine',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (state.message != null) ...[
              Semantics(liveRegion: true, child: Text(state.message!)),
              const SizedBox(height: 16),
            ],
            if (busy) ...[
              const LinearProgressIndicator(
                semanticsLabel: 'Vérification du pointage',
              ),
              const SizedBox(height: 12),
              Text(
                state.status == AttendanceStatus.submitting
                    ? 'En attente de la confirmation du serveur…'
                    : 'Vérification du pointage en cours…',
              ),
            ],
            if (completed != null) ...[
              Text(
                completed.lifecycleStatus == 'voided'
                    ? 'Session annulée — À l’usine'
                    : 'Session terminée — À l’usine',
              ),
              Text('Entrée : ${formatBusinessTime(completed.startedAt)}'),
              Text('Sortie : ${formatBusinessTime(completed.endedAt!)}'),
              const SizedBox(height: 16),
            ],
            if (active != null) ...[
              Text(
                active.isFactory
                    ? 'Session active — À l’usine'
                    : 'Session active — Chantier extérieur',
              ),
              Text('Entrée : ${formatBusinessTime(active.startedAt)}'),
              if (!active.isFactory)
                const Text(
                  'Le pointage sur chantier extérieur n’est pas disponible dans cette version.',
                ),
              const SizedBox(height: 16),
            ] else if (state.status == AttendanceStatus.ready)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('Aucune session active.'),
              ),
            if (controller.canCheckIn)
              FilledButton.icon(
                onPressed: controller.checkIn,
                icon: const Icon(Icons.login),
                label: const Text('Pointer une entrée à l’usine'),
              ),
            if (controller.canCheckOut)
              FilledButton.icon(
                onPressed: controller.checkOut,
                icon: const Icon(Icons.logout),
                label: const Text('Pointer une sortie'),
              ),
            if (state.status == AttendanceStatus.pending)
              FilledButton(
                onPressed: controller.retryPending,
                child: const Text('Vérifier et réessayer le pointage'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : controller.refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Actualiser le pointage'),
            ),
          ],
        );
      },
    );
  }
}
