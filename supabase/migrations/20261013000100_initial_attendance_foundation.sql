-- ChantiPoint M2.1 initial database foundation.
-- Local review artifact only; do not apply to hosted Supabase before human review.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

create table public.companies (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 200),
  status text not null default 'active' check (status in ('active', 'suspended', 'archived')),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp()
);

create table public.user_profiles (
  id uuid primary key default extensions.gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete restrict,
  employee_number text null check (employee_number is null or length(btrim(employee_number)) between 1 and 64),
  display_name text not null check (length(btrim(display_name)) between 1 and 200),
  email text not null check (position('@' in email) > 1 and length(email) <= 320),
  status text not null default 'active' check (status in ('active', 'disabled', 'invited', 'archived')),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint user_profiles_auth_user_id_key unique (auth_user_id),
  constraint user_profiles_id_company_id_key unique (id, company_id)
);

create unique index user_profiles_company_employee_number_key
  on public.user_profiles (company_id, employee_number)
  where employee_number is not null;

create unique index user_profiles_company_lower_email_key
  on public.user_profiles (company_id, lower(email));

create table public.role_assignments (
  id uuid primary key default extensions.gen_random_uuid(),
  user_profile_id uuid not null,
  company_id uuid not null references public.companies(id) on delete restrict,
  role text not null check (role in ('employee', 'administrator')),
  status text not null default 'active' check (status in ('active', 'revoked')),
  created_by_profile_id uuid null references public.user_profiles(id) on delete set null,
  created_at timestamptz not null default statement_timestamp(),
  revoked_at timestamptz null,
  constraint role_assignments_profile_company_fk
    foreign key (user_profile_id, company_id)
    references public.user_profiles(id, company_id)
    on delete restrict,
  constraint role_assignments_revoked_at_status_check
    check ((status = 'revoked' and revoked_at is not null) or (status = 'active' and revoked_at is null))
);

create unique index role_assignments_one_active_role_per_profile
  on public.role_assignments (user_profile_id, role)
  where status = 'active';

create index role_assignments_company_role_idx
  on public.role_assignments (company_id, role, status);

create table public.work_sessions (
  id uuid primary key default extensions.gen_random_uuid(),
  employee_profile_id uuid not null,
  company_id uuid not null references public.companies(id) on delete restrict,
  location_context text not null check (location_context in ('factory', 'external_worksite')),
  site_description text null check (site_description is null or length(site_description) <= 500),
  lifecycle_status text not null default 'active'
    check (lifecycle_status in ('active', 'closed_manual', 'closed_automatic', 'closed_admin', 'voided')),
  review_status text not null default 'normal'
    check (review_status in ('normal', 'anomaly_open', 'correction_pending', 'reviewed', 'corrected', 'disputed')),
  current_monitoring_status text not null default 'not_applicable'
    check (current_monitoring_status in (
      'not_applicable',
      'pending',
      'enabled',
      'disabled_detected',
      'permission_revoked_detected',
      'unavailable',
      'inconclusive',
      'stopped'
    )),
  started_at timestamptz not null default statement_timestamp(),
  ended_at timestamptz null,
  checkout_source text null check (checkout_source is null or checkout_source in ('manual', 'automatic', 'administrator')),
  checkout_reason_code text null check (checkout_reason_code is null or length(checkout_reason_code) <= 80),
  automatic_checkout_evidence_summary text null check (
    automatic_checkout_evidence_summary is null
    or length(automatic_checkout_evidence_summary) <= 1000
  ),
  check_in_device_observed_at timestamptz null,
  check_out_device_observed_at timestamptz null,
  check_in_idempotency_key text not null check (length(btrim(check_in_idempotency_key)) between 8 and 160),
  check_in_request_hash text not null check (length(check_in_request_hash) = 64),
  check_out_idempotency_key text null check (
    check_out_idempotency_key is null
    or length(btrim(check_out_idempotency_key)) between 8 and 160
  ),
  check_out_request_hash text null check (check_out_request_hash is null or length(check_out_request_hash) = 64),
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint work_sessions_employee_company_fk
    foreign key (employee_profile_id, company_id)
    references public.user_profiles(id, company_id)
    on delete restrict,
  constraint work_sessions_id_company_employee_key unique (id, company_id, employee_profile_id),
  constraint work_sessions_ended_at_after_started_at_check
    check (ended_at is null or ended_at >= started_at),
  constraint work_sessions_active_shape_check
    check (
      (lifecycle_status = 'active' and ended_at is null and checkout_source is null)
      or
      (lifecycle_status <> 'active' and ended_at is not null)
    ),
  constraint work_sessions_factory_monitoring_check
    check (location_context <> 'factory' or current_monitoring_status in ('not_applicable', 'stopped'))
);

