"""Settled note RPCs on the retained LOCAL DB; stdlib, fictional fixtures only.

Invoked by m2_3b_2b_notes_concurrency_test.py --settled. Never changes the gate.
Uses the currently enabled legacy checkout for committed overlapping closure;
existing rollback-only pgTAP also covers v2 final-note behavior.
"""
import json
import subprocess
import time
import uuid

import m2_3b_2a_concurrency_test as db


def main():
    counts = db.COUNTS.replace('));', '),(select count(*) from private.employee_note_operations));')
    before = db.execute(counts)
    gate_query = "select pg_get_functiondef('private.attendance_write_contract()'::regprocedure);"
    gate = db.execute(gate_query)
    db.check(db.execute('select private.attendance_write_contract();') == '1', 'legacy gate required')
    db.check(db.execute("select count(*) from supabase_migrations.schema_migrations where version='20261021000100';") == '1',
             'settled migration must be recorded locally')
    company, auth, profile = (str(uuid.uuid4()) for _ in range(3))
    for table, key in [('public.companies', company), ('auth.users', auth), ('public.user_profiles', profile)]:
        db.check(db.execute(f"select count(*) from {table} where id='{key}';") == '0', 'fixture ID must be new')
    prefix = 'cp_settled_' + uuid.uuid4().hex

    def authenticated(sql, name=''):
        return ("begin; set local statement_timeout='15s'; set local lock_timeout='10s'; "
                f"set local application_name='{name}'; set local role authenticated; "
                f"select set_config('request.jwt.claim.sub','{auth}',true); {sql}")

    def decode(code, output, error):
        if code:
            # Return only SQLSTATE; never surface raw backend messages/values.
            return {'error': next((s for s in ['23505', '42501', 'P0001'] if s + ':' in error), 'other')}
        return json.loads(next(line for line in output.splitlines() if line.startswith('{')))

    def accepted(sql):
        return decode(0, db.execute(authenticated(sql) + ' commit;'), '')

    def start(suffix):
        return accepted(f"select public.check_in('factory',null,null,'{prefix}-{suffix}');")['session_id']

    def save(session, key, text, replay=False):
        # All arguments are generated UUIDs or fixed fictional test literals.
        return (f"select public.save_employee_note('{session}','{key}','replace','{text}',"
                + ('true' if replay else 'false') + ');')

    def close(session, key):
        return f"select public.check_out('{session}','{key}');"

    def current(session):
        return db.execute(f"select coalesce(employee_note,'<null>') from public.work_sessions where id='{session}';")

    def overlap(first_sql, second_sql, *, commit_first=True):
        """Prove the second request is blocked on a lock BEFORE ending the first."""
        first = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, encoding='utf-8')
        second = None
        ready = False
        output = []
        try:
            first.stdin.write(authenticated(first_sql) + " select 'SETTLED_READY';\n")
            first.stdin.flush()
            for line in first.stdout:
                output.append(line)
                if line.strip() == 'SETTLED_READY':
                    ready = True
                    break
            if not ready:
                raise RuntimeError('first fictional transaction failed')
            name = prefix + '_waiting'
            second = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, encoding='utf-8')
            second.stdin.write(authenticated(second_sql, name) + ' commit;')
            second.stdin.close()
            second.stdin = None
            deadline = time.monotonic() + 8
            waiting = '0'
            while time.monotonic() < deadline:
                waiting = db.execute("select count(*) from pg_stat_activity "
                                     f"where application_name='{name}' and wait_event_type='Lock';")
                if waiting == '1':
                    break
                time.sleep(0.1)
            db.check(waiting == '1', 'second RPC must demonstrably overlap and wait')
        finally:
            if first.poll() is None:
                first.stdin.write(('commit;' if ready and commit_first else 'rollback;') + '\n\\q\n')
                first.stdin.close()
                first.stdin = None
            tail, error = first.communicate(timeout=20)
            if second:
                second_output, second_error = second.communicate(timeout=25)
        return (decode(first.returncode, ''.join(output) + tail, error),
                decode(second.returncode, second_output, second_error))

    attempted = False
    try:
        attempted = True
        db.execute(f"""begin;
insert into public.companies(id,name) values('{company}','Fictional settled concurrency');
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
values('{auth}','authenticated','authenticated','settled.{auth}@example.test','not-a-password',statement_timestamp());
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
values('{profile}','{auth}','{company}','Fictional settled employee','settled.{auth}@example.test');
insert into public.role_assignments(user_profile_id,company_id,role) values('{profile}','{company}','employee');
commit;""")

        session = start('original-first')
        command = save(session, 'settled-original-first', 'First applied value')
        original, replay = overlap(command, save(session, 'settled-original-first', 'First applied value', True))
        db.check(original.get('outcome') == 'applied' and replay == original, 'original commits, replay recovers exact lost receipt')
        db.check(current(session) == 'First applied value', 'one note mutation accepted')
        accepted(f"select public.update_employee_note('{session}','Newer value');")
        db.check(accepted(command) == original and current(session) == 'Newer value', 'duplicate cannot reapply historical note')
        accepted(close(session, 'settled-close-original'))
        print('PASS: original first, replay waits; lost result recovered without reapplying', flush=True)

        session = start('replay-first')
        command = save(session, 'settled-replay-first', 'Must never apply')
        fence, original = overlap(save(session, 'settled-replay-first', 'Must never apply', True), command)
        db.check(fence.get('outcome') == 'not_applied' and fence.get('reason') == 'replay_fenced', 'replay installs terminal fence')
        db.check(original == fence and accepted(command) == fence, 'waiting and later originals both observe fence')
        db.check(current(session) == '<null>', 'fenced original never mutates note')
        accepted(close(session, 'settled-close-fenced'))
        print('PASS: replay first fences waiting and later originals', flush=True)

        session = start('conflict')
        first, conflict = overlap(save(session, 'settled-conflicting-key', 'Accepted'),
                                  save(session, 'settled-conflicting-key', 'Changed', True))
        db.check(first.get('outcome') == 'applied' and conflict.get('error') == '23505', 'changed replay payload conflicts after waiting')
        db.check(current(session) == 'Accepted', 'conflict cannot mutate')
        accepted(close(session, 'settled-close-conflict'))
        print('PASS: competing changed payload cannot collide with accepted operation', flush=True)

        session = start('save-close')
        saved, closed = overlap(save(session, 'settled-save-before-close', 'Before checkout'),
                                close(session, 'settled-close-after-save'))
        db.check(saved.get('outcome') == 'applied' and closed.get('status') == 'closed', 'save then checkout both commit')
        db.check(current(session) == 'Before checkout', 'preserve checkout sees serialized save')
        db.check(accepted(save(session, 'settled-save-before-close', 'Before checkout', True)) == saved, 'lost save response recovered after checkout')
        db.check(accepted(close(session, 'settled-close-after-save')).get('status') == 'idempotent_replay', 'lost checkout response uses unchanged attendance replay')
        print('PASS: note first, checkout waits and preserves; both lost responses replay', flush=True)

        session = start('close-save')
        closed, rejected = overlap(close(session, 'settled-close-before-save'),
                                   save(session, 'settled-save-after-close', 'Too late'))
        db.check(closed.get('status') == 'closed' and rejected.get('outcome') == 'not_applied'
                 and rejected.get('reason') == 'session_closed', 'waiting original cannot edit closed session')
        db.check(current(session) == '<null>', 'closed session remains untouched')
        db.check(accepted(save(session, 'settled-save-after-close', 'Too late', True)) == rejected, 'closed rejection has terminal replay')
        print('PASS: checkout first, waiting save terminally prevented', flush=True)

        session = start('original-rollback')
        _, replay = overlap(save(session, 'settled-original-rollback', 'Rolled back'),
                            save(session, 'settled-original-rollback', 'Rolled back', True), commit_first=False)
        db.check(replay.get('reason') == 'replay_fenced' and current(session) == '<null>', 'rolled-back original leaves no applied evidence')
        db.check(accepted(save(session, 'settled-original-rollback', 'Rolled back')) == replay, 'replay fences after original rollback')
        accepted(close(session, 'settled-close-rollback-original'))
        print('PASS: original rollback releases waiting replay to fence', flush=True)

        session = start('replay-rollback')
        _, original = overlap(save(session, 'settled-replay-rollback', 'Actually committed', True),
                              save(session, 'settled-replay-rollback', 'Actually committed'), commit_first=False)
        db.check(original.get('outcome') == 'applied' and current(session) == 'Actually committed', 'rolled-back fence never falsely prevents original')
        db.check(accepted(save(session, 'settled-replay-rollback', 'Actually committed', True)) == original, 'committed original now replays')
        accepted(close(session, 'settled-close-rollback-replay'))
        print('PASS: replay rollback allows waiting original to apply', flush=True)

        db.check(db.execute(f"select count(*) from private.employee_note_operations where employee_profile_id='{profile}';") == '7', 'exactly seven terminal operations, no duplicate receipts')
        db.check(db.execute(f"select count(*) from public.session_events where company_id='{company}';") == '14', 'only seven arrivals/closures, no note events')
        db.check(db.execute(f"select factory_latitude is null and factory_longitude is null and factory_radius_meters is null from public.companies where id='{company}';") == 't', 'no real or fictional factory coordinates needed')
    finally:
        if attempted:
            db.execute(f"""begin; set local lock_timeout='10s';
delete from private.employee_note_operations where employee_profile_id='{profile}' and company_id='{company}' and auth_user_id='{auth}';
delete from public.location_observations where employee_profile_id='{profile}' and company_id='{company}';
delete from public.session_events where employee_profile_id='{profile}' and company_id='{company}';
delete from public.work_sessions where employee_profile_id='{profile}' and company_id='{company}';
delete from public.role_assignments where user_profile_id='{profile}' and company_id='{company}';
delete from public.user_profiles where id='{profile}' and auth_user_id='{auth}' and company_id='{company}';
delete from public.companies where id='{company}';
delete from auth.users where id='{auth}';
commit;""")
        db.check(db.execute(counts) == before, 'all nine before/after table counts restored')
        db.check(db.execute(gate_query) == gate, 'gate definition never changed')
    print(f'PASS: 7 real overlapping scenarios; {db.assertions} assertions; own fixtures removed; gate unchanged')


if __name__ == '__main__':
    main()
