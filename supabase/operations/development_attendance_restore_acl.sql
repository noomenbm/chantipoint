-- DEVELOPMENT ONLY. Restore ONLY the verified original usage grants.
-- Required private settings: expected_epoch, original_public_acl.
-- Private renderer inserts SET LOCAL ROLE <original grantor> / GRANT USAGE
-- for each of PUBLIC, anon, authenticated, service_role at the marker below.
-- No ownership, CREATE, grant option or unrelated privilege is changed.
-- The final exact ACL comparison rolls back any inexact restoration.
begin;
set local statement_timeout = '10s';
set local lock_timeout = '3s';
-- RESTORE_ORIGINAL_USAGE_GRANTS_HERE
do $$
declare v_acl jsonb;
begin
  if not exists(select 1 from private.attendance_deployment where singleton
    and write_contract in (1,2) and deployment_epoch=
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
    raise exception 'maintenance_acl_not_restored_exactly';
  end if;
end;
$$;
commit;
