-- DEVELOPMENT ONLY. Render required settings into a private copy after BEGIN.
-- Required: chantipoint.maintenance.expected_epoch, original_public_acl.
-- The original ACL is the exact JSONB aggregate below, captured before fencing.
-- Apply only after verified backup, seven-state gate-1 checks, and client quarantine.
begin;
set local statement_timeout = '10s';
set local lock_timeout = '3s';
do $$
declare v_acl jsonb;
begin
  if not exists(select 1 from private.attendance_deployment where singleton
    and write_contract=1 and deployment_epoch=
      current_setting('chantipoint.maintenance.expected_epoch')::uuid) then
    raise exception 'maintenance_deployment_mismatch';
  end if;
  select jsonb_agg(jsonb_build_object('grantee',case when a.grantee=0 then 'PUBLIC'
      else pg_get_userbyid(a.grantee) end,'grantor',pg_get_userbyid(a.grantor),
      'privilege',a.privilege_type,'grantable',a.is_grantable)
      order by a.grantee,a.grantor,a.privilege_type)
    into v_acl from pg_namespace n
    cross join lateral aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
    where n.nspname='public';
  if v_acl is distinct from
      current_setting('chantipoint.maintenance.original_public_acl')::jsonb then
    raise exception 'maintenance_original_acl_mismatch';
  end if;
end;
$$;
revoke usage on schema public from public, anon, authenticated, service_role;
do $$
begin
  if has_schema_privilege('anon','public','USAGE') or
     has_schema_privilege('authenticated','public','USAGE') or
     has_schema_privilege('service_role','public','USAGE') then
    raise exception 'maintenance_inherited_usage_not_fenced';
  end if;
end;
$$;
commit;
