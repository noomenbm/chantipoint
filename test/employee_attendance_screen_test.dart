import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/attendance/journal/journal_record.dart';
import 'package:chantipoint/src/attendance/location_evidence.dart';
import 'package:chantipoint/src/ui/employee_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/employee_workflow_fixture.dart';
import 'support/journal_fixtures.dart';

Future<void> mount(WidgetTester tester, EmployeeWorkflowFixture f) async {
  await tester.pumpWidget(
    MaterialApp(home: EmployeeAttendanceScreen(workflow: f.workflow)),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  late EmployeeWorkflowFixture f;
  setUp(() => f = EmployeeWorkflowFixture());
  tearDown(() => f.workflow.dispose());

  for (final checkout in [false, true]) {
    final limit = checkout ? 1000 : 500;
    for (final offset in [-1, 0, 1]) {
      testWidgets(
        'pasted combining ${checkout ? "note" : "description"} at ${limit + offset} code points',
        (tester) async {
          if (checkout) {
            f.setActive(workflowSession());
            f.operations.canonical.result = workflowSession(closed: true);
          }
          await mount(tester, f);
          if (checkout) {
            await tester.ensureVisible(
              find.byType(DropdownButton<CheckoutNoteAction>),
            );
            await tester.tap(find.byType(DropdownButton<CheckoutNoteAction>));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Remplacer la note à la sortie').last);
            await tester.pumpAndSettle();
          }
          final points = limit + offset;
          final original =
              '${'e\u0301' * (points ~/ 2)}${points.isOdd ? 'é' : ''}';
          final field = find.byType(TextField);
          await tester.ensureVisible(field);
          await tester.enterText(field, original);
          await tester.pump();
          expect(tester.widget<TextField>(field).controller!.text, original);
          expect(
            find.text('$points / $limit caractères Unicode'),
            findsOneWidget,
          );
          final button = checkout ? 'Pointer une sortie' : 'Pointer une entrée';
          await press(tester, button);
          await tester.pumpAndSettle();
          if (offset > 0) {
            expect(
              find.text('Corrigez la saisie avant de pointer.'),
              findsOneWidget,
            );
            expect(
              find.textContaining('$limit caractères Unicode.'),
              findsWidgets,
            );
            expect(
              find.textContaining('Actualisation indisponible'),
              findsNothing,
            );
            expect(tester.widget<TextField>(field).controller!.text, original);
            expect(tester.widget<TextField>(field).enabled, isTrue);
            expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
            expect(f.location.calls, 0);
            expect(f.keys.calls, 0);
            expect(f.operations.disk.writes, 0);
            expect(f.operations.transport.calls, isEmpty);
            const corrected = '  À Montréal, l’équipe termine la réparation.  ';
            await tester.ensureVisible(field);
            await tester.enterText(field, corrected);
            await tester.pumpAndSettle();
            expect(
              find.textContaining('$limit caractères Unicode.'),
              findsNothing,
            );
            await press(tester, button);
            await tester.pumpAndSettle();
            expect(find.text('Pointage confirmé et vérifié.'), findsOneWidget);
            expect(
              f.operations.transport.calls.single.command.parameters[checkout
                  ? 'p_employee_note'
                  : 'p_site_description'],
              corrected,
            );
            expect(f.location.calls, 1);
            expect(f.keys.calls, 1);
          } else {
            expect(find.text('Pointage confirmé et vérifié.'), findsOneWidget);
            expect(
              f.operations.transport.calls.single.command.parameters[checkout
                  ? 'p_employee_note'
                  : 'p_site_description'],
              original,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'pasting over the grapheme limit does not silently truncate text',
    (tester) async {
      await mount(tester, f);
      final text = 'é' * 501;
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        text,
      );
      expect(find.text('501 / 500 caractères Unicode'), findsOneWidget);
      await press(tester, 'Pointer une entrée');
      await tester.pumpAndSettle();
      expect(find.text('Corrigez la saisie avant de pointer.'), findsOneWidget);
      expect(f.location.calls, 0);
    },
  );

  testWidgets('French check-in accepts description without a mode picker', (
    tester,
  ) async {
    await mount(tester, f);
    expect(find.text('Mon pointage'), findsOneWidget);
    expect(find.text('Aucune session active.'), findsOneWidget);
    expect(find.byType(DropdownButton<CheckoutNoteAction>), findsNothing);
    expect(find.text('Enregistrer la note'), findsNothing);
    await tester.enterText(find.byType(TextField), '  Chantier fictif  ');
    await press(tester, 'Pointer une entrée');
    await tester.pumpAndSettle();
    expect(
      f
          .operations
          .transport
          .calls
          .single
          .command
          .parameters['p_site_description'],
      '  Chantier fictif  ',
    );
    expect(find.text('Pointage confirmé et vérifié.'), findsOneWidget);
  });

  for (final entry in {
    'factory': 'À l’usine',
    'external_worksite': 'Chantier extérieur',
    'location_unverified': 'Lieu non vérifié — le pointage reste enregistré',
  }.entries) {
    testWidgets('canonical ${entry.key} and Montreal time display', (
      tester,
    ) async {
      f.setActive(workflowSession(context: entry.key, review: 'anomaly_open'));
      await mount(tester, f);
      expect(find.text(entry.value), findsOneWidget);
      expect(
        find.text('Entrée : 15/10/2026 à 23:45 (heure de Montréal, UTC−04:00)'),
        findsOneWidget,
      );
      expect(
        find.text('Note enregistrée : Note canonique fictive'),
        findsOneWidget,
      );
      expect(find.text('Vérification : à examiner'), findsOneWidget);
      expect(find.textContaining('America/Toronto'), findsNothing);
      expect(find.textContaining('45.123'), findsNothing);
      expect(find.textContaining('fictional-workflow'), findsNothing);
    });
  }

  for (final entry in {
    'normal': 'aucune anomalie signalée',
    'correction_pending': 'correction en attente',
    'reviewed': 'examinée',
    'corrected': 'corrigée',
    'disputed': 'contestée',
  }.entries) {
    testWidgets('review status ${entry.key} has a French label', (
      tester,
    ) async {
      f.setActive(workflowSession(review: entry.key));
      await mount(tester, f);
      expect(find.text('Vérification : ${entry.value}'), findsOneWidget);
    });
  }

  for (final entry in <String?, String>{
    null: 'Aucune note enregistrée.',
    '': 'Note enregistrée vide.',
  }.entries) {
    testWidgets('saved note ${entry.key ?? "null"} stays distinct from empty', (
      tester,
    ) async {
      f.setActive(workflowSession(note: entry.key, review: null));
      await mount(tester, f);
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('État de vérification indisponible'), findsOneWidget);
    });
  }

  for (final action in CheckoutNoteAction.values) {
    testWidgets(
      'checkout UI sends explicit ${action.name}, not an unsaved note',
      (tester) async {
        f.setActive(workflowSession());
        f.operations.canonical.result = workflowSession(closed: true);
        await mount(tester, f);
        if (action != CheckoutNoteAction.preserve) {
          await tester.ensureVisible(
            find.byType(DropdownButton<CheckoutNoteAction>),
          );
          await tester.tap(find.byType(DropdownButton<CheckoutNoteAction>));
          await tester.pumpAndSettle();
          await tester.tap(
            find
                .text(
                  action == CheckoutNoteAction.replace
                      ? 'Remplacer la note à la sortie'
                      : 'Effacer la note à la sortie',
                )
                .last,
          );
          await tester.pumpAndSettle();
        }
        if (action == CheckoutNoteAction.replace) {
          expect(find.text('Note finale (brouillon)'), findsOneWidget);
          await tester.enterText(
            find.byType(TextField),
            '  Note finale fictive  ',
          );
          expect(
            find.text('Note enregistrée : Note canonique fictive'),
            findsOneWidget,
          );
        }
        await press(tester, 'Pointer une sortie');
        await tester.pumpAndSettle();
        final parameters =
            f.operations.transport.calls.single.command.parameters;
        expect(parameters['p_note_action'], action.name);
        expect(
          parameters['p_employee_note'],
          action == CheckoutNoteAction.replace
              ? '  Note finale fictive  '
              : null,
        );
        expect(find.text('Session terminée'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'location pending announces progress and duplicate taps are disabled',
    (tester) async {
      await mount(tester, f);
      final fix = Completer<LocationEvidence>();
      f.location.onAcquire = () => fix.future;
      await press(tester, 'Pointer une entrée');
      expect(
        find.textContaining('ne signifie pas que le pointage a échoué'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .semanticsLabel,
        contains('Recherche ponctuelle'),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Pointer une entrée'));
      expect(f.keys.calls, 1);
      fix.complete(const LocationEvidence());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('server wait is distinct from acquisition and confirmation', (
    tester,
  ) async {
    await mount(tester, f);
    final reply = Completer<AttendanceTransportReply>();
    f.operations.transport.onDispatch = (_, _) => reply.future;
    await press(tester, 'Pointer une entrée');
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('En attente de la confirmation du serveur…'),
      findsOneWidget,
    );
    expect(find.text('Pointage confirmé et vérifié.'), findsNothing);
    final command = f.operations.transport.calls.single.command;
    reply.complete(
      AttendanceTransportReply.acknowledged(
        JournalJson.encode(journalReceipt(command)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pointage confirmé et vérifié.'), findsOneWidget);
    expect(f.workflow.canCheckOut, isFalse);
  });

  testWidgets(
    'pending replay miss offers verification, not a replacement command',
    (tester) async {
      f.operations.inject(recordAt(JournalPhase.uncertain));
      f.operations.transport.onDispatch = (_, _) async =>
          const AttendanceTransportReply.replayMiss();
      await mount(tester, f);
      expect(
        find.textContaining('Son résultat reste incertain'),
        findsOneWidget,
      );
      await press(tester, 'Vérifier le pointage conservé');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Son résultat reste incertain'),
        findsOneWidget,
      );
      expect(f.operations.transport.calls.single.replayOnly, isTrue);
      expect(f.location.calls, 0);
    },
  );

  testWidgets(
    'blocked journal exposes safe French guidance without receipt or IDs',
    (tester) async {
      f.operations.inject(recordAt(JournalPhase.blocked));
      await mount(tester, f);
      expect(
        find.textContaining('Pointage bloqué sur cet appareil'),
        findsOneWidget,
      );
      expect(find.textContaining(journalSessionId), findsNothing);
      expect(find.text('Vérifier le pointage conservé'), findsNothing);
      expect(f.workflow.canCheckIn, isFalse);
    },
  );

  testWidgets(
    'confirmed but refresh unavailable does not invent session details',
    (tester) async {
      f.operations.canonical.result = null;
      await mount(tester, f);
      await press(tester, 'Pointer une entrée');
      await tester.pumpAndSettle();
      expect(find.textContaining('Confirmation sécurisée'), findsOneWidget);
      expect(find.text('Session active'), findsNothing);
      expect(f.workflow.canCheckIn, isFalse);
    },
  );

  testWidgets(
    'refresh failure has retry guidance and does not claim no active session',
    (tester) async {
      f.active.onRead = () async => throw StateError('fixture');
      await mount(tester, f);
      expect(find.textContaining('Actualisation indisponible'), findsOneWidget);
      expect(find.text('Aucune session active.'), findsNothing);
      f.active.onRead = null;
      await press(tester, 'Actualiser le pointage');
      await tester.pumpAndSettle();
      expect(f.workflow.canCheckIn, isTrue);
    },
  );

  testWidgets(
    'auth revalidation clears private drafts; fresh action requires explicit refresh',
    (tester) async {
      await mount(tester, f);
      await tester.enterText(find.byType(TextField), 'Brouillon privé fictif');
      f.invalidate();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('choisissez à nouveau votre action'),
        findsOneWidget,
      );
      expect(find.text('Brouillon privé fictif'), findsNothing);
      expect(f.operations.transport.calls, isEmpty);
      await press(tester, 'Actualiser le pointage');
      await tester.pumpAndSettle();
      expect(f.workflow.canCheckIn, isTrue);
      expect(f.operations.transport.calls, isEmpty);
    },
  );

  testWidgets(
    'route disposal after submission retains receipt with no widget publication',
    (tester) async {
      await mount(tester, f);
      final reply = Completer<AttendanceTransportReply>();
      f.operations.transport.onDispatch = (_, _) => reply.future;
      await press(tester, 'Pointer une entrée');
      await tester.pump(const Duration(milliseconds: 100));
      final command = f.operations.transport.calls.single.command;
      final context = f.contexts.last;
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(context.releaseCalls, 0);
      reply.complete(
        AttendanceTransportReply.acknowledged(
          JournalJson.encode(journalReceipt(command)),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.operations.record!.phase, JournalPhase.confirmed);
      expect(context.releaseCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact phone, large text and keyboard keep checkout scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      f.setActive(workflowSession(note: 'Texte fictif ' * 50));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: EmployeeAttendanceScreen(workflow: f.workflow),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byType(DropdownButton<CheckoutNoteAction>),
      );
      await tester.tap(find.byType(DropdownButton<CheckoutNoteAction>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remplacer la note à la sortie').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextField));
      await tester.showKeyboard(find.byType(TextField));
      await tester.enterText(
        find.byType(TextField),
        'Brouillon compact fictif',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Pointer une sortie'));
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    },
  );
}