create unique index work_sessions_one_active_per_employee
  on public.work_sessions (employee_profile_id)
  where lifecycle_status = 'active';

create unique index work_sessions_employee_check_in_idempotency_key
  on public.work_sessions (employee_profile_id, check_in_idempotency_key);

create unique index work_sessions_employee_check_out_idempotency_key
  on public.work_sessions (employee_profile_id, check_out_idempotency_key)
  where check_out_idempotency_key is not null;

create index work_sessions_employee_check_in_request_hash_idx
  on public.work_sessions (employee_profile_id, check_in_request_hash);

create index work_sessions_employee_started_at_idx
  on public.work_sessions (employee_profile_id, started_at desc);

create index work_sessions_company_started_at_idx
  on public.work_sessions (company_id, started_at desc);

create table public.session_events (
  id uuid primary key default extensions.gen_random_uuid(),
  work_session_id uuid not null,
  employee_profile_id uuid not null,
  company_id uuid not null references public.companies(id) on delete restrict,
  event_type text not null check (event_type in (
    'check_in',
    'manual_checkout',
    'automatic_checkout',
    'admin_closure',
    'monitoring_status',
    'location_observation',
    'correction',
    'notification'
  )),
  source text not null check (source in ('employee_app', 'admin_app', 'system', 'platform_callback')),
  actor_profile_id uuid null references public.user_profiles(id) on delete restrict,
  device_observed_at timestamptz null,
  callback_received_at timestamptz null,
  server_accepted_at timestamptz not null default statement_timestamp(),
  reason_code text null check (reason_code is null or length(reason_code) <= 80),
  notes text null check (notes is null or length(notes) <= 1000),
  idempotency_key text null check (idempotency_key is null or length(btrim(idempotency_key)) between 8 and 160),
  created_at timestamptz not null default statement_timestamp(),
  constraint session_events_session_identity_fk
    foreign key (work_session_id, company_id, employee_profile_id)
    references public.work_sessions(id, company_id, employee_profile_id)
    on delete restrict,
  constraint session_events_id_session_identity_key unique (id, work_session_id, company_id, employee_profile_id)
);

create unique index session_events_session_event_idempotency_key
  on public.session_events (work_session_id, event_type, idempotency_key)
  where idempotency_key is not null;

create index session_events_work_session_time_idx
  on public.session_events (work_session_id, server_accepted_at);

create index session_events_company_time_idx
  on public.session_events (company_id, server_accepted_at desc);

create table public.location_observations (
  id uuid primary key default extensions.gen_random_uuid(),
  work_session_id uuid not null,
  session_event_id uuid null,
  employee_profile_id uuid not null,
  company_id uuid not null references public.companies(id) on delete restrict,
  observation_type text not null check (observation_type in (
    'check_in_location',
    'checkout_location',
    'geofence_exit',
    'geofence_enter',
    'periodic_observation',
    'unavailable'
  )),
  latitude numeric(9,6) null,
  longitude numeric(9,6) null,
  accuracy_meters numeric(10,2) null check (accuracy_meters is null or accuracy_meters >= 0),
  geofence_radius_meters integer null check (geofence_radius_meters is null or geofence_radius_meters > 0),
  provider text null check (
    provider is null
    or provider in ('gps', 'network', 'fused', 'geofence', 'platform_event', 'emulator', 'unknown')
  ),
  device_observed_at timestamptz null,
  callback_received_at timestamptz null,
  server_received_at timestamptz not null default statement_timestamp(),
  raw_metadata jsonb null check (raw_metadata is null or jsonb_typeof(raw_metadata) = 'object'),
  created_at timestamptz not null default statement_timestamp(),
  constraint location_observations_session_identity_fk
    foreign key (work_session_id, company_id, employee_profile_id)
    references public.work_sessions(id, company_id, employee_profile_id)
    on delete restrict,
  constraint location_observations_event_identity_fk
    foreign key (session_event_id, work_session_id, company_id, employee_profile_id)
    references public.session_events(id, work_session_id, company_id, employee_profile_id)
    on delete restrict,
  constraint location_observations_coordinate_pair_check
    check ((latitude is null and longitude is null) or (latitude is not null and longitude is not null)),
  constraint location_observations_latitude_range_check
    check (latitude is null or (latitude >= -90 and latitude <= 90)),
  constraint location_observations_longitude_range_check
    check (longitude is null or (longitude >= -180 and longitude <= 180)),
  constraint location_observations_location_required_check
    check (observation_type = 'unavailable' or (latitude is not null and longitude is not null))
);

create index location_observations_work_session_time_idx
  on public.location_observations (work_session_id, server_received_at);

