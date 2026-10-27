-- PREPARED ONLY: trusted operator, verified chantipoint-dev link, no client use.
-- First create the approved distinct Auth identity through supported Supabase
-- Auth administration. Do not insert directly into auth.users or invent a password.
-- In a PRIVATE copy, set these transaction-local values immediately after BEGIN:
-- chantipoint.beta.expected_epoch, auth_user_id, company_id, email, display_name.
-- Independently verify company/identity and retain the operator approval record.
-- This reviewed template defaults to ROLLBACK. A separately authorized real
-- provisioning uses COMMIT in the private copy after the same guards/probes.
begin;
set local statement_timeout = '10s';
set local lock_timeout = '3s';
do $$
declare
  v_auth uuid := current_setting('chantipoint.beta.auth_user_id')::uuid;
  v_company uuid := current_setting('chantipoint.beta.company_id')::uuid;
  v_email text := current_setting('chantipoint.beta.email');
  v_name text := current_setting('chantipoint.beta.display_name');
  v_profile uuid;
begin
  if not exists(select 1 from private.attendance_deployment where singleton
    and write_contract=2 and deployment_epoch=
      current_setting('chantipoint.beta.expected_epoch')::uuid) then
    raise exception 'beta_deployment_mismatch';
  end if;
  if not exists(select 1 from auth.users where id=v_auth
    and lower(email)=lower(v_email) and email_confirmed_at is not null
    and deleted_at is null) then raise exception 'beta_auth_identity_not_confirmed'; end if;
  if not exists(select 1 from public.companies where id=v_company and status='active') then
    raise exception 'beta_company_unavailable';
  end if;
  if exists(select 1 from public.user_profiles where auth_user_id=v_auth) then
    raise exception 'beta_identity_already_provisioned_review_required';
  end if;
  insert into public.user_profiles(auth_user_id,company_id,display_name,email,status)
    values(v_auth,v_company,v_name,v_email,'active') returning id into v_profile;
  insert into public.role_assignments(user_profile_id,company_id,role,status)
    values(v_profile,v_company,'employee','active');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_auth,
    'role','authenticated')::text,true);
end;
$$;
set local role authenticated;
do $$
begin
  if (select count(*) from public.user_profiles where auth_user_id=auth.uid())<>1 then
    raise exception 'beta_own_profile_not_visible';
  end if;
  if exists(select 1 from public.role_assignments where role='administrator'
    and user_profile_id in (select id from public.user_profiles where auth_user_id=auth.uid())) then
    raise exception 'beta_unexpected_administrator';
  end if;
  if exists(select 1 from public.work_sessions w where not exists(
    select 1 from public.user_profiles p where p.id=w.employee_profile_id and p.auth_user_id=auth.uid())) then
    raise exception 'beta_foreign_history_visible';
  end if;
  if exists(select 1 from public.work_sessions) then
    raise exception 'beta_fresh_account_has_unexpected_history';
  end if;
end;
$$;
select true as beta_employee_provisioning_dry_run_passed;
rollback;
