-- Forward-only extension of settled notes. Never activates the deployment.
-- Keep one employee/key namespace so a legacy key cannot become a v2 write.
alter table private.employee_note_operations
  add column protocol_version integer not null default 1,
  add column deployment_epoch uuid,
  add constraint employee_note_operation_protocol check (
    (protocol_version = 1 and deployment_epoch is null) or
    (protocol_version = 2 and deployment_epoch is not null)
  );

create function public.save_employee_note_v2(
  p_work_session_id uuid,
  p_operation_key text,
  p_note_action text,
  p_employee_note text,
  p_replay_only boolean default false
)
returns jsonb language plpgsql volatile security definer
set search_path = '' set timezone = 'UTC' as $$
declare
  v_state private.attendance_deployment%rowtype;
  v_profile public.user_profiles%rowtype;
  v_old private.employee_note_operations%rowtype;
  v_receipt jsonb;
begin
  -- Lock order remains deployment -> profile -> role -> company -> session.
  -- Both epoch validation and the gate are checked in the writing transaction.
  perform private.require_attendance_epoch();
  v_state := private.locked_attendance_deployment();
  if v_state.write_contract is distinct from 2 then
    raise exception 'standalone_notes_not_enabled' using errcode = 'P0001';
  end if;
  v_profile := private.attendance_employee();
  select * into v_old from private.employee_note_operations
    where employee_profile_id=v_profile.id and operation_key=p_operation_key;
  if found and (v_old.protocol_version <> 2 or
      v_old.deployment_epoch is distinct from v_state.deployment_epoch) then
    raise exception 'note_operation_conflict' using errcode = '23505';
  end if;
  -- Reuse exact validation, fingerprint, session lock, mutation/fence and atomic
  -- terminal evidence. The profile lock prevents a competing key admission.
  v_receipt := private.save_employee_note_legacy_impl(p_work_session_id,
    p_operation_key,p_note_action,p_employee_note,p_replay_only);
  update private.employee_note_operations set protocol_version=2,
    deployment_epoch=v_state.deployment_epoch
    where employee_profile_id=v_profile.id and operation_key=p_operation_key
      and protocol_version=1;
  return v_receipt || jsonb_build_object('note_contract_version',2,
    'deployment_epoch',v_state.deployment_epoch);
end;
$$;

-- Preserve gate-1 behavior for legacy keys, including their original receipts.
-- A later gate rollback must not reinterpret a v2 key as legacy evidence.
create or replace function public.save_employee_note(
  p_work_session_id uuid, p_operation_key text, p_note_action text,
  p_employee_note text, p_replay_only boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' set timezone = 'UTC'
as $$
declare v_profile public.user_profiles%rowtype;
begin
  if private.attendance_write_contract() is distinct from 1 then
    raise exception 'standalone_notes_not_enabled' using errcode = 'P0001';
  end if;
  v_profile := private.attendance_employee();
  if exists (select 1 from private.employee_note_operations
    where employee_profile_id=v_profile.id and operation_key=p_operation_key
      and protocol_version<>1) then
    raise exception 'note_operation_conflict' using errcode = '23505';
  end if;
  return private.save_employee_note_legacy_impl(p_work_session_id,p_operation_key,
    p_note_action,p_employee_note,p_replay_only);
end;
$$;

revoke all on function public.save_employee_note_v2(uuid,text,text,text,boolean) from public, anon;
grant execute on function public.save_employee_note_v2(uuid,text,text,text,boolean) to authenticated;
notify pgrst, 'reload schema';
