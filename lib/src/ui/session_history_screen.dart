import 'package:flutter/material.dart';

import '../attendance/attendance_models.dart';
import '../attendance/history/session_history_controller.dart';
import '../time/business_time.dart';

/// Kept inside AuthGate's home subtree, including details: no private route can
/// remain above login/logout. Home owns the controller and attendance sibling.
class SessionHistoryScreen extends StatelessWidget {
  const SessionHistoryScreen({
    super.key,
    required this.controller,
    required this.onBack,
  });
  final SessionHistoryController controller;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Accueil'),
          ),
        ),
        Text('Historique', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Vos sessions des six derniers mois, selon l’heure de Montréal.',
        ),
        const SizedBox(height: 8),
        Text('Depuis le ${formatBusinessTime(controller.window.fromUtc)}'),
        if (!controller.repository.capabilities.notes ||
            !controller.repository.capabilities.review)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Certaines notes ou informations de révision ne sont pas disponibles dans cet historique.',
            ),
          ),
        if (controller.failure != null) ...[
          Text(controller.failure!.message, key: const Key('history-error')),
          if (controller.isCurrent)
            TextButton(
              onPressed: controller.loadMore,
              child: const Text('Réessayer'),
            ),
        ],
        if (controller.loaded &&
            controller.sessions.isEmpty &&
            controller.failure == null)
          const Text('Aucune session pour cette période.'),
        for (final session in controller.sessions)
          Card(
            child: ExpansionTile(
              key: ValueKey(session.id),
              title: Text(formatBusinessTime(session.startedAt)),
              subtitle: Text('${_status(session)} · ${_location(session)}'),
              childrenPadding: const EdgeInsets.all(16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Entrée : ${formatBusinessTime(session.startedAt)}'),
                Text(
                  session.endedAt == null
                      ? 'Sortie : en cours'
                      : 'Sortie : ${formatBusinessTime(session.endedAt!)}',
                ),
                Text('Lieu : ${_location(session)}'),
                Text(
                  'Description du chantier : ${session.siteDescription ?? 'Non renseignée'}',
                ),
                Text('Statut : ${_status(session)}'),
                if (controller.repository.capabilities.notes)
                  Text(
                    session.employeeNote == null
                        ? 'Note : aucune note enregistrée'
                        : 'Note : ${session.employeeNote}',
                  ),
                if (controller.repository.capabilities.review)
                  Text('Révision : ${_review(session.reviewStatus)}'),
              ],
            ),
          ),
        if (controller.loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          ),
        if (!controller.loading &&
            controller.hasMore &&
            controller.failure == null)
          OutlinedButton(
            onPressed: controller.loadMore,
            child: const Text('Charger plus'),
          ),
      ],
    ),
  );
  static String _location(WorkSession session) =>
      switch (session.locationContext) {
        'factory' => 'Usine',
        'external_worksite' => 'Chantier extérieur',
        _ => 'Localisation non vérifiée',
      };
  static String _status(WorkSession session) =>
      switch (session.lifecycleStatus) {
        'active' => 'En cours',
        'closed_manual' => 'Fermée manuellement',
        'closed_automatic' => 'Fermée automatiquement',
        'closed_admin' => 'Fermée par l’administration',
        _ => 'Annulée',
      };
  static String _review(String? status) => switch (status) {
    'normal' => 'Aucune anomalie signalée',
    'anomaly_open' => 'À examiner',
    'correction_pending' => 'Correction en attente',
    'reviewed' => 'Examinée',
    'corrected' => 'Corrigée',
    'disputed' => 'Contestée',
    _ => 'Non disponible',
  };
}
