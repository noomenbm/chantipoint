"""Local-only strict inspection regression tests. No hosted connections.

Expected function metadata comes from the six committed migration sources, not
from observed database bodies. Database drift probes are rollback-only.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
INSPECTION = ROOT / 'supabase/inspection/attendance_activation_deployment_check.sql'
VERSIONS = ['20261013000100', '20261016000100', '20261017000100',
            '20261017000200', '20261021000100', '20261025000100']
PSQL = ['docker', 'exec', '-i', 'supabase_db_chantipoint', 'psql', '-X', '-qAt',
        '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']


def source_functions():
    """Narrow reader for these reviewed SQL files; not a general SQL parser."""
    latest, by_version = {}, {}
    pattern = re.compile(r'create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*'
                         r'\((.*?)\)\s*returns\s+(.*?)\bas\s+\$\$(.*?)\$\$\s*;', re.I | re.S)
    for version in VERSIONS:
        files = list((ROOT / 'supabase/migrations').glob(version + '_*.sql'))
        assert len(files) == 1
        definitions = {}
        for match in pattern.finditer(files[0].read_text(encoding='utf-8')):
            name, arguments, header, body = match.groups()
            args = re.sub(r'--[^\n]*', '', arguments).strip()
            parts = [a.strip() for a in args.split(',')] if args else []
            names, types, defaults = [], [], []
            for part in parts:
                declared = re.split(r'\s+default\s+', part, flags=re.I)
                arg_name, arg_type = declared[0].split()
                names.append(arg_name)
                types.append(arg_type)
                if len(declared) == 2:
                    value = declared[1].strip()
                    display_type = {'timestamptz': 'timestamp with time zone'}.get(arg_type, arg_type)
                    if value.lower() == 'null':
                        value = 'NULL::' + display_type
                    elif value.startswith("'"):
                        value += '::' + display_type
                    defaults.append(value)
            language = re.search(r'\blanguage\s+(\w+)', header, re.I).group(1).lower()
            result = re.split(r'\blanguage\b', header, flags=re.I)[0].strip()
            config = ['search_path=""']
            assert re.search(r"set\s+search_path\s*=\s*''", header, re.I)
            if re.search(r"set\s+timezone\s*=\s*'UTC'", header, re.I):
                config.append('TimeZone=UTC')
            record = {
                'signature': name + '(' + ','.join(types) + ')',
                'body_sha256': hashlib.sha256(body.encode('utf-8')).hexdigest(),
                'argument_names': names,
                'defaults': ', '.join(defaults),
                'result_type': result,
                'definer': bool(re.search(r'\bsecurity\s+definer\b', header, re.I)),
                'language': language,
                'volatility': 'i' if re.search(r'\bimmutable\b', header, re.I) else
                              's' if re.search(r'\bstable\b', header, re.I) else 'v',
                'config': config,
            }
            definitions[name] = record
            latest[name] = record
        by_version[version] = definitions
    relocated = {
        'private.check_in_legacy_impl': ('20261013000100', 'public.check_in'),
        'private.check_out_legacy_impl': ('20261013000100', 'public.check_out'),
        'private.update_employee_note_legacy_impl': ('20261017000200', 'public.update_employee_note'),
        'private.save_employee_note_legacy_impl': ('20261021000100', 'public.save_employee_note'),
    }
    for target, (version, original) in relocated.items():
        record = dict(by_version[version][original])
        record['signature'] = target + record['signature'][record['signature'].index('('):]
        latest[target] = record
    readable_helpers = {'private.current_profile_id', 'private.current_company_id',
                        'private.current_user_has_role', 'private.current_user_is_company_admin',
                        'private.current_user_can_read_own_attendance'}
    for name, record in latest.items():
        record['client_execute'] = name.startswith('public.') or name in readable_helpers
    return sorted(latest.values(), key=lambda value: value['signature'])


def execute(sql):
    result = subprocess.run(PSQL, input=sql, text=True, encoding='utf-8',
                            capture_output=True, timeout=40)
    if result.returncode:
        # SQL diagnostics only from local synthetic/catalog tests, no raw rows.
        codes = re.findall(r'ERROR:\s+([^\n]*)', result.stderr)
        raise AssertionError('Local inspection SQL failed: ' + '; '.join(codes))
    return result.stdout.strip()


def inspection_rows(text, prefix='begin read only;'):
    assert text.startswith('--')
    # The SELECT remains the exact deployed inspection; replace ONLY its outer
    # transaction delimiters for rollback-only drift probes in this local test.
    assert text.count('begin read only;') == 1 and text.rstrip().endswith('rollback;')
    sql = text.replace('begin read only;', prefix, 1)
    result = execute(sql)
    rows = [line.rsplit('|', 1) for line in result.splitlines() if '|' in line]
    assert rows and len({name for name, _ in rows}) == len(rows)
    return dict(rows)


def main():
    text = INSPECTION.read_text(encoding='utf-8')
    manifest = json.loads(re.search(r'jsonb_to_recordset\(\$functions\$(.*?)\$functions\$::jsonb\)',
                                    text, re.S).group(1))
    assert manifest == source_functions(), 'Inspection function expectations drifted from migration sources'
    baseline = inspection_rows(text)
    assert all(value == 't' for value in baseline.values()), \
        'Baseline failures: ' + ', '.join(name for name, value in baseline.items() if value != 't')
    print(f'PASS: source-derived metadata and {len(baseline)} strict read-only local postchecks', flush=True)
    probes = [
        ('gate', 'update private.attendance_deployment set write_contract=2;', 'gate 1 and exactly one canonical server epoch'),
        ('missing deployment', 'delete from private.attendance_deployment;', 'gate 1 and exactly one canonical server epoch'),
        ('extra migration', "insert into supabase_migrations.schema_migrations(version) values('20990101000000');", 'exact six-migration history'),
        ('capability body', "create or replace function public.attendance_capability() returns jsonb language plpgsql stable security definer set search_path='' as $$ begin return '{}'::jsonb; end $$;", 'function: public.attendance_capability()'),
        ('RPC grant', 'grant execute on function public.check_out(uuid,text,timestamptz,numeric,numeric,numeric,text) to anon;', 'function: public.check_out(uuid,text,timestamptz,numeric,numeric,numeric,text)'),
        ('RPC grant option', 'grant execute on function public.check_out(uuid,text,timestamptz,numeric,numeric,numeric,text) to authenticated with grant option;', 'function: public.check_out(uuid,text,timestamptz,numeric,numeric,numeric,text)'),
        ('RPC overload', "create function public.check_out(uuid,text) returns jsonb language sql as $$select '{}'::jsonb$$;", 'no unexpected contract overloads'),
        ('private table grant', 'grant select on private.attendance_deployment to authenticated;', 'private tables protected'),
        ('RLS disabled', 'alter table public.work_sessions disable row level security;', 'application tables RLS and read-only API grants'),
        ('RLS widened', 'create policy unsafe_test on public.work_sessions for select to authenticated using(true);', 'exact owner-scoped RLS policies'),
        ('RLS renamed', 'alter policy work_sessions_select_self_or_company_admin on public.work_sessions rename to unexpected_policy;', 'exact owner-scoped RLS policies'),
        ('History FK removed', 'alter table public.work_sessions drop constraint work_sessions_employee_company_fk;', 'History composite relationships'),
        ('deployment fence removed', 'drop trigger attendance_deployment_change_lock on private.attendance_deployment;', 'deployment statement fence trigger'),
    ]
    for label, mutation, failed_name in probes:
        rows = inspection_rows(text, 'begin; ' + mutation)
        assert rows.get(failed_name) == 'f', label + ' did not fail closed'
    final = inspection_rows(text)
    assert final == baseline, 'Rollback probes did not restore baseline'
    print(f'PASS: {len(probes)} rollback-only drift probes rejected; final baseline unchanged')


if __name__ == '__main__':
    main()
