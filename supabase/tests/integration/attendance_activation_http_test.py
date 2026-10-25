"""Actual LOCAL PostgREST/JWT test, never a hosted or original-write smoke.

Uses the retained database and cached image only. A uniquely owned fictional
employee fixture is committed for cross-connection HTTP visibility, then removed
with identity-checked cleanup. No attendance/note mutation is submitted. Tokens,
response bodies and row contents are never printed or saved. The disposable
service shares only the DB network namespace, using its existing loopback trust
policy and existing curl client. No database password or auth configuration is
read/changed. Neither the HTTP socket nor a full Supabase stack is published.
"""
import base64
import ctypes
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import re
import subprocess
import time
from urllib.parse import urlencode
import uuid

ROOT = Path(__file__).resolve().parents[3]
DATABASE = 'supabase_db_chantipoint'
IMAGE = 'public.ecr.aws/supabase/postgrest:v16.4'
PSQL = ['docker', 'exec', '-i', DATABASE, 'psql', '-X', '-qAt', '-h', '127.0.0.1',
        '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
EVIDENCE = ['public.work_sessions', 'public.session_events',
            'public.location_observations', 'private.employee_note_operations']
COUNTS = ['auth.users', 'public.companies', 'public.user_profiles',
          'public.role_assignments', 'public.admin_audit_events', *EVIDENCE]


def command(args, *, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                            text=True, encoding='utf-8', timeout=40)
    if result.returncode:
        raise RuntimeError('Local tool failed; private diagnostic details suppressed')
    return result.stdout.strip()


def sql(text):
    result = subprocess.run(PSQL, input=text, capture_output=True, text=True,
                            encoding='utf-8', timeout=30)
    if result.returncode:
        raise RuntimeError('Local SQL failed; private diagnostic details suppressed')
    return result.stdout.strip()


def resource_guard(minimum_ram_mib=256):
    if os.name != 'nt':
        raise RuntimeError('This retained-resource harness targets the reviewed Windows setup')
    free = ctypes.c_ulonglong()
    assert ctypes.windll.kernel32.GetDiskFreeSpaceExW('C:\\', ctypes.byref(free), None, None)
    if free.value < 3 * 1024**3:
        raise RuntimeError('C: 3 GiB stop rule reached')
    class Memory(ctypes.Structure):
        _fields_ = [('length', ctypes.c_ulong), ('load', ctypes.c_ulong),
                    *[(name, ctypes.c_ulonglong) for name in
                      ('total', 'available', 'page_total', 'page_available',
                       'virtual_total', 'virtual_available', 'extended')]]
    memory = Memory()
    memory.length = ctypes.sizeof(memory)
    assert ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory))
    if memory.available < minimum_ram_mib * 1024**2:
        raise RuntimeError('Available RAM below local HTTP harness guard')


def snapshot():
    expressions = [f"(select jsonb_build_array(count(*),encode(sha256(convert_to("
                   f"coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]'::jsonb)::text,"
                   f"'UTF8')),'hex')) from {table} t)" for table in EVIDENCE]
    expressions += [f'(select to_jsonb(count(*)) from {table})' for table in COUNTS]
    expressions += ['(select to_jsonb(d) from private.attendance_deployment d)']
    return sql('begin read only; set local statement_timeout=\'10s\'; select jsonb_build_array('
               + ','.join(expressions) + '); rollback;')


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError('Duplicate HTTP JSON field')
        result[key] = value
    return result


