"""Rollback-only populated-baseline rehearsal on the retained LOCAL database.

Run before applying 20261025000100. No reset, committed fixtures or hosted access.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PSQL = ['docker', 'exec', '-i', 'supabase_db_chantipoint', 'psql', '-X', '-qAt',
        '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']


def execute(sql):
    result = subprocess.run(PSQL, input=sql, text=True, encoding='utf-8',
                            capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError('Local upgrade rehearsal SQL failed: ' + result.stderr)
    return result.stdout


def main():
    assert execute("select to_regclass('private.attendance_deployment') is null;").strip() == 't', \
        'Rehearsal requires the five-migration baseline; do not reset an upgraded database'
    snapshot = """select jsonb_build_array(
      (select jsonb_agg(to_jsonb(s) order by id) from public.work_sessions s),
      (select jsonb_agg(to_jsonb(e) order by id) from public.session_events e),
      (select jsonb_agg(to_jsonb(l) order by id) from public.location_observations l),
      (select jsonb_agg(to_jsonb(o) order by operation_key) from private.employee_note_operations o))"""
    setup = """
begin;
set local statement_timeout='30s';
set local lock_timeout='5s';
create extension if not exists pgtap with schema extensions;
select no_plan();
create temporary table upgrade_identity as select gen_random_uuid() a,gen_random_uuid() p,gen_random_uuid() c;
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
select a,'authenticated','authenticated','upgrade@example.test','not-a-password',statement_timestamp() from upgrade_identity;
insert into public.companies(id,name) select c,'Fictional upgrade company' from upgrade_identity;
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
select p,a,c,'Fictional upgrade employee','upgrade@example.test' from upgrade_identity;
insert into public.role_assignments(user_profile_id,company_id,role) select p,c,'employee' from upgrade_identity;
do $$ begin perform set_config('request.jwt.claim.sub',(select a::text from upgrade_identity),true); end $$;
create temporary table upgrade_receipts(label text primary key,r jsonb);
insert into upgrade_receipts values('closed_in',public.check_in('factory','Fictional workshop',null,'upgrade-closed-in'));
insert into upgrade_receipts values('closed_out',public.check_out(
  (select (r->>'session_id')::uuid from upgrade_receipts where label='closed_in'),'upgrade-closed-out',null));
insert into upgrade_receipts values('active_in',public.check_in('factory',null,null,'upgrade-active-in'));
insert into upgrade_receipts values('note',public.save_employee_note(
  (select (r->>'session_id')::uuid from upgrade_receipts where label='active_in'),
  'upgrade-note-key','replace','Fictional note',false));
select public.update_employee_note((select (r->>'session_id')::uuid from upgrade_receipts where label='active_in'),'Later fictional note');
create temporary table upgrade_function_bodies as
select oid,prosrc,proargnames,pronargdefaults from pg_proc where oid in (
 'private.submit_attendance(integer,text,uuid,text,timestamptz,text,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean,text,text)'::regprocedure,
 'private.attendance_receipt(public.work_sessions,text,text,integer)'::regprocedure,
 'private.attendance_request_hash(integer,text,uuid,uuid,uuid,text,text,timestamptz,numeric,numeric,numeric,timestamptz,text,boolean,text,text)'::regprocedure,
 'private.check_in_legacy_impl(text,text,timestamptz,text,numeric,numeric,numeric,text)'::regprocedure,
 'private.check_out_legacy_impl(uuid,text,timestamptz,numeric,numeric,numeric,text)'::regprocedure,
 'public.update_employee_note(uuid,text)'::regprocedure,
 'public.save_employee_note(uuid,text,text,text,boolean)'::regprocedure);
"""
    migration = (ROOT / 'supabase/migrations/20261025000100_attendance_activation_contract.sql').read_text(encoding='utf-8')
    checks = """
select is(private.attendance_write_contract(),1,'upgrade retains legacy gate');
select is((select count(*)::int from private.attendance_deployment),1,'upgrade creates one server identity');
select ok(not exists(select 1 from upgrade_function_bodies b left join pg_proc p on p.oid=b.oid
 where p.oid is null or p.prosrc is distinct from b.prosrc or p.proargnames is distinct from b.proargnames
 or p.pronargdefaults is distinct from b.pronargdefaults),'original bodies, hashes and note implementation signatures preserved');
select is(public.check_out((select (r->>'session_id')::uuid from upgrade_receipts where label='closed_in'),
 'upgrade-closed-out',null),(select r||'{"status":"idempotent_replay"}'::jsonb from upgrade_receipts where label='closed_out'),
 'pre-upgrade checkout replays exactly');
select is(public.check_in('factory',null,null,'upgrade-active-in'),
 (select r||'{"status":"idempotent_replay"}'::jsonb from upgrade_receipts where label='active_in'),
 'pre-upgrade active check-in replays exactly');
select is(public.save_employee_note((select (r->>'session_id')::uuid from upgrade_receipts where label='active_in'),
 'upgrade-note-key','replace','Fictional note',true),(select r from upgrade_receipts where label='note'),
 'pre-upgrade keyed note receipt replays exactly without applying old text');
select * from finish();
rollback;
"""
    output = execute(setup + '\ncreate temporary table upgrade_before as ' + snapshot + ' as value;\n' + migration +
                     '\nselect is((' + snapshot + "),(select value from upgrade_before),'all existing rows and terminal evidence unchanged');\n" + checks)
    failures = [line for line in output.splitlines() if line.startswith('not ok')]
    plans = re.findall(r'^1\.\.(\d+)$', output, re.M)
    assert not failures and plans == ['7'], 'Populated upgrade assertions failed: ' + str(failures)
    assert execute("select to_regclass('private.attendance_deployment') is null;").strip() == 't'
    print('PASS: populated baseline upgrade; 7 assertions; migration and fictional fixtures rolled back')


if __name__ == '__main__':
    main()