create index location_observations_company_time_idx
  on public.location_observations (company_id, server_received_at desc);

create table public.admin_audit_events (
  id uuid primary key default extensions.gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  actor_profile_id uuid not null,
  action text not null check (action in ('role_assignment_revoked', 'user_profile_disabled')),
  target_profile_id uuid null references public.user_profiles(id) on delete restrict,
  target_role_assignment_id uuid null references public.role_assignments(id) on delete restrict,
  server_recorded_at timestamptz not null default statement_timestamp(),
  action_details jsonb not null default '{}'::jsonb check (jsonb_typeof(action_details) = 'object'),
  constraint admin_audit_events_actor_company_fk
    foreign key (actor_profile_id, company_id)
    references public.user_profiles(id, company_id)
    on delete restrict,
  constraint admin_audit_events_target_required_check
    check (target_profile_id is not null or target_role_assignment_id is not null)
);

create index admin_audit_events_company_time_idx
  on public.admin_audit_events (company_id, server_recorded_at desc);

create index admin_audit_events_target_profile_idx
  on public.admin_audit_events (target_profile_id)
  where target_profile_id is not null;

create index admin_audit_events_target_role_assignment_idx
  on public.admin_audit_events (target_role_assignment_id)
  where target_role_assignment_id is not null;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = statement_timestamp();
  return new;
end;
$$;

create trigger companies_set_updated_at
  before update on public.companies
  for each row execute function private.set_updated_at();

create trigger user_profiles_set_updated_at
  before update on public.user_profiles
  for each row execute function private.set_updated_at();

create trigger work_sessions_set_updated_at
  before update on public.work_sessions
  for each row execute function private.set_updated_at();

create or replace function private.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select up.id
  from public.user_profiles as up
  where up.auth_user_id = auth.uid()
    and up.status = 'active'
  limit 1
$$;

create or replace function private.current_company_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select up.company_id
  from public.user_profiles as up
  where up.auth_user_id = auth.uid()
    and up.status = 'active'
  limit 1
$$;

create or replace function private.current_user_has_role(p_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_profiles as up
    join public.role_assignments as ra
      on ra.user_profile_id = up.id
     and ra.company_id = up.company_id
    where up.auth_user_id = auth.uid()
      and up.status = 'active'
      and ra.role = p_role
      and ra.status = 'active'
  )
$$;

create or replace function private.current_user_is_company_admin(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_profiles as up
    join public.role_assignments as ra
      on ra.user_profile_id = up.id
     and ra.company_id = up.company_id
    where up.auth_user_id = auth.uid()
      and up.company_id = p_company_id
      and up.status = 'active'
      and ra.role = 'administrator'
      and ra.status = 'active'
  )
$$;

create or replace function private.current_user_can_read_own_attendance(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_profiles as up
    join public.role_assignments as ra
      on ra.user_profile_id = up.id
     and ra.company_id = up.company_id
    where up.auth_user_id = auth.uid()
      and up.id = p_profile_id
      and up.status = 'active'
      and ra.role = 'employee'
      and ra.status = 'active'
  )
$$;

create or replace function private.prevent_last_admin_role_loss()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target_profile_active boolean;
  v_remaining_active_admins integer;
begin
  if tg_op = 'UPDATE' then
    if new.user_profile_id <> old.user_profile_id
      or new.company_id <> old.company_id
      or new.role <> old.role then
      raise exception 'role_assignment_identity_immutable'
        using errcode = '23514';
    end if;

    if old.role <> 'administrator' or old.status <> 'active' or new.status = 'active' then
      return new;
    end if;
  elsif tg_op = 'DELETE' then
    if old.role <> 'administrator' or old.status <> 'active' then
      return old;
    end if;
  end if;

  select up.status = 'active'
    into v_target_profile_active
  from public.user_profiles as up
  where up.id = old.user_profile_id
    and up.company_id = old.company_id;

  if not coalesce(v_target_profile_active, false) then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  perform 1
  from public.companies as c
  where c.id = old.company_id
  for update;

  select count(*)::integer
    into v_remaining_active_admins
  from public.role_assignments as ra
  join public.user_profiles as up
    on up.id = ra.user_profile_id
   and up.company_id = ra.company_id
  where ra.company_id = old.company_id
    and ra.id <> old.id
    and ra.role = 'administrator'
    and ra.status = 'active'
    and up.status = 'active';

  if v_remaining_active_admins < 1 then
    raise exception 'last_active_administrator_required'
      using errcode = '23514';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create trigger role_assignments_prevent_last_admin_loss
  before update or delete on public.role_assignments
  for each row execute function private.prevent_last_admin_role_loss();

