-- DEVELOPMENT ONLY. Run separately AFTER the maintenance fence is committed.
-- Required private setting after BEGIN: chantipoint.maintenance.expected_epoch.
-- Verify stopped/quarantined clients independently; SQL cannot inspect journals.
-- On failure inspect committed state. Never improvise a gate-1 rollback.
begin;
set local statement_timeout = '10s';
set local lock_timeout = '3s';
do $$
declare v_changed integer;
begin
  if has_schema_privilege('anon','public','USAGE') or
     has_schema_privilege('authenticated','public','USAGE') or
     has_schema_privilege('service_role','public','USAGE') then
    raise exception 'maintenance_fence_required';
  end if;
  if exists(select 1 from pg_prepared_xacts) then
    raise exception 'maintenance_prepared_transactions_present';
  end if;
  if exists(select 1 from pg_stat_activity where pid<>pg_backend_pid()
    and usename in ('authenticator','authenticated','anon')
    and xact_start is not null) then
    raise exception 'maintenance_api_transactions_not_drained';
  end if;
  if not pg_try_advisory_xact_lock(174811,2) then
    raise exception 'maintenance_writers_not_drained';
  end if;
  update private.attendance_deployment set write_contract=2
    where singleton and write_contract=1 and deployment_epoch=
      current_setting('chantipoint.maintenance.expected_epoch')::uuid;
  get diagnostics v_changed = row_count;
  if v_changed<>1 then raise exception 'maintenance_deployment_mismatch'; end if;
end;
$$;
notify pgrst, 'reload schema';
commit;
