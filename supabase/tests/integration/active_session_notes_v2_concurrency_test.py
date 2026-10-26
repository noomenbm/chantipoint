"""Real overlapping SQL on an explicitly named disposable LOCAL note database.

Retains fictional fixtures for inspection. Never targets the retained development
database or hosted endpoints. Output contains assertion names/counts only.
"""
import argparse
import json
import re
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--container', required=True, choices=[
        'chantipoint_notes_validation_20261025',
        'supabase_db_chantipoint_e2e_20261025'])
    parser.add_argument('--database', choices=['cp_notes_validation'], default='cp_notes_validation')
    args = parser.parse_args()
    inspected = subprocess.run(['docker', 'inspect', args.container], capture_output=True, check=True)
    info = json.loads(inspected.stdout)[0]
    assert info['Name'] == '/' + args.container
    assert not any(m.get('Name') == 'supabase_db_chantipoint' for m in info['Mounts'])
    psql = ['docker', 'exec', '-i', args.container, 'psql', '-X', '-qAt',
            '-U', 'postgres', '-d', args.database, '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose']

    def execute(sql):
        p = subprocess.run(psql, input=sql, text=True, encoding='utf-8', capture_output=True, timeout=30)
        if p.returncode:
            raise RuntimeError('Disposable SQL failed; raw values suppressed')
        return p.stdout.strip()

    assert execute("select to_regprocedure('public.save_employee_note_v2(uuid,text,text,text,boolean)') is not null;") == 't'
    execute('update private.attendance_deployment set write_contract=2;')
    epoch = execute('select deployment_epoch from private.attendance_deployment;')
    assert re.fullmatch(r'[0-9a-f-]{36}', epoch)
    company, auth, profile = (str(uuid.uuid4()) for _ in range(3))
    prefix = 'notes_v2_' + uuid.uuid4().hex
    execute(f"""begin;
insert into public.companies(id,name) values('{company}','Fictional local note concurrency');
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
 values('{auth}','authenticated','authenticated','{prefix}@example.test','not-a-password',statement_timestamp());
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
 values('{profile}','{auth}','{company}','Fictional local employee','{prefix}@example.test');
insert into public.role_assignments(user_profile_id,company_id,role) values('{profile}','{company}','employee');
commit;""")

    def authenticated(sql, name=''):
        headers = json.dumps({'x-chantipoint-attendance-epoch': epoch})
        return ("begin; set local statement_timeout='20s'; set local lock_timeout='15s'; "
                f"set local application_name='{name}'; set local role authenticated; "
                f"select set_config('request.jwt.claim.sub','{auth}',true); "
                f"select set_config('request.headers','{headers}',true); {sql}")

    def decode(code, output):
        if code:
            return {'error': True}
        lines = [s for s in output.splitlines() if s.startswith('{')]
        return json.loads(lines[-1])

    def call(sql):
        return decode(0, execute(authenticated(sql) + ' commit;'))

    def start(suffix):
        return call(f"select public.check_in_v2('{prefix}-{suffix}');")['session_id']

    def save(session, key, replay=False):
        return f"select public.save_employee_note_v2('{session}','{prefix}-{key}','replace','fictional saved',{str(replay).lower()});"

    def close(session, key, action='preserve'):
        text = "'fictional final'" if action == 'replace' else 'null'
        return f"select public.check_out_v2('{session}','{prefix}-{key}',p_note_action=>'{action}',p_employee_note=>{text});"

    def overlap(first_sql, second_sql, privileged_second=False):
        first = subprocess.Popen(psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, encoding='utf-8')
        second = None
        ready = False
        first_lines = []
        try:
            first.stdin.write(authenticated(first_sql) + " select 'NOTE_READY';\n")
            first.stdin.flush()
            for line in first.stdout:
                first_lines.append(line)
                if line.strip() == 'NOTE_READY':
                    ready = True
                    break
            assert ready, 'First local transaction did not become ready'
            name = prefix + '_waiting'
            second = subprocess.Popen(psql, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, encoding='utf-8')
            body = (f"begin; set local application_name='{name}'; set local statement_timeout='20s'; {second_sql}"
                    if privileged_second else authenticated(second_sql, name))
            second.stdin.write(body + ' commit;\n')
            second.stdin.close()
            second.stdin = None
            deadline = time.monotonic() + 8
            waiting = False
            while time.monotonic() < deadline:
                waiting = execute(f"select count(*) from pg_stat_activity where application_name='{name}' and wait_event_type='Lock';") == '1'
                if waiting:
                    break
                time.sleep(0.1)
            assert waiting, 'Second transaction must demonstrably wait on a lock'
        finally:
            if first.poll() is None:
                first.stdin.write(('commit;' if ready else 'rollback;') + '\n\\q\n')
                first.stdin.close()
                first.stdin = None
            tail, _ = first.communicate(timeout=25)
        assert second is not None
        output, _ = second.communicate(timeout=25)
        return decode(first.returncode, ''.join(first_lines) + tail), decode(second.returncode, output)

    passed = 0
    for action in ['preserve', 'replace', 'clear']:
        session = start('save-before-' + action)
        note, checkout = overlap(save(session, 'save-' + action), close(session, 'close-' + action, action))
        assert note['outcome'] == 'applied' and checkout['status'] == 'closed'
        expected = {'preserve': 'fictional saved', 'replace': 'fictional final', 'clear': '<null>'}[action]
        assert execute(f"select coalesce(employee_note,'<null>') from public.work_sessions where id='{session}';") == expected
        passed += 1
    session = start('checkout-first')
    checkout, note = overlap(close(session, 'close-first'), save(session, 'save-after-close'))
    assert checkout['status'] == 'closed' and note['reason'] == 'session_closed'
    passed += 1
    session = start('replay-first')
    fence, original = overlap(save(session, 'fence', True), save(session, 'fence'))
    assert fence == original and fence['reason'] == 'replay_fenced'
    assert execute(f"select employee_note is null from public.work_sessions where id='{session}';") == 't'
    passed += 1
    original, replay = overlap(save(session, 'original-first'), save(session, 'original-first', True))
    assert original == replay and original['outcome'] == 'applied'
    passed += 1
    original, changed = overlap(save(session, 'conflict'), save(session, 'conflict').replace('fictional saved','different'))
    assert original['outcome'] == 'applied' and changed.get('error') is True
    passed += 1
    original, rotation = overlap(save(session, 'epoch-locked'),
        "update private.attendance_deployment set deployment_epoch=gen_random_uuid(); select '{}'::jsonb;", True)
    assert original['outcome'] == 'applied' and rotation == {}
    p = subprocess.run(psql, input=authenticated(save(session, 'stale-epoch')) + ' commit;',
                       text=True, encoding='utf-8', capture_output=True, timeout=30)
    assert p.returncode != 0 and 'attendance_epoch_mismatch' in p.stderr
    passed += 1
    print(json.dumps({'suite': 'v2 note real SQL concurrency', 'passed': passed,
                      'overlap_lock_waits_proved': passed, 'fixtures_retained': True}))


if __name__ == '__main__':
    main()