create or replace function private.prevent_last_admin_profile_disable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_active_admin_role boolean;
  v_remaining_active_admins integer;
begin
  if tg_op = 'UPDATE' then
    if new.auth_user_id <> old.auth_user_id or new.company_id <> old.company_id then
      raise exception 'user_profile_identity_immutable'
        using errcode = '23514';
    end if;

    if old.status <> 'active' or new.status = 'active' then
      return new;
    end if;
  elsif tg_op = 'DELETE' then
    if old.status <> 'active' then
      return old;
    end if;
  end if;

  select exists (
    select 1
    from public.role_assignments as ra
    where ra.user_profile_id = old.id
      and ra.company_id = old.company_id
      and ra.role = 'administrator'
      and ra.status = 'active'
  )
  into v_has_active_admin_role;

  if not v_has_active_admin_role then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  perform 1
  from public.companies as c
  where c.id = old.company_id
  for update;

  select count(*)::integer
    into v_remaining_active_admins
  from public.role_assignments as ra
  join public.user_profiles as up
    on up.id = ra.user_profile_id
   and up.company_id = ra.company_id
  where ra.company_id = old.company_id
    and ra.user_profile_id <> old.id
    and ra.role = 'administrator'
    and ra.status = 'active'
    and up.status = 'active';

  if v_remaining_active_admins < 1 then
    raise exception 'last_active_administrator_required'
      using errcode = '23514';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

create trigger user_profiles_prevent_last_admin_disable
  before update or delete on public.user_profiles
  for each row execute function private.prevent_last_admin_profile_disable();

create or replace function private.validate_location_observation_session()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_location_context text;
  v_lifecycle_status text;
begin
  select ws.location_context, ws.lifecycle_status
    into v_location_context, v_lifecycle_status
  from public.work_sessions as ws
  where ws.id = new.work_session_id
    and ws.company_id = new.company_id
    and ws.employee_profile_id = new.employee_profile_id;

  if not found then
    raise exception 'location_observation_session_not_found'
      using errcode = '23503';
  end if;

  if v_location_context <> 'external_worksite' then
    raise exception 'location_observation_requires_external_worksite'
      using errcode = '23514';
  end if;

  if v_lifecycle_status <> 'active' then
    raise exception 'location_observation_requires_active_session'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger location_observations_validate_session
  before insert or update on public.location_observations
  for each row execute function private.validate_location_observation_session();

create or replace function private.prevent_admin_audit_event_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'admin_audit_events_append_only'
    using errcode = '23514';
end;
$$;

create trigger admin_audit_events_append_only
  before update or delete on public.admin_audit_events
  for each row execute function private.prevent_admin_audit_event_mutation();

