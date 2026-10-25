-- Run ONLY after verifying the linked project is chantipoint-dev.
-- Metadata and aggregate booleans only: no identities, coordinates, notes,
-- session contents, credential reads, attendance RPCs, or activation.
-- Missing/incompatible objects are blockers, never implicit approval.
begin read only;
set local statement_timeout = '10s';

select jsonb_build_object(
  'migrations', (
    select jsonb_agg(version order by version)
    from supabase_migrations.schema_migrations
  ),
  'columns', (
    select jsonb_agg(jsonb_build_object(
      'table', table_name, 'column', column_name, 'type', data_type,
      'nullable', is_nullable
    ) order by table_name, column_name)
    from information_schema.columns
    where table_schema = 'public' and (
      (table_name = 'companies' and column_name in
        ('factory_latitude', 'factory_longitude', 'factory_radius_meters')) or
      (table_name = 'work_sessions' and column_name in
        ('employee_note', 'review_status', 'location_context', 'lifecycle_status')) or
      (table_name = 'session_events' and column_name = 'metadata')
    )
  ),
  'functions', (
    select jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'name', p.proname,
      'arguments', pg_catalog.pg_get_function_identity_arguments(p.oid),
      'result', pg_catalog.pg_get_function_result(p.oid),
      'security_definer', p.prosecdef,
      'empty_search_path', coalesce('search_path=""' = any(p.proconfig), false),
      'body_sha256', encode(sha256(convert_to(replace(p.prosrc, E'\r\n', E'\n'), 'UTF8')), 'hex'),
      'authenticated_execute', pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE'),
      'anon_execute', pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE'),
      'recognized_gate_mode', case
        when n.nspname = 'private' and p.proname = 'attendance_write_contract'
          and l.lanname = 'sql' and p.pronargs = 0
          and p.prorettype = 'pg_catalog.int4'::regtype then case
          pg_catalog.regexp_replace(p.prosrc, '[[:space:];]', '', 'g')
          when 'select1' then 1 when 'select2' then 2 else null end
        else null end
    ) order by n.nspname, p.proname, p.oid)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    join pg_catalog.pg_language l on l.oid = p.prolang
    where (n.nspname = 'public' and p.proname in
      ('check_in', 'check_out', 'check_in_v2', 'check_out_v2',
       'update_employee_note', 'save_employee_note')) or
      (n.nspname = 'private' and p.proname in
       ('attendance_write_contract', 'check_in_legacy_impl', 'check_out_legacy_impl'))
  ),
  'relations', (
    select jsonb_agg(jsonb_build_object(
      'schema', n.nspname, 'table', c.relname, 'rls', c.relrowsecurity,
      'authenticated_select', pg_catalog.has_table_privilege('authenticated', c.oid, 'SELECT'),
      'authenticated_insert', pg_catalog.has_table_privilege('authenticated', c.oid, 'INSERT'),
      'authenticated_update', pg_catalog.has_table_privilege('authenticated', c.oid, 'UPDATE'),
      'authenticated_delete', pg_catalog.has_table_privilege('authenticated', c.oid, 'DELETE')
    ) order by n.nspname, c.relname)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'r' and (
      (n.nspname = 'public' and c.relname in
       ('user_profiles', 'role_assignments', 'work_sessions', 'session_events', 'location_observations')) or
      (n.nspname = 'private' and c.relname = 'employee_note_operations')
    )
  ),
  'required_composite_relationships', (
    select jsonb_agg(conname order by conname)
    from pg_catalog.pg_constraint
    where conrelid in ('public.work_sessions'::regclass, 'public.role_assignments'::regclass)
      and conname in ('work_sessions_employee_company_fk', 'role_assignments_profile_company_fk')
  ),
  'existing_sessions_present', exists(select 1 from public.work_sessions),
  'active_sessions_present', exists(select 1 from public.work_sessions where lifecycle_status = 'active'),
  -- This tests the baseline fields only, NOT PostgREST/RLS as an employee.
  -- employee_note must exist before enabling the enriched SELECT projection.
  'incompatible_baseline_session_shape_present', exists(
    select 1 from public.work_sessions where
      location_context not in ('factory', 'external_worksite', 'location_unverified') or
      lifecycle_status not in ('active', 'closed_manual', 'closed_automatic', 'closed_admin', 'voided') or
      review_status not in ('normal', 'anomaly_open', 'correction_pending', 'reviewed', 'corrected', 'disputed') or
      (site_description is not null and char_length(site_description) > 500) or
      not isfinite(started_at) or (ended_at is not null and not isfinite(ended_at)) or
      (lifecycle_status = 'active') <> (ended_at is null) or ended_at < started_at
  )
) as cutover_inspection;

rollback;
