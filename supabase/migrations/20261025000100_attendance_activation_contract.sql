-- Local v2 activation contract; applying this migration does NOT activate v2.
-- Apply transactionally. Do not edit already-applied migration files.
do $$
begin
  perform pg_catalog.pg_advisory_xact_lock(174811, 2);
  if private.attendance_write_contract() is distinct from 1 then
    raise exception 'attendance_activation_requires_legacy_mode' using errcode = 'P0001';
  end if;
end;
$$;

-- One server-generated identity for this deployment/restore epoch, not a secret
-- or client authority. Restore/clone operators must rotate it before API admission.
create table private.attendance_deployment (
  singleton boolean primary key default true check (singleton),
  deployment_epoch uuid not null default gen_random_uuid(),
  write_contract integer not null default 1 check (write_contract in (1, 2))
);
alter table private.attendance_deployment enable row level security;
revoke all on table private.attendance_deployment from public, anon, authenticated;
insert into private.attendance_deployment (singleton) values (true);

-- BEFORE STATEMENT takes the exclusive lock before UPDATE/DELETE row locks.
-- Ordinary trusted gate/epoch updates serialize with every guarded writer.
create function private.lock_attendance_deployment_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(174811, 2);
  return null;
end;
$$;
create trigger attendance_deployment_change_lock
before insert or update or delete on private.attendance_deployment
for each statement execute function private.lock_attendance_deployment_change();

create function private.locked_attendance_deployment()
returns private.attendance_deployment
language plpgsql volatile security definer set search_path = '' as $$
declare v_state private.attendance_deployment%rowtype;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(174811, 2);
  select * into v_state from private.attendance_deployment where singleton for share;
  if not found then
    raise exception 'attendance_deployment_unavailable' using errcode = 'P0001';
  end if;
  -- Row lock also prevents stale REPEATABLE READ snapshots silently succeeding:
  -- PostgreSQL raises serialization_failure if the row changed since the snapshot.
  return v_state;
end;
$$;

-- Same private gate interface; the migration leaves its observable value at 1.
create or replace function private.attendance_write_contract()
returns integer language sql volatile set search_path = '' as $$
  select (private.locked_attendance_deployment()).write_contract
$$;

-- STABLE and free of row/advisory locks: callable via GET in READ ONLY.
-- A capability is a snapshot, never a lease or permission to dispatch by itself.
create function public.attendance_capability()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_state private.attendance_deployment%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.user_profiles p join public.role_assignments r
      on r.user_profile_id=p.id and r.company_id=p.company_id
    where p.auth_user_id=auth.uid() and p.status='active'
      and r.role='employee' and r.status='active'
  ) then
    raise exception 'employee_role_required' using errcode = '42501';
  end if;
  select * into v_state from private.attendance_deployment where singleton;
  return jsonb_build_object('capability_version', 1,
    'deployment_epoch', v_state.deployment_epoch,
    'write_contract', v_state.write_contract,
    'v2_available', coalesce(v_state.write_contract=2, false));
end;
$$;

-- Request metadata only: never add epoch to frozen RPC JSON/hash/receipt.
-- PostgREST lowercases header names in the transaction-local request.headers GUC.
create function private.require_attendance_epoch()
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
  v_state private.attendance_deployment%rowtype;
  v_text text := nullif(current_setting('request.headers', true), '');
  v_headers jsonb;
  v_expected text;