create or replace function public.check_in(
  p_location_context text,
  p_site_description text,
  p_device_observed_at timestamptz,
  p_idempotency_key text,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_provider text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_company_id uuid;
  v_company_status text;
  v_request_hash text;
  v_session public.work_sessions%rowtype;
  v_event_id uuid;
  v_now timestamptz := statement_timestamp();
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 or length(btrim(p_idempotency_key)) > 160 then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;

  if p_location_context is null or p_location_context not in ('factory', 'external_worksite') then
    raise exception 'invalid_location_context' using errcode = '22023';
  end if;

  select up.id, up.company_id, c.status
    into v_profile_id, v_company_id, v_company_status
  from public.user_profiles as up
  join public.role_assignments as ra
    on ra.user_profile_id = up.id
   and ra.company_id = up.company_id
  join public.companies as c
    on c.id = up.company_id
  where up.auth_user_id = auth.uid()
    and up.status = 'active'
    and ra.role = 'employee'
    and ra.status = 'active'
  limit 1;

  if v_profile_id is null then
    raise exception 'employee_role_required' using errcode = '42501';
  end if;

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'incomplete_location_coordinates' using errcode = '22023';
  end if;

  if p_latitude is not null and (p_latitude < -90 or p_latitude > 90) then
    raise exception 'invalid_latitude' using errcode = '22023';
  end if;

  if p_longitude is not null and (p_longitude < -180 or p_longitude > 180) then
    raise exception 'invalid_longitude' using errcode = '22023';
  end if;

  if p_accuracy_meters is not null and p_accuracy_meters < 0 then
    raise exception 'invalid_accuracy_meters' using errcode = '22023';
  end if;

  if p_location_context = 'factory'
    and (p_latitude is not null or p_longitude is not null or p_accuracy_meters is not null or p_provider is not null) then
    raise exception 'factory_location_not_allowed' using errcode = '22023';
  end if;

  if p_location_context = 'external_worksite' and p_latitude is null then
    raise exception 'external_worksite_location_required_pending_policy'
      using errcode = 'P0001';
  end if;

  v_request_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'location_context', p_location_context,
          'site_description', nullif(btrim(p_site_description), ''),
          'device_observed_at', p_device_observed_at,
          'latitude', p_latitude,
          'longitude', p_longitude,
          'accuracy_meters', p_accuracy_meters,
          'provider', p_provider
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select *
    into v_session
  from public.work_sessions as ws
  where ws.employee_profile_id = v_profile_id
    and ws.check_in_idempotency_key = btrim(p_idempotency_key)
  limit 1;

  if found then
    if v_session.check_in_request_hash <> v_request_hash then
      raise exception 'idempotency_key_conflict' using errcode = '23505';
    end if;

    return jsonb_build_object(
      'status', 'idempotent_replay',
      'session_id', v_session.id,
      'lifecycle_status', v_session.lifecycle_status,
      'location_context', v_session.location_context,
      'started_at', v_session.started_at,
      'ended_at', v_session.ended_at
    );
  end if;

  if v_company_status <> 'active' then
    raise exception 'company_not_active' using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from public.work_sessions as ws
    where ws.employee_profile_id = v_profile_id
      and ws.lifecycle_status = 'active'
  ) then
    raise exception 'active_session_exists' using errcode = '23505';
  end if;

  insert into public.work_sessions (
    employee_profile_id,
    company_id,
    location_context,
    site_description,
    lifecycle_status,
    review_status,
    current_monitoring_status,
    started_at,
    check_in_device_observed_at,
    check_in_idempotency_key,
    check_in_request_hash
  )
  values (
    v_profile_id,
    v_company_id,
    p_location_context,
    nullif(btrim(p_site_description), ''),
    'active',
    'normal',
    case
      when p_location_context = 'factory' then 'not_applicable'
      else 'unavailable'
    end,
    v_now,
    p_device_observed_at,
    btrim(p_idempotency_key),
    v_request_hash
  )
  returning * into v_session;

  insert into public.session_events (
    work_session_id,
    employee_profile_id,
    company_id,
    event_type,
    source,
    actor_profile_id,
    device_observed_at,
    server_accepted_at,
    reason_code,
    idempotency_key
  )
  values (
    v_session.id,
    v_profile_id,
    v_company_id,
    'check_in',
    'employee_app',
    v_profile_id,
    p_device_observed_at,
    v_now,
    'manual_check_in',
    btrim(p_idempotency_key)
  )
  returning id into v_event_id;

  if p_location_context = 'external_worksite' then
    insert into public.location_observations (
      work_session_id,
      session_event_id,
      employee_profile_id,
      company_id,
      observation_type,
      latitude,
      longitude,
      accuracy_meters,
      provider,
      device_observed_at,
      server_received_at
    )
    values (
      v_session.id,
      v_event_id,
      v_profile_id,
      v_company_id,
      'check_in_location',
      p_latitude,
      p_longitude,
      p_accuracy_meters,
      p_provider,
      p_device_observed_at,
      v_now
    );
  end if;

  return jsonb_build_object(
    'status', 'created',
    'session_id', v_session.id,
    'lifecycle_status', v_session.lifecycle_status,
    'location_context', v_session.location_context,
    'started_at', v_session.started_at,
    'ended_at', v_session.ended_at
  );
exception
  when unique_violation then
    select *
      into v_session
    from public.work_sessions as ws
    where ws.employee_profile_id = v_profile_id
      and ws.check_in_idempotency_key = btrim(p_idempotency_key)
    limit 1;

    if found then
      if v_session.check_in_request_hash <> v_request_hash then
        raise exception 'idempotency_key_conflict' using errcode = '23505';
      end if;

      return jsonb_build_object(
        'status', 'idempotent_replay',
        'session_id', v_session.id,
        'lifecycle_status', v_session.lifecycle_status,
        'location_context', v_session.location_context,
        'started_at', v_session.started_at,
        'ended_at', v_session.ended_at
      );
    end if;

    raise exception 'active_session_exists' using errcode = '23505';
end;
$$;

