-- M2.3b.1: additive foundations for the revised attendance location model.
-- No coordinates are seeded, and the existing attendance RPCs stay unchanged.

alter table public.companies
  add column factory_latitude numeric(9,6) null,
  add column factory_longitude numeric(9,6) null,
  add column factory_radius_meters integer null,
  add constraint companies_factory_latitude_range_check
    check (factory_latitude is null or factory_latitude between -90 and 90),
  add constraint companies_factory_longitude_range_check
    check (factory_longitude is null or factory_longitude between -180 and 180),
  add constraint companies_factory_radius_positive_check
    check (factory_radius_meters is null or factory_radius_meters > 0),
  add constraint companies_factory_configuration_complete_check
    check (
      (factory_latitude is null and factory_longitude is null and factory_radius_meters is null)
      or
      (factory_latitude is not null and factory_longitude is not null and factory_radius_meters is not null)
    );

alter table public.work_sessions
  drop constraint work_sessions_location_context_check,
  add constraint work_sessions_location_context_check
    check (location_context in ('factory', 'external_worksite', 'location_unverified')),
  add column employee_note text null,
  add constraint work_sessions_employee_note_length_check
    check (employee_note is null or length(employee_note) <= 1000);

-- Retain checkout_reason_code until historical closure reasons/events have
-- been audited. No note-writing RPC or new client write grant is added here.

create or replace function private.validate_location_observation_session()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_lifecycle_status text;
begin
  select ws.lifecycle_status
    into v_lifecycle_status
  from public.work_sessions as ws
  where ws.id = new.work_session_id
    and ws.company_id = new.company_id
    and ws.employee_profile_id = new.employee_profile_id;

  if not found then
    raise exception 'location_observation_session_not_found'
      using errcode = '23503';
  end if;

  -- Foreground evidence may belong to any supported location context.
  -- Checkout evidence must still be written before closing the session.
  if v_lifecycle_status <> 'active' then
    raise exception 'location_observation_requires_active_session'
      using errcode = '23514';
  end if;

  return new;
end;
$$;