begin
  v_state := private.locked_attendance_deployment();
  if v_text is null then
    raise exception 'attendance_epoch_required' using errcode = 'P0001';
  end if;
  if octet_length(v_text)>65536 then
    raise exception 'attendance_epoch_invalid' using errcode = 'P0001';
  end if;
  begin
    v_headers := v_text::jsonb;
  exception when invalid_text_representation then
    raise exception 'attendance_epoch_invalid' using errcode = 'P0001';
  end;
  if jsonb_typeof(v_headers) is distinct from 'object' then
    raise exception 'attendance_epoch_invalid' using errcode = 'P0001';
  end if;
  if not (v_headers ? 'x-chantipoint-attendance-epoch') then
    raise exception 'attendance_epoch_required' using errcode = 'P0001';
  end if;
  v_expected := v_headers->>'x-chantipoint-attendance-epoch';
  if jsonb_typeof(v_headers->'x-chantipoint-attendance-epoch') is distinct from 'string'
    or v_expected !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'attendance_epoch_invalid' using errcode = 'P0001';
  end if;
  if v_expected is distinct from v_state.deployment_epoch::text then
    raise exception 'attendance_epoch_mismatch' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.check_in(
  p_location_context text, p_site_description text, p_device_observed_at timestamptz, p_idempotency_key text,
  p_latitude numeric default null, p_longitude numeric default null,
  p_accuracy_meters numeric default null, p_provider text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if private.attendance_write_contract() is distinct from 1 then
    raise exception 'attendance_client_update_required' using errcode = 'P0001';
  end if;
  return private.check_in_legacy_impl(p_location_context, p_site_description, p_device_observed_at,
    p_idempotency_key, p_latitude, p_longitude, p_accuracy_meters, p_provider);
end;
$$;

create or replace function public.check_out(
  p_work_session_id uuid, p_idempotency_key text, p_device_observed_at timestamptz default null,
  p_latitude numeric default null, p_longitude numeric default null,
  p_accuracy_meters numeric default null, p_provider text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if private.attendance_write_contract() is distinct from 1 then
    raise exception 'attendance_client_update_required' using errcode = 'P0001';
  end if;
  return private.check_out_legacy_impl(p_work_session_id, p_idempotency_key,
    p_device_observed_at, p_latitude, p_longitude, p_accuracy_meters, p_provider);
end;
$$;

create or replace function public.check_in_v2(
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_site_description text default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_location_observed_at timestamptz default null,
  p_permission text default 'unknown',
  p_services_enabled boolean default null,
  p_location_result text default 'unknown',
  p_provider text default 'unknown',
  p_replay_only boolean default false
)
returns jsonb language plpgsql volatile security definer set search_path = '' set timezone = 'UTC'
as $$
begin
  perform private.require_attendance_epoch();
  return private.submit_attendance(2, 'check_in', null, p_idempotency_key,
    p_device_observed_at, p_site_description, p_latitude, p_longitude, p_accuracy_meters,
    p_location_observed_at, p_permission, p_services_enabled, p_location_result, p_provider, p_replay_only);
end;
$$;

create or replace function public.check_out_v2(
  p_work_session_id uuid,
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_location_observed_at timestamptz default null,
  p_permission text default 'unknown',
  p_services_enabled boolean default null,
  p_location_result text default 'unknown',
  p_provider text default 'unknown',
  p_replay_only boolean default false,
  p_note_action text default 'preserve',
  p_employee_note text default null
)
returns jsonb language plpgsql volatile security definer set search_path = '' set timezone = 'UTC'
as $$
begin
  perform private.require_attendance_epoch();
  return private.submit_attendance(2, 'check_out', p_work_session_id, p_idempotency_key,
    p_device_observed_at, null, p_latitude, p_longitude, p_accuracy_meters,
    p_location_observed_at, p_permission, p_services_enabled, p_location_result, p_provider, p_replay_only,
    p_note_action, p_employee_note);
end;
$$;

-- Preserve the exact note implementations, default arguments, hashing and
-- terminal evidence at gate 1. Clients cannot invoke the relocated bodies.
alter function public.update_employee_note(uuid, text) set schema private;
alter function private.update_employee_note(uuid, text) rename to update_employee_note_legacy_impl;
alter function public.save_employee_note(uuid, text, text, text, boolean) set schema private;
alter function private.save_employee_note(uuid, text, text, text, boolean) rename to save_employee_note_legacy_impl;
revoke all on function private.update_employee_note_legacy_impl(uuid, text) from public, anon, authenticated;
revoke all on function private.save_employee_note_legacy_impl(uuid, text, text, text, boolean) from public, anon, authenticated;

create or replace function public.update_employee_note(
  p_work_session_id uuid,
  p_employee_note text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if private.attendance_write_contract() is distinct from 1 then
    raise exception 'standalone_notes_not_enabled' using errcode = 'P0001';
  end if;
  return private.update_employee_note_legacy_impl(p_work_session_id, p_employee_note);
end;
$$;

create or replace function public.save_employee_note(
  p_work_session_id uuid,
  p_operation_key text,
  p_note_action text,
  p_employee_note text,
  p_replay_only boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' set timezone = 'UTC'
as $$
begin
  if private.attendance_write_contract() is distinct from 1 then
    raise exception 'standalone_notes_not_enabled' using errcode = 'P0001';
  end if;
  return private.save_employee_note_legacy_impl(p_work_session_id, p_operation_key,
    p_note_action, p_employee_note, p_replay_only);
end;
$$;

revoke all on function private.lock_attendance_deployment_change() from public, anon, authenticated;
revoke all on function private.locked_attendance_deployment() from public, anon, authenticated;
revoke all on function private.require_attendance_epoch() from public, anon, authenticated;
revoke all on function private.attendance_write_contract() from public, anon, authenticated;
revoke all on function public.attendance_capability() from public, anon;
grant execute on function public.attendance_capability() to authenticated;
revoke all on function public.update_employee_note(uuid, text) from public, anon;
revoke all on function public.save_employee_note(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.update_employee_note(uuid, text) to authenticated;
grant execute on function public.save_employee_note(uuid, text, text, text, boolean) to authenticated;
-- CREATE OR REPLACE retains the existing attendance RPC ACLs and signatures.
notify pgrst, 'reload schema';