create or replace function public.check_out(
  p_work_session_id uuid,
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_provider text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_company_id uuid;
  v_request_hash text;
  v_session public.work_sessions%rowtype;
  v_event_id uuid;
  v_now timestamptz := statement_timestamp();
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if p_work_session_id is null then
    raise exception 'work_session_id_required' using errcode = '22023';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 or length(btrim(p_idempotency_key)) > 160 then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;

  select up.id, up.company_id
    into v_profile_id, v_company_id
  from public.user_profiles as up
  join public.role_assignments as ra
    on ra.user_profile_id = up.id
   and ra.company_id = up.company_id
  where up.auth_user_id = auth.uid()
    and up.status = 'active'
    and ra.role = 'employee'
    and ra.status = 'active'
  limit 1;

  if v_profile_id is null then
    raise exception 'employee_role_required' using errcode = '42501';
  end if;

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'incomplete_location_coordinates' using errcode = '22023';
  end if;

  if p_latitude is not null and (p_latitude < -90 or p_latitude > 90) then
    raise exception 'invalid_latitude' using errcode = '22023';
  end if;

  if p_longitude is not null and (p_longitude < -180 or p_longitude > 180) then
    raise exception 'invalid_longitude' using errcode = '22023';
  end if;

  if p_accuracy_meters is not null and p_accuracy_meters < 0 then
    raise exception 'invalid_accuracy_meters' using errcode = '22023';
  end if;

  v_request_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'work_session_id', p_work_session_id,
          'device_observed_at', p_device_observed_at,
          'latitude', p_latitude,
          'longitude', p_longitude,
          'accuracy_meters', p_accuracy_meters,
          'provider', p_provider
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select *
    into v_session
  from public.work_sessions as ws
  where ws.employee_profile_id = v_profile_id
    and ws.check_out_idempotency_key = btrim(p_idempotency_key)
  limit 1;

  if found then
    if v_session.id <> p_work_session_id or v_session.check_out_request_hash <> v_request_hash then
      raise exception 'idempotency_key_conflict' using errcode = '23505';
    end if;

    return jsonb_build_object(
      'status', 'idempotent_replay',
      'session_id', v_session.id,
      'lifecycle_status', v_session.lifecycle_status,
      'location_context', v_session.location_context,
      'started_at', v_session.started_at,
      'ended_at', v_session.ended_at
    );
  end if;

  select *
    into v_session
  from public.work_sessions as ws
  where ws.id = p_work_session_id
    and ws.employee_profile_id = v_profile_id
  for update;

  if not found then
    raise exception 'active_session_not_found_for_employee' using errcode = '42501';
  end if;

  if v_session.lifecycle_status <> 'active' then
    if v_session.check_out_idempotency_key = btrim(p_idempotency_key)
      and v_session.check_out_request_hash = v_request_hash then
      return jsonb_build_object(
        'status', 'idempotent_replay',
        'session_id', v_session.id,
        'lifecycle_status', v_session.lifecycle_status,
        'location_context', v_session.location_context,
        'started_at', v_session.started_at,
        'ended_at', v_session.ended_at
      );
    end if;

    if v_session.check_out_idempotency_key = btrim(p_idempotency_key) then
      raise exception 'idempotency_key_conflict' using errcode = '23505';
    end if;

    raise exception 'session_not_active' using errcode = 'P0001';
  end if;

  if v_session.location_context = 'factory'
    and (p_latitude is not null or p_longitude is not null or p_accuracy_meters is not null or p_provider is not null) then
    raise exception 'factory_location_not_allowed' using errcode = '22023';
  end if;

  insert into public.session_events (
    work_session_id,
    employee_profile_id,
    company_id,
    event_type,
    source,
    actor_profile_id,
    device_observed_at,
    server_accepted_at,
    reason_code,
    idempotency_key
  )
  values (
    v_session.id,
    v_profile_id,
    v_company_id,
    'manual_checkout',
    'employee_app',
    v_profile_id,
    p_device_observed_at,
    v_now,
    'manual_checkout',
    btrim(p_idempotency_key)
  )
  returning id into v_event_id;

  if v_session.location_context = 'external_worksite' and p_latitude is not null then
    insert into public.location_observations (
      work_session_id,
      session_event_id,
      employee_profile_id,
      company_id,
      observation_type,
      latitude,
      longitude,
      accuracy_meters,
      provider,
      device_observed_at,
      server_received_at
    )
    values (
      v_session.id,
      v_event_id,
      v_profile_id,
      v_company_id,
      'checkout_location',
      p_latitude,
      p_longitude,
      p_accuracy_meters,
      p_provider,
      p_device_observed_at,
      v_now
    );
  end if;

  update public.work_sessions
     set lifecycle_status = 'closed_manual',
         current_monitoring_status = 'stopped',
         ended_at = v_now,
         checkout_source = 'manual',
         checkout_reason_code = 'manual_checkout',
         check_out_device_observed_at = p_device_observed_at,
         check_out_idempotency_key = btrim(p_idempotency_key),
         check_out_request_hash = v_request_hash
   where id = v_session.id
   returning * into v_session;

  return jsonb_build_object(
    'status', 'closed',
    'session_id', v_session.id,
    'lifecycle_status', v_session.lifecycle_status,
    'location_context', v_session.location_context,
    'started_at', v_session.started_at,
    'ended_at', v_session.ended_at
  );
exception
  when unique_violation then
    select *
      into v_session
    from public.work_sessions as ws
    where ws.id = p_work_session_id
      and ws.employee_profile_id = v_profile_id
      and ws.check_out_idempotency_key = btrim(p_idempotency_key)
    limit 1;

    if found then
      if v_session.id <> p_work_session_id or v_session.check_out_request_hash <> v_request_hash then
        raise exception 'idempotency_key_conflict' using errcode = '23505';
      end if;

      return jsonb_build_object(
        'status', 'idempotent_replay',
        'session_id', v_session.id,
        'lifecycle_status', v_session.lifecycle_status,
        'location_context', v_session.location_context,
        'started_at', v_session.started_at,
        'ended_at', v_session.ended_at
      );
    end if;

    raise;
end;
$$;

create or replace function public.revoke_role_assignment(p_role_assignment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_profile_id uuid;
  v_admin_company_id uuid;
  v_assignment public.role_assignments%rowtype;
  v_now timestamptz := statement_timestamp();
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if p_role_assignment_id is null then
    raise exception 'role_assignment_id_required' using errcode = '22023';
  end if;

  select up.id, up.company_id
    into v_admin_profile_id, v_admin_company_id
  from public.user_profiles as up
  join public.role_assignments as ra
    on ra.user_profile_id = up.id
   and ra.company_id = up.company_id
  where up.auth_user_id = auth.uid()
    and up.status = 'active'
    and ra.role = 'administrator'
    and ra.status = 'active'
  limit 1;

  if v_admin_profile_id is null then
    raise exception 'administrator_role_required' using errcode = '42501';
  end if;

  select *
    into v_assignment
  from public.role_assignments as ra
  where ra.id = p_role_assignment_id
    and ra.company_id = v_admin_company_id
  for update;

  if not found then
    raise exception 'role_assignment_not_found' using errcode = '42501';
  end if;

  if v_assignment.status = 'revoked' then
    return jsonb_build_object(
      'status', 'already_revoked',
      'role_assignment_id', v_assignment.id,
      'role', v_assignment.role
    );
  end if;

  update public.role_assignments
     set status = 'revoked',
         revoked_at = v_now
   where id = v_assignment.id
   returning * into v_assignment;

  insert into public.admin_audit_events (
    company_id,
    actor_profile_id,
    action,
    target_profile_id,
    target_role_assignment_id,
    server_recorded_at,
    action_details
  )
  values (
    v_admin_company_id,
    v_admin_profile_id,
    'role_assignment_revoked',
    v_assignment.user_profile_id,
    v_assignment.id,
    v_now,
    jsonb_build_object('role', v_assignment.role)
  );

  return jsonb_build_object(
    'status', 'revoked',
    'role_assignment_id', v_assignment.id,
    'role', v_assignment.role
  );
end;
$$;

create or replace function public.disable_user_profile(p_user_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin_profile_id uuid;
  v_admin_company_id uuid;
  v_profile public.user_profiles%rowtype;
  v_previous_status text;
  v_now timestamptz := statement_timestamp();
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if p_user_profile_id is null then
    raise exception 'user_profile_id_required' using errcode = '22023';
  end if;

  select up.id, up.company_id
    into v_admin_profile_id, v_admin_company_id
  from public.user_profiles as up
  join public.role_assignments as ra
    on ra.user_profile_id = up.id
   and ra.company_id = up.company_id
  where up.auth_user_id = auth.uid()
    and up.status = 'active'
    and ra.role = 'administrator'
    and ra.status = 'active'
  limit 1;

  if v_admin_profile_id is null then
    raise exception 'administrator_role_required' using errcode = '42501';
  end if;

  select *
    into v_profile
  from public.user_profiles as up
  where up.id = p_user_profile_id
    and up.company_id = v_admin_company_id
  for update;

  if not found then
    raise exception 'user_profile_not_found' using errcode = '42501';
  end if;

  if v_profile.status = 'disabled' then
    return jsonb_build_object(
      'status', 'already_disabled',
      'user_profile_id', v_profile.id
    );
  end if;

  v_previous_status := v_profile.status;

  update public.user_profiles
     set status = 'disabled'
   where id = v_profile.id
   returning * into v_profile;

  insert into public.admin_audit_events (
    company_id,
    actor_profile_id,
    action,
    target_profile_id,
    server_recorded_at,
    action_details
  )
  values (
    v_admin_company_id,
    v_admin_profile_id,
    'user_profile_disabled',
    v_profile.id,
    v_now,
    jsonb_build_object('previous_status', v_previous_status)
  );

  return jsonb_build_object(
    'status', 'disabled',
    'user_profile_id', v_profile.id
  );
end;
$$;

alter table public.companies enable row level security;
alter table public.user_profiles enable row level security;
alter table public.role_assignments enable row level security;
alter table public.work_sessions enable row level security;
alter table public.session_events enable row level security;
alter table public.location_observations enable row level security;
alter table public.admin_audit_events enable row level security;

create policy companies_select_own_company_or_admin
  on public.companies
  for select
  to authenticated
  using (
    auth.uid() is not null
    and id = private.current_company_id()
    and (
      private.current_user_has_role('employee')
      or private.current_user_is_company_admin(id)
    )
  );

create policy user_profiles_select_self_or_company_admin
  on public.user_profiles
  for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      (
        auth_user_id = auth.uid()
        and status = 'active'
        and (
          private.current_user_has_role('employee')
          or private.current_user_is_company_admin(company_id)
        )
      )
      or private.current_user_is_company_admin(company_id)
    )
  );

create policy role_assignments_select_self_or_company_admin
  on public.role_assignments
  for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      (
        user_profile_id = private.current_profile_id()
        and (
          private.current_user_has_role('employee')
          or private.current_user_is_company_admin(company_id)
        )
      )
      or private.current_user_is_company_admin(company_id)
    )
  );