def main():
    resource_guard(512)
    assert command(['docker', 'inspect', DATABASE, '--format', '{{.State.Running}}']) == 'true'
    command(['docker', 'image', 'inspect', IMAGE, '--format', '{{.Id}}'])  # Never pull.
    command(['docker', 'exec', DATABASE, 'curl', '--version'])  # Already installed.
    state = json.loads(sql('begin read only; select to_jsonb(d) from private.attendance_deployment d; rollback;'))
    assert state['write_contract'] == 1 and state['singleton'] is True
    original = snapshot()
    auth_id, profile_id, company_id, role_id, session_id = [str(uuid.uuid4()) for _ in range(5)]
    fixture_email = 'local.http.' + uuid.uuid4().hex + '@example.test'
    name = 'chantipoint_activation_http_' + uuid.uuid4().hex[:12]
    created = False
    container = False
    assertions = 0

    def check(condition, label):
        nonlocal assertions
        if not condition:
            raise AssertionError(label)
        assertions += 1

    def evidence():
        return sql('begin read only; select jsonb_build_array(' + ','.join(
            f"(select jsonb_build_array(count(*),encode(sha256(convert_to(coalesce(jsonb_agg(to_jsonb(t) "
            f"order by to_jsonb(t)::text),'[]'::jsonb)::text,'UTF8')),'hex')) from {table} t)"
            for table in EVIDENCE) + '); rollback;')

    try:
        sql(f"""begin; set local statement_timeout='10s';
        insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
          values('{auth_id}','authenticated','authenticated','{fixture_email}','not-a-password',statement_timestamp());
        insert into public.companies(id,name) values('{company_id}','Fictional local HTTP company');
        insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
          values('{profile_id}','{auth_id}','{company_id}','Fictional local HTTP employee','{fixture_email}');
        insert into public.role_assignments(id,user_profile_id,company_id,role)
          values('{role_id}','{profile_id}','{company_id}','employee'); commit;""")
        created = True
        before_http = evidence()
        # The existing retained DB accepts its authenticator on loopback. Bridge
        # connections require a password not supplied by this minimal DB setup.
        # Share the network namespace and bind HTTP to loopback only; do not
        # weaken HBA/password rules or expose a new host port to work around it.
        secret = secrets.token_urlsafe(48)
        env = dict(os.environ)
        env.update({
            'PGRST_DB_URI': 'postgres://authenticator@127.0.0.1:5432/postgres',
            'PGRST_JWT_SECRET': secret,
        })
        args = ['docker', 'run', '-d', '--pull=never', '--name', name,
                '--network', 'container:' + DATABASE, '--memory=96m', '--memory-swap=96m',
                '--cpus=0.5', '--pids-limit=64', '--read-only', '--tmpfs', '/tmp:size=8m',
                '--log-driver=none', '-e', 'PGRST_SERVER_HOST=127.0.0.1', '-e', 'PGRST_SERVER_PORT=3000',
                '-e', 'PGRST_DB_URI', '-e', 'PGRST_JWT_SECRET', '-e', 'PGRST_DB_SCHEMAS=public',
                '-e', 'PGRST_DB_ANON_ROLE=anon', '-e', 'PGRST_DB_POOL=1',
                '-e', 'PGRST_DB_EXTRA_SEARCH_PATH=extensions', '-e', 'GHCRTS=-N1', IMAGE]
        # Mark ownership before create: even a client-side Docker timeout after
        # successful creation must still attempt cleanup of this unique name.
        container = True
        command(args, env=env)
        endpoint = 'http://127.0.0.1:3000'
        encode = lambda value: base64.urlsafe_b64encode(value).decode().rstrip('=')
        signing = encode(b'{"alg":"HS256","typ":"JWT"}') + '.' + encode(json.dumps({
            'role': 'authenticated', 'sub': auth_id, 'aud': 'authenticated',
            'exp': int(time.time()) + 300,
        }, separators=(',', ':')).encode())
        token = signing + '.' + encode(hmac.new(secret.encode(), signing.encode(), hashlib.sha256).digest())
        def request(path, body=None, epoch=None, authenticated=True):
            resource_guard()
            headers = {'Accept': 'application/json'}
            if authenticated:
                headers['Authorization'] = 'Bearer ' + token
            if epoch is not None:
                headers['x-chantipoint-attendance-epoch'] = epoch
            if body is not None:
                # These are the ONLY RPC POSTs this harness can issue.
                assert path in ('/rpc/check_in_v2', '/rpc/check_out_v2')
                assert body['p_replay_only'] is True
                headers['Content-Type'] = 'application/json'
            config = ['url = ' + json.dumps(endpoint + path), 'noproxy = "*"',
                      'silent', 'show-error', 'max-time = 10', 'max-filesize = 16384',
                      'write-out = "\\n%{http_code}"']
            config += ['header = ' + json.dumps(key + ': ' + value) for key, value in headers.items()]
            if body is not None:
                config += ['data = ' + json.dumps(json.dumps(body))]
            # No secrets in process arguments, Docker logs or files. curl speaks
            # actual HTTP to the isolated PostgREST listener, without redirects,
            # proxying or implicit retries; tokens travel through stdin only.
            result = subprocess.run(['docker', 'exec', '-i', DATABASE, 'curl', '--config', '-'],
                                    input=('\n'.join(config) + '\n').encode('utf-8'),
                                    capture_output=True, timeout=15)
            if result.returncode:
                if result.returncode == 7:
                    raise ConnectionError('Local listener not ready')
                raise RuntimeError('Local HTTP client failed with safe exit code ' + str(result.returncode))
            raw, status = result.stdout.decode('utf-8').rsplit('\n', 1)
            if len(raw.encode('utf-8')) > 16 * 1024:
                raise RuntimeError('Local HTTP response exceeded bound')
            return int(status), json.loads(raw, object_pairs_hook=strict_object)

        deadline = time.monotonic() + 30
        last_status, last_code = None, None
        while True:
            try:
                status, capability = request('/rpc/attendance_capability')
                if status == 200:
                    break
                last_status = status
                code = capability.get('code') if isinstance(capability, dict) else None
                last_code = code if isinstance(code, str) and re.fullmatch(r'[A-Z0-9]{5,12}', code) else None
            except ConnectionError:
                pass
            if time.monotonic() >= deadline:
                runtime = json.loads(command(['docker', 'inspect', name, '--format', '{{json .State}}']))
                raise RuntimeError('Local PostgREST readiness failed: HTTP=' + str(last_status)
                                   + ', code=' + str(last_code) + ', running=' + str(runtime['Running'])
                                   + ', exit=' + str(runtime['ExitCode']) + ', OOM=' + str(runtime['OOMKilled']))
            time.sleep(0.3)
        check(type(capability.get('capability_version')) is int
              and type(capability.get('write_contract')) is int
              and capability == {'capability_version': 1, 'deployment_epoch': state['deployment_epoch'],
                             'write_contract': 1, 'v2_available': False}, 'Exact authenticated gate-1 capability')
        status, denied = request('/rpc/attendance_capability', authenticated=False)
        check(status == 401 and denied.get('code') == '42501', 'Anonymous capability denied')
        for operation in ('check_in_v2', 'check_out_v2'):
            body = {'p_idempotency_key': 'local-http-replay-' + uuid.uuid4().hex, 'p_replay_only': True}
            if operation == 'check_out_v2':
                body['p_work_session_id'] = session_id
            status, result = request('/rpc/' + operation, body, state['deployment_epoch'])
            check(status == 200 and type(result.get('contract_version')) is int
                  and result == {'contract_version': 2, 'status': 'not_found'},
                  operation + ' matching epoch exact replay-only miss')
            status, result = request('/rpc/' + operation, body, str(uuid.uuid4()))
            check(status == 400 and result.get('code') == 'P0001'
                  and result.get('message') == 'attendance_epoch_mismatch', operation + ' mismatching header rejected')
            status, result = request('/rpc/' + operation, body)
            check(status == 400 and result.get('code') == 'P0001'
                  and result.get('message') == 'attendance_epoch_required', operation + ' missing header rejected')
            check(evidence() == before_http, operation + ' changed no attendance/note/evidence rows')
        selection = 'id,auth_user_id,company_id,status,employee_role:role_assignments!role_assignments_profile_company_fk(role,status),sessions:work_sessions!work_sessions_employee_company_fk(id,started_at,ended_at)'
        status, rows = request('/user_profiles?' + urlencode({
            'select': selection, 'id': 'eq.' + profile_id, 'company_id': 'eq.' + company_id,
            'auth_user_id': 'eq.' + auth_id, 'status': 'eq.active',
            'employee_role.role': 'eq.employee', 'employee_role.status': 'eq.active',
            'employee_role.limit': '2', 'sessions.employee_profile_id': 'eq.' + profile_id,
            'sessions.company_id': 'eq.' + company_id, 'sessions.limit': '21', 'limit': '2',
        }))
        check(status == 200 and len(rows) == 1 and rows[0]['id'] == profile_id
              and rows[0]['company_id'] == company_id and rows[0]['auth_user_id'] == auth_id
              and rows[0]['employee_role'] == [{'role': 'employee', 'status': 'active'}]
              and rows[0]['sessions'] == [], 'Actual empty owner-scoped History relationships')
        check(evidence() == before_http, 'All HTTP checks leave attendance/note/evidence unchanged')
        print('PASS: actual cached PostgREST v16.4 HTTP/JWT; capability GET, anonymous denial,', flush=True)
        print('both replay-only RPCs with matching/mismatching/missing epoch headers; empty owner-scoped embedding', flush=True)
    finally:
        if container:
            # Only the uniquely owned disposable test service. Never remove DB.
            subprocess.run(['docker', 'stop', '--time', '10', name], capture_output=True, timeout=25)
            result = subprocess.run(['docker', 'rm', name], capture_output=True, timeout=20)
            if result.returncode and command(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$']):
                raise RuntimeError('Disposable local HTTP container cleanup failed')
        if created:
            # Refuse deletion if unexpected attendance/note work exists. Never
            # cascade away evidence merely to make cleanup pass.
            count = sql(f"select (select count(*) from public.work_sessions where employee_profile_id='{profile_id}')"
                        f"+(select count(*) from private.employee_note_operations where employee_profile_id='{profile_id}');")
            if count != '0':
                raise RuntimeError('Unexpected local evidence retained; fictional fixture cleanup blocked')
            sql(f"""begin; set local statement_timeout='10s';
            delete from public.role_assignments where id='{role_id}' and user_profile_id='{profile_id}' and company_id='{company_id}';
            delete from public.user_profiles where id='{profile_id}' and auth_user_id='{auth_id}' and company_id='{company_id}' and email='{fixture_email}';
            delete from public.companies where id='{company_id}' and name='Fictional local HTTP company';
            delete from auth.users where id='{auth_id}' and email='{fixture_email}'; commit;""")
        check(snapshot() == original, 'Original local data counts, evidence digests and deployment state restored')
    print(f'PASS: {assertions} HTTP/state assertions; fictional identity removed; disposable service removed; gate/epoch retained')


if __name__ == '__main__':
    main()
