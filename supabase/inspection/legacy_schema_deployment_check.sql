-- Metadata/aggregate post-deployment check for the LEGACY-MODE schema stage.
-- First verify the linked project is chantipoint-dev. All rows must pass.
-- No gate/attendance/note RPC is invoked. Never use this as v2 cutover approval.
-- Body SHA-256 values are from the ordered committed migrations (UTF-8, LF).
begin read only;
set local statement_timeout = '10s';
with expected_functions(signature, body_sha256, client_execute) as (values
  ('private.check_in_legacy_impl(text,text,timestamptz,text,numeric,numeric,numeric,text)', '6b6b0431be8e30a6d3906be56425727a6ded80b1083eb1a6f04d8982fc4a0009', false),
  ('private.check_out_legacy_impl(uuid,text,timestamptz,numeric,numeric,numeric,text)', 'f030c1045c37eef9835ae5ceaf6083077692bf02e42861fa9160cd4703483bf9', false),
  ('public.check_in(text,text,timestamptz,text,numeric,numeric,numeric,text)', '7a36d6c8c18f2fa507b1e3fdc157c67857211403ab51aa4743ea2235eefb5493', true),
  ('public.check_out(uuid,text,timestamptz,numeric,numeric,numeric,text)', '1ebaf276aefa1400550c3d20d698610007fc02435fa89baf600c9f632c249b41', true),
  ('private.attendance_write_contract()', '52ff794204567c254cd78373d6d88230beb60f2a4de43b0740d97953eaa4bab2', false),
  ('public.check_in_v2(text,timestamptz,text,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean)', 'abd6e84a94c273699eeddddde13f41ac6758d5a98dcd3a25def0ebead2f2d2bf', true),
  ('public.check_out_v2(uuid,text,timestamptz,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean,text,text)', 'e97a5f3510d2661d3e07544071fecf608e3e7298e88da6623af909649cba9f39', true),
  ('private.submit_attendance(integer,text,uuid,text,timestamptz,text,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean,text,text)', '0069caa62c5e5cf8825b13cc6522286786af7bcdc6d861fbee1e1fa426a04cb5', false),
  ('public.update_employee_note(uuid,text)', 'c6b60b5cdb8d81514d3216e68770561a248015673158c92b36b8cc033e60ee65', true),
  ('public.save_employee_note(uuid,text,text,text,boolean)', 'a29a1c53dae0546b1e60aee079eb63fc4638f31b0420645a8179fca31f54aa2a', true),
  ('private.validate_location_observation_session()', '8b5f6016ba6a02522cd0ab8df754eb71a89e7b3658f88797ae21293204c675a2', false)
), function_checks as (
  select 'function: ' || e.signature as check_name,
    coalesce(encode(sha256(convert_to(replace(p.prosrc, E'\r\n', E'\n'), 'UTF8')), 'hex') = e.body_sha256
      and ('search_path=""' = any(p.proconfig))
      and has_function_privilege('authenticated', p.oid, 'EXECUTE') = e.client_execute
      and not has_function_privilege('anon', p.oid, 'EXECUTE')
      and p.prosecdef = (e.signature not in (
        'private.attendance_write_contract()', 'private.validate_location_observation_session()')), false) as passed
  from expected_functions e left join pg_proc p on p.oid=to_regprocedure(e.signature)
), checks as (
  select * from function_checks
  union all select 'exact migration history',
    (select array_agg(version::text order by version) from supabase_migrations.schema_migrations)
      = array['20261013000100','20261016000100','20261017000100','20261017000200','20261021000100']
  union all select 'recognized constant legacy gate 1', exists(
    select 1 from pg_proc p join pg_language l on l.oid=p.prolang
    where p.oid=to_regprocedure('private.attendance_write_contract()') and l.lanname='sql'
      and p.pronargs=0 and p.prorettype='int4'::regtype
      and regexp_replace(p.prosrc,'[[:space:];]','','g')='select1')
  union all select 'no unexpected public RPC overloads',
    (select count(*)=6 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in
        ('check_in','check_out','check_in_v2','check_out_v2','update_employee_note','save_employee_note'))
  union all select 'five additive nullable columns',
    (select count(*)=5 from information_schema.columns where table_schema='public' and is_nullable='YES'
      and ((table_name='companies' and column_name in ('factory_latitude','factory_longitude','factory_radius_meters'))
        or (table_name='work_sessions' and column_name='employee_note')
        or (table_name='session_events' and column_name='metadata')))
  union all select 'History composite relationships retained',
    (select count(*)=2 from pg_constraint where
      (conrelid='public.work_sessions'::regclass and conname='work_sessions_employee_company_fk') or
      (conrelid='public.role_assignments'::regclass and conname='role_assignments_profile_company_fk'))
  union all select 'application tables retain RLS and authenticated read-only grants',
    (select count(*)=7 and bool_and(c.relrowsecurity
      and has_table_privilege('authenticated',c.oid,'SELECT')
      and not has_table_privilege('authenticated',c.oid,'INSERT')
      and not has_table_privilege('authenticated',c.oid,'UPDATE')
      and not has_table_privilege('authenticated',c.oid,'DELETE'))
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relname in
      ('companies','user_profiles','role_assignments','work_sessions','session_events','location_observations','admin_audit_events'))
  union all select 'private note evidence has no client table grants', exists(
    select 1 from pg_class c where c.oid=to_regclass('private.employee_note_operations') and c.relrowsecurity
      and not has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE')
      and not has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE'))
  union all select 'baseline session shapes remain compatible', not exists(
    select 1 from public.work_sessions where
      location_context not in ('factory','external_worksite','location_unverified') or
      lifecycle_status not in ('active','closed_manual','closed_automatic','closed_admin','voided') or
      review_status not in ('normal','anomaly_open','correction_pending','reviewed','corrected','disputed') or
      (site_description is not null and char_length(site_description)>500) or
      not isfinite(started_at) or (ended_at is not null and not isfinite(ended_at)) or
      (lifecycle_status='active') <> (ended_at is null) or ended_at<started_at)
)
select check_name,coalesce(passed,false) as passed from checks order by check_name;
rollback;