create policy work_sessions_select_self_or_company_admin
  on public.work_sessions
  for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      private.current_user_can_read_own_attendance(employee_profile_id)
      or private.current_user_is_company_admin(company_id)
    )
  );

create policy session_events_select_self_or_company_admin
  on public.session_events
  for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      private.current_user_can_read_own_attendance(employee_profile_id)
      or private.current_user_is_company_admin(company_id)
    )
  );

create policy location_observations_select_self_or_company_admin
  on public.location_observations
  for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      private.current_user_can_read_own_attendance(employee_profile_id)
      or private.current_user_is_company_admin(company_id)
    )
  );

create policy admin_audit_events_select_company_admin
  on public.admin_audit_events
  for select
  to authenticated
  using (
    auth.uid() is not null
    and private.current_user_is_company_admin(company_id)
  );

revoke all on table public.companies from anon, authenticated;
revoke all on table public.user_profiles from anon, authenticated;
revoke all on table public.role_assignments from anon, authenticated;
revoke all on table public.work_sessions from anon, authenticated;
revoke all on table public.session_events from anon, authenticated;
revoke all on table public.location_observations from anon, authenticated;
revoke all on table public.admin_audit_events from anon, authenticated;

grant select on table public.companies to authenticated;
grant select on table public.user_profiles to authenticated;
grant select on table public.role_assignments to authenticated;
grant select on table public.work_sessions to authenticated;
grant select on table public.session_events to authenticated;
grant select on table public.location_observations to authenticated;
grant select on table public.admin_audit_events to authenticated;

