import 'dart:async';

import 'package:flutter/material.dart';

import '../attendance/attendance_v2_requests.dart';
import '../attendance/attendance_action_capture.dart';
import '../attendance/employee_attendance_workflow.dart';
import '../time/business_time.dart';

/// Isolated screen: deliberately absent from AuthGate and application routes.
/// Owns only its injected presentation workflow, never the shared auth owner or
/// operation coordinator. Disposal does not cancel submitted attendance work.
class EmployeeAttendanceScreen extends StatefulWidget {
  const EmployeeAttendanceScreen({super.key, required this.workflow});
  final EmployeeAttendanceWorkflow workflow;

  @override
  State<EmployeeAttendanceScreen> createState() =>
      _EmployeeAttendanceScreenState();
}

class _EmployeeAttendanceScreenState extends State<EmployeeAttendanceScreen> {
  final _description = TextEditingController();
  final _finalNote = TextEditingController();
  CheckoutNoteAction _noteAction = CheckoutNoteAction.preserve;
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    widget.workflow.addListener(_workflowChanged);
    unawaited(widget.workflow.refresh());
  }

  void _workflowChanged() {
    final state = widget.workflow.state;
    if (state.status == EmployeeAttendanceStatus.authorizationUnavailable) {
      _description.clear();
      _finalNote.clear();
      _noteAction = CheckoutNoteAction.preserve;
      _sessionId = null;
    } else if (state.session != null && state.session!.id != _sessionId) {
      _sessionId = state.session!.id;
      _finalNote.clear();
      _noteAction = CheckoutNoteAction.preserve;
    }
  }

  @override
  void didUpdateWidget(covariant EmployeeAttendanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workflow != widget.workflow) {
      oldWidget.workflow.removeListener(_workflowChanged);
      oldWidget.workflow.dispose();
      _description.clear();
      _finalNote.clear();
      _noteAction = CheckoutNoteAction.preserve;
      _sessionId = null;
      widget.workflow.addListener(_workflowChanged);
      unawaited(widget.workflow.refresh());
    }
  }

  @override
  void dispose() {
    widget.workflow.removeListener(_workflowChanged);
    widget.workflow.dispose();
    _description.dispose();
    _finalNote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mon pointage')),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: widget.workflow,
        builder: (context, _) {
          final workflow = widget.workflow;
          final state = workflow.state;
          final session = state.session;
          final status = state.status;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _message(status),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (workflow.isBusy) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(semanticsLabel: _message(status)),
                    ],
                    const SizedBox(height: 16),
                    if (state.message != null) ...[
                      Semantics(liveRegion: true, child: Text(state.message!)),
                      const SizedBox(height: 16),
                    ],
                    if (session != null) ...[
                      Text(
                        session.isActive
                            ? 'Session active'
                            : session.lifecycleStatus == 'voided'
                            ? 'Session annulée'
                            : 'Session terminée',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(switch (session.locationContext) {
                        'factory' => 'À l’usine',
                        'external_worksite' => 'Chantier extérieur',
                        _ => 'Lieu non vérifié — le pointage reste enregistré',
                      }),
                      Text('Entrée : ${formatBusinessTime(session.startedAt)}'),
                      if (session.endedAt != null)
                        Text(
                          'Sortie : ${formatBusinessTime(session.endedAt!)}',
                        ),
                      if (session.siteDescription != null)
                        Text('Lieu décrit : ${session.siteDescription}'),
                      Text(_reviewLabel(session.reviewStatus)),
                      const SizedBox(height: 12),
                      Text(switch (session.employeeNote) {
                        null => 'Aucune note enregistrée.',
                        '' => 'Note enregistrée vide.',
                        final note => 'Note enregistrée : $note',
                      }),
                      const SizedBox(height: 16),
                    ] else if (status == EmployeeAttendanceStatus.ready)
                      const Text('Aucune session active.'),
                    if (session?.isActive == true) ...[
                      const Text('Note pour la sortie'),
                      DropdownButton<CheckoutNoteAction>(
                        isExpanded: true,
                        value: _noteAction,
                        onChanged: workflow.canCheckOut
                            ? (value) => setState(() {
                                _noteAction = value!;
                                workflow.clearInputError();
                              })
                            : null,
                        items: const [
                          DropdownMenuItem(
                            value: CheckoutNoteAction.preserve,
                            child: Text('Conserver la note enregistrée'),
                          ),
                          DropdownMenuItem(
                            value: CheckoutNoteAction.replace,
                            child: Text('Remplacer la note à la sortie'),
                          ),
                          DropdownMenuItem(
                            value: CheckoutNoteAction.clear,
                            child: Text('Effacer la note à la sortie'),
                          ),
                        ],
                      ),
                      if (_noteAction == CheckoutNoteAction.replace)
                        TextField(
                          controller: _finalNote,
                          enabled: workflow.canCheckOut,
                          minLines: 2,
                          maxLines: 5,
                          onChanged: (_) {
                            workflow.clearInputError();
                            setState(() {});
                          },
                          decoration: InputDecoration(
                            labelText: 'Note finale (brouillon)',
                            helperText: 'Un texte vide remplace aussi la note.',
                            helperMaxLines: 2,
                            counterText:
                                '${_finalNote.text.runes.length} / '
                                '${AttendanceActionCapture.finalNoteLimit} caractères Unicode',
                            errorText: validateAttendanceInput(
                              note: CheckoutNoteIntent.replace(_finalNote.text),
                            )?.message,
                            errorMaxLines: 4,
                          ),
                        ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: workflow.canCheckOut
                            ? () {
                                FocusScope.of(context).unfocus();
                                unawaited(
                                  workflow.checkOut(
                                    note: switch (_noteAction) {
                                      CheckoutNoteAction.preserve =>
                                        const CheckoutNoteIntent.preserve(),
                                      CheckoutNoteAction.clear =>
                                        const CheckoutNoteIntent.clear(),
                                      CheckoutNoteAction.replace =>
                                        CheckoutNoteIntent.replace(
                                          _finalNote.text,
                                        ),
                                    },
                                  ),
                                );
                              }
                            : null,
                        icon: const Icon(Icons.logout),
                        label: const Text('Pointer une sortie'),
                      ),
                    ] else ...[
                      TextField(
                        controller: _description,
                        enabled: workflow.canCheckIn,
                        onChanged: (_) {
                          workflow.clearInputError();
                          setState(() {});
                        },
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: 'Description du lieu (facultative)',
                          counterText:
                              '${_description.text.runes.length} / '
                              '${AttendanceActionCapture.siteDescriptionLimit} caractères Unicode',
                          errorText: validateAttendanceInput(
                            siteDescription: _description.text,
                          )?.message,
                          errorMaxLines: 4,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: workflow.canCheckIn
                            ? () {
                                FocusScope.of(context).unfocus();
                                final text = _description.text;
                                unawaited(
                                  workflow.checkIn(
                                    siteDescription: text.isEmpty ? null : text,
                                  ),
                                );
                              }
                            : null,
                        icon: const Icon(Icons.login),
                        label: const Text('Pointer une entrée'),
                      ),
                    ],
                    if (workflow.canConsume) ...[
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: workflow.consume,
                        child: const Text('Terminer la vérification'),
                      ),
                    ],
                    if (state.recovery != AttendanceRecoveryAction.none) ...[
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: workflow.canRecover
                            ? workflow.recover
                            : null,
                        child: Text(
                          state.recovery ==
                                  AttendanceRecoveryAction.recoverEmpty
                              ? 'Réessayer la vérification sur cet appareil'
                              : 'Vérifier le pointage conservé',
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: workflow.isBusy ? null : workflow.refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Actualiser le pointage'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

String _message(EmployeeAttendanceStatus status) => switch (status) {
  EmployeeAttendanceStatus.loading => 'Vérification du pointage en cours…',
  EmployeeAttendanceStatus.ready => 'Votre pointage est à jour.',
  EmployeeAttendanceStatus.invalidInput =>
    'Corrigez la saisie avant de pointer.',
  EmployeeAttendanceStatus.consumingConfirmation =>
    'Finalisation de la vérification sur cet appareil…',
  EmployeeAttendanceStatus.consumptionUnresolved =>
    'La vérification sur cet appareil reste incertaine. Actualisez puis réessayez '
        'la vérification avant un nouveau pointage. Aucun nouveau pointage '
        'n’est autorisé pour le moment.',
  EmployeeAttendanceStatus.acquiringLocation =>
    'Recherche ponctuelle de la position… Une position indisponible ne signifie '
        'pas que le pointage a échoué.',
  EmployeeAttendanceStatus.awaitingConfirmation =>
    'En attente de la confirmation du serveur…',
  EmployeeAttendanceStatus.confirmed => 'Pointage confirmé et vérifié.',
  EmployeeAttendanceStatus.pending =>
    'Pointage à vérifier. Son résultat reste incertain. Ne créez pas un nouveau '
        'pointage pour le remplacer.',
  EmployeeAttendanceStatus.blocked =>
    'Pointage bloqué sur cet appareil. Actualisez ou contactez votre '
        'administrateur avant de continuer.',
  EmployeeAttendanceStatus.authorizationUnavailable =>
    'Votre accès doit être vérifié. Une fois l’autorisation rétablie, actualisez '
        'puis choisissez à nouveau votre action. Aucune nouvelle tentative '
        'automatique ne sera lancée.',
  EmployeeAttendanceStatus.refreshUnavailable =>
    'Actualisation indisponible. Réessayez de vérifier le pointage avant de '
        'continuer.',
  EmployeeAttendanceStatus.confirmedNeedsRefresh =>
    'Confirmation sécurisée, mais les détails du serveur sont indisponibles. '
        'Actualisez avant de continuer.',
};

String _reviewLabel(String? status) => switch (status) {
  'normal' => 'Vérification : aucune anomalie signalée',
  'anomaly_open' => 'Vérification : à examiner',
  'correction_pending' => 'Vérification : correction en attente',
  'reviewed' => 'Vérification : examinée',
  'corrected' => 'Vérification : corrigée',
  'disputed' => 'Vérification : contestée',
  _ => 'État de vérification indisponible',
};
