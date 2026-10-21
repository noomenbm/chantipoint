// C6.2 safety fallback: no standalone note writer exists or is simulated here.
import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_operation_transport.dart';
import 'package:chantipoint/src/attendance/attendance_v2_requests.dart';
import 'package:chantipoint/src/attendance/journal/journal_json.dart';
import 'package:chantipoint/src/ui/employee_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/employee_workflow_fixture.dart';
import 'support/journal_fixtures.dart';

final noteField = find.byKey(const ValueKey('checkout-note'));

Future<void> mount(WidgetTester tester, EmployeeWorkflowFixture f) async {
  await tester.pumpWidget(
    MaterialApp(home: EmployeeAttendanceScreen(workflow: f.workflow)),
  );
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, CheckoutNoteAction action) async {
  final tile = find.byWidgetPredicate(
    (w) => w is RadioListTile<CheckoutNoteAction> && w.value == action,
  );
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

Future<void> checkout(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Pointer une sortie'));
  await tester.tap(find.text('Pointer une sortie'));
  await tester.pumpAndSettle();
}

void main() {
  late EmployeeWorkflowFixture f;
  setUp(() {
    f = EmployeeWorkflowFixture();
    f.setActive(workflowSession());
    f.operations.canonical.result = workflowSession(closed: true);
  });
  tearDown(() => f.workflow.dispose());

  testWidgets('visible canonical note and explicit disabled standalone save', (
    tester,
  ) async {
    await mount(tester, f);
    expect(find.text('Note de la session'), findsOneWidget);
    expect(find.text('Note à la sortie'), findsOneWidget);
    expect(find.byType(RadioListTile<CheckoutNoteAction>), findsNWidgets(3));
    expect(noteField, findsOneWidget); // No picker hides the final-note field.
    expect(tester.widget<TextField>(noteField).enabled, isFalse);
    final save = find.widgetWithText(OutlinedButton, 'Enregistrer la note');
    expect(tester.widget<OutlinedButton>(save).onPressed, isNull);
    expect(
      find.textContaining('pendant la session n’est pas encore'),
      findsOneWidget,
    );
    final contexts = f.contexts.length;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(f.contexts.length, contexts);
    expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
    expect(f.operations.transport.calls, isEmpty);
    expect(f.operations.disk.writes, 0);
    expect(f.location.calls, 0);
    expect(f.keys.calls, 0);
  });

  for (final action in CheckoutNoteAction.values) {
    testWidgets('retained final draft is sent only for ${action.name}', (
      tester,
    ) async {
      await mount(tester, f);
      await choose(tester, CheckoutNoteAction.replace);
      await tester.ensureVisible(noteField);
      const draft = '  Réparation terminée, équipe à Montréal.  ';
      await tester.enterText(noteField, draft);
      await choose(tester, action);
      expect(tester.widget<TextField>(noteField).controller!.text, draft);
      expect(
        find.text('Note enregistrée : Note canonique fictive'),
        findsOneWidget,
      );
      expect(find.text('Note enregistrée : $draft'), findsNothing);
      expect(f.operations.transport.calls, isEmpty);
      await checkout(tester);
      final params = f.operations.transport.calls.single.command.parameters;
      expect(params['p_note_action'], action.name);
      expect(
        params['p_employee_note'],
        action == CheckoutNoteAction.replace ? draft : null,
      );
      expect(f.contexts.every((c) => c.releaseCalls == 1), isTrue);
    });
  }

  for (final text in ['', 'Note canonique fictive']) {
    testWidgets(
      'explicit replacement preserves exact ${text.isEmpty ? "empty" : "unchanged"} text',
      (tester) async {
        await mount(tester, f);
        await choose(tester, CheckoutNoteAction.replace);
        await tester.ensureVisible(noteField);
        await tester.enterText(noteField, text);
        await checkout(tester);
        final params = f.operations.transport.calls.single.command.parameters;
        expect(params['p_note_action'], 'replace');
        expect(params['p_employee_note'], text);
      },
    );
  }

  testWidgets('over-limit inactive draft cannot block preserve or be sent', (
    tester,
  ) async {
    await mount(tester, f);
    await choose(tester, CheckoutNoteAction.replace);
    await tester.ensureVisible(noteField);
    await tester.enterText(noteField, 'e\u0301' * 501);
    await tester.pump();
    expect(
      tester.widget<TextField>(noteField).decoration!.errorText,
      isNotNull,
    );
    await choose(tester, CheckoutNoteAction.preserve);
    expect(tester.widget<TextField>(noteField).decoration!.errorText, isNull);
    await checkout(tester);
    expect(
      f.operations.transport.calls.single.command.parameters['p_employee_note'],
      isNull,
    );
  });

  testWidgets('auth change clears private draft and disables note choices', (
    tester,
  ) async {
    await mount(tester, f);
    await choose(tester, CheckoutNoteAction.replace);
    await tester.ensureVisible(noteField);
    await tester.enterText(noteField, 'Brouillon privé fictif');
    f.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('Brouillon privé fictif'), findsNothing);
    expect(noteField, findsNothing);
    await f.workflow.refresh();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(noteField).controller!.text, isEmpty);
    expect(tester.widget<TextField>(noteField).enabled, isFalse);
    expect(f.operations.transport.calls, isEmpty);
  });

  testWidgets('session switch never carries final draft to another session', (
    tester,
  ) async {
    await mount(tester, f);
    await choose(tester, CheckoutNoteAction.replace);
    await tester.ensureVisible(noteField);
    await tester.enterText(noteField, 'Brouillon de la première session');
    f.setActive(workflowSession(id: journalOtherId));
    await f.workflow.refresh();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(noteField).controller!.text, isEmpty);
    expect(tester.widget<TextField>(noteField).enabled, isFalse);
    expect(f.operations.transport.calls, isEmpty);
  });

  testWidgets('submitted checkout freezes note and double tap sends once', (
    tester,
  ) async {
    await mount(tester, f);
    await choose(tester, CheckoutNoteAction.replace);
    await tester.ensureVisible(noteField);
    const draft = '  Travail terminé.  ';
    await tester.enterText(noteField, draft);
    final response = Completer<AttendanceTransportReply>();
    f.operations.transport.onDispatch = (_, _) => response.future;
    await tester.ensureVisible(find.text('Pointer une sortie'));
    await tester.tap(find.text('Pointer une sortie'));
    await tester.tap(find.text('Pointer une sortie'));
      await tester.pump(const Duration(milliseconds: 100));
      // The pending state hides the canonical selection and note controls.
      expect(noteField, findsNothing);
      expect(find.byType(RadioListTile<CheckoutNoteAction>), findsNothing);
      expect(f.workflow.canCheckOut, isFalse);
    final call = f.operations.transport.calls.single;
    expect(call.command.parameters['p_employee_note'], draft);
    response.complete(
      AttendanceTransportReply.acknowledged(
        JournalJson.encode(journalReceipt(call.command)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pointage confirmé et vérifié.'), findsOneWidget);
    expect(f.operations.transport.calls, hasLength(1));
  });

  testWidgets(
    'compact keyboard layout exposes all choices and draft feedback',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await mount(tester, f);
      await choose(tester, CheckoutNoteAction.replace);
      await tester.ensureVisible(noteField);
      await tester.showKeyboard(noteField);
      await tester.enterText(noteField, 'é' * 1000);
      await tester.pump();
      expect(find.textContaining('Brouillon non enregistré.'), findsOneWidget);
      await tester.ensureVisible(find.text('Pointer une sortie'));
      expect(tester.takeException(), isNull);
    },
  );
}