grant usage on schema private to authenticated;

revoke execute on function private.set_updated_at() from public, anon, authenticated;
revoke execute on function private.validate_location_observation_session() from public, anon, authenticated;
revoke execute on function private.current_profile_id() from public, anon;
revoke execute on function private.current_company_id() from public, anon;
revoke execute on function private.current_user_has_role(text) from public, anon;
revoke execute on function private.current_user_is_company_admin(uuid) from public, anon;
revoke execute on function private.current_user_can_read_own_attendance(uuid) from public, anon;
revoke execute on function private.prevent_last_admin_role_loss() from public, anon, authenticated;
revoke execute on function private.prevent_last_admin_profile_disable() from public, anon, authenticated;
revoke execute on function private.prevent_admin_audit_event_mutation() from public, anon, authenticated;

grant execute on function private.current_profile_id() to authenticated;
grant execute on function private.current_company_id() to authenticated;
grant execute on function private.current_user_has_role(text) to authenticated;
grant execute on function private.current_user_is_company_admin(uuid) to authenticated;
grant execute on function private.current_user_can_read_own_attendance(uuid) to authenticated;

revoke execute on function public.check_in(text, text, timestamptz, text, numeric, numeric, numeric, text)
  from public, anon;
revoke execute on function public.check_out(uuid, text, timestamptz, numeric, numeric, numeric, text)
  from public, anon;
revoke execute on function public.revoke_role_assignment(uuid)
  from public, anon;
revoke execute on function public.disable_user_profile(uuid)
  from public, anon;

grant execute on function public.check_in(text, text, timestamptz, text, numeric, numeric, numeric, text)
  to authenticated;
grant execute on function public.check_out(uuid, text, timestamptz, numeric, numeric, numeric, text)
  to authenticated;
grant execute on function public.revoke_role_assignment(uuid)
  to authenticated;
grant execute on function public.disable_user_profile(uuid)
  to authenticated;
