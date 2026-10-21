import 'dart:async';

import 'package:chantipoint/src/attendance/attendance_auth_owner.dart';
import 'package:chantipoint/src/auth/auth_failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/attendance_auth_backend.dart';
import 'support/journal_fixtures.dart';

void main() {
  late AttendanceAuthBackend b;
  setUp(() => b = AttendanceAuthBackend());
  tearDown(() => b.close());

  test(
    'reentrant logout notification cannot let an older login run after logout',
    () async {
      await b.login();
      var armed = true;
      Future<void>? logout;
      void onStart() {
        if (!armed) return;
        armed = false;
        logout = b.repository.signOut();
      }

      b.repository.attendanceOperationChanges.addListener(onStart);
      await expectLater(
        b.repository.signIn(
          email: 'fictional@example.test',
          password: 'fictional',
        ),
        throwsA(isA<AuthFailure>()),
      );
      await logout;
      b.repository.attendanceOperationChanges.removeListener(onStart);
      expect(b.client.auth.currentSession, isNull);
    },
  );

  test('no approval notification before completed profile/role attestation; listener sees atomic state', () async {
    b.profileResponse = Completer<http.Response>();
    final approved = <bool>[];
    void listener() {
      try {
        final context = b.context();
        approved.add(context.isCurrent);
      } on AttendanceAuthFailure {
        approved.add(false);
      }
    }

    b.owner.addListener(listener);
    final login = b.login();
    await b.profileStarted.future;
    expect(approved, isNot(contains(true)));
    b.profileResponse!.complete(
      json([
        {
          'id': journalBinding().profileId,
          'company_id': journalBinding().companyId,
          'status': 'active',
          'display_name': 'Fictional employee',
          'email': 'fictional@example.test',
        },
      ]),
    );
    await login;
    expect(approved.last, true);
    expect(b.profileCalls, 1);
    b.owner.removeListener(listener);
    final count = approved.length;
    await b.controller.signOut();
    expect(approved.length, count);
  });
  for (final throughController in [true, false]) {
    test(
      'logout initiation notifies synchronously (controller=$throughController)',
      () async {
        await b.login();
        final old = b.context();
        final current = <bool>[];
        b.owner.addListener(() => current.add(old.isCurrent));
        final logout = throughController
            ? b.controller.signOut()
            : b.repository.signOut();
        expect(b.logoutCalls, 0);
        expect(b.client.auth.currentSession, isNotNull);
        expect(current, isNotEmpty);
        expect(current.every((value) => !value), true);
        expect(b.owner.outstandingAttempts, 1);
        await logout;
      },
    );
  }
  test(
    'repository-direct restore invalidates before awaiting the profile read',
    () async {
      await b.login();
      final old = b.context();
      var invalidated = false;
      b.owner.addListener(() {
        invalidated = !old.isCurrent;
      });
      final restore = b.repository.restoreSession();
      expect(invalidated, true);
      expect(old.isCurrent, false);
      await restore;
    },
  );
  for (final different in [false, true]) {
    test(
      'same-user relogin / account replacement notifies at initiation (different=$different)',
      () async {
        await b.login();
        final old = b.context();
        var notices = 0;
        b.owner.addListener(() {
          notices++;
          expect(old.isCurrent, false);
        });
        if (different) b.account = journalOtherId;
        final login = b.login();
        expect(notices, greaterThan(0));
        expect(old.isCurrent, false);
        await login;
        final fresh = b.context();
        expect(fresh.isCurrent, true);
        expect(fresh.identity.generation, isNot(old.identity.generation));
      },
    );
  }
  for (final outcome in ['authorized', 'disabled', 'revoked', 'network']) {
    test(
      '$outcome revalidation revokes old generation before its awaits',
      () async {
        await b.login();
        final old = b.context();
        final observed = <bool>[];
        b.owner.addListener(() => observed.add(old.isCurrent));
        b.disabled = outcome == 'disabled';
        b.roleRevoked = outcome == 'revoked';
        b.offlineProfile = outcome == 'network';
        final revalidation = b.controller.revalidateOnResume();
        expect(observed, isNotEmpty);
        expect(observed.every((current) => !current), true);
        await revalidation;
        expect(old.isCurrent, false);
        if (outcome == 'authorized') {
          expect(b.context().isCurrent, true);
        } else {
          expect(b.owner.issueContext, throwsA(isA<AttendanceAuthFailure>()));
        }
      },
    );
  }
  test('proven refresh preserves generation and does not notify/revalidate profiles', () async {
    await b.login();
    final old = b.context();
    var notices = 0;
    b.owner.addListener(() => notices++);
    await b.client.auth.refreshSession();
    await turn();
    expect(old.isCurrent, true);
    expect(b.owner.generation, old.identity.generation);
    expect(notices, 0);
    expect(b.profileCalls, 1);
  });
  test('tokenRefreshed for a different login notifies loss without granting cached approval', () async {
    await b.login();
    final old = b.context();
    var unavailable = false;
    b.owner.addListener(() {
      unavailable = true;
      expect(old.isCurrent, false);
      expect(b.owner.issueContext, throwsA(isA<AttendanceAuthFailure>()));
    });
    b.refreshResponse = Completer<http.Response>();
    final replacement = b.client.auth.setSession('fictional-other-login');
    await b.refreshStarted.future;
    b.refreshResponse!.complete(json(b.session(login: journalOtherId)));
    await replacement;
    await turn();
    expect(unavailable, true);
  });
  test('owner close notifies synchronously, detaches inputs, and drains submitted contexts', () async {
    await b.login();
    final context = b.context();
    var notices = 0;
    b.owner.addListener(() => notices++);
    var closed = false;
    final closing = b.owner.close().then((_) => closed = true);
    expect(context.isCurrent, false);
    expect(notices, 1);
    await turn();
    expect(closed, false);
    await b.controller.signOut();
    await b.login();
    expect(notices, 1);
    expect(b.owner.outstandingAttempts, 1);
    await context.release();
    await closing;
    expect(closed, true);
  });
  test('listener may request close reentrantly without premature shutdown completion', () async {
    await b.login();
    final context = b.context();
    Future<void>? nested;
    b.owner.addListener(() {
      nested = b.owner.close();
    });
    final closing = b.owner.close();
    expect(identical(nested, closing), true);
    var settled = false;
    closing.then((_) => settled = true);
    await turn();
    expect(settled, false);
    await context.release();
    await closing;
  });
}
