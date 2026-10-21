-- C6.3a SERVER CONTRACT ONLY. No hosted deployment, v2 gate or client change.
-- Operation evidence is NOT note edit history: never retain note text here.
-- Do not prune evidence without an approved protocol preventing old-key replay.
create table private.employee_note_operations (
  employee_profile_id uuid not null,
  company_id uuid not null,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  operation_key text not null check (
    char_length(operation_key) between 8 and 160 and operation_key = btrim(operation_key)
  ),
  work_session_id uuid not null,
  request_fingerprint text not null check (request_fingerprint ~ '^[0-9a-f]{64}$'),
  outcome text not null,
  reason text null,
  settled_at timestamptz not null check (isfinite(settled_at)),
  primary key (employee_profile_id, operation_key),
  constraint employee_note_operations_session_owner_fk
    foreign key (work_session_id, company_id, employee_profile_id)
    references public.work_sessions(id, company_id, employee_profile_id) on delete restrict,
  constraint employee_note_operations_terminal_shape check (
    (outcome = 'applied' and reason is null) or
    (outcome = 'not_applied' and reason is not null and
      reason in ('replay_fenced', 'session_closed'))
  )
);

alter table private.employee_note_operations enable row level security;
-- No client policies, table grants or direct metadata lookup, including admins.
revoke all on table private.employee_note_operations from public, anon, authenticated;

create function public.save_employee_note(
  p_work_session_id uuid,
  p_operation_key text,
  p_note_action text,
  p_employee_note text,
  p_replay_only boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' set timezone = 'UTC'
as $$
declare
  v_profile public.user_profiles%rowtype;
  v_session public.work_sessions%rowtype;
  v_operation private.employee_note_operations%rowtype;
  v_fingerprint text;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(174811, 2);
  -- Existing profile FOR UPDATE is the per-employee/key serialization lock.
  -- Order stays: deployment -> profile -> role -> company -> session -> evidence.
  -- Every request, including a replay miss, takes it BEFORE looking for evidence.
  v_profile := private.attendance_employee();
  if p_work_session_id is null then
    raise exception 'work_session_id_required' using errcode = '22023';
  end if;
  if p_operation_key is null or char_length(p_operation_key) not between 8 and 160
    or p_operation_key <> btrim(p_operation_key) then
    raise exception 'invalid_note_operation_key' using errcode = '22023';
  end if;
  if p_replay_only is null or p_note_action is null
    or p_note_action not in ('replace', 'clear')
    or (p_note_action = 'replace' and p_employee_note is null)
    or (p_note_action = 'clear' and p_employee_note is not null) then
    raise exception 'invalid_employee_note_operation' using errcode = '22023';
  end if;
  if char_length(p_employee_note) > 1000 then
    raise exception 'employee_note_too_long' using errcode = '22023';
  end if;
  perform 1 from public.companies where id = v_profile.company_id for share;
  select * into v_session from public.work_sessions where id = p_work_session_id
    and employee_profile_id = v_profile.id and company_id = v_profile.company_id for update;
  if not found then
    -- Same error for absent and foreign sessions; no foreign-key oracle.
    raise exception 'active_session_not_found_for_employee' using errcode = '42501';
  end if;

  -- JSONB framing distinguishes NULL/empty, action, exact Unicode/whitespace,
  -- and owner/session identity. The operational replay flag is not intent.
  v_fingerprint := encode(extensions.digest(convert_to(jsonb_build_object(
    'note_contract_version', 1, 'operation', 'save_employee_note',
    'operation_key', p_operation_key,
    'auth_user_id', v_profile.auth_user_id, 'employee_profile_id', v_profile.id,
    'company_id', v_profile.company_id, 'session_id', p_work_session_id,
    'note_action', p_note_action, 'employee_note', p_employee_note
  )::text, 'UTF8'), 'sha256'), 'hex');

  select * into v_operation from private.employee_note_operations
    where employee_profile_id = v_profile.id and operation_key = p_operation_key;
  if found then
    if v_operation.auth_user_id <> v_profile.auth_user_id
      or v_operation.company_id <> v_profile.company_id
      or v_operation.work_session_id <> p_work_session_id
      or v_operation.request_fingerprint <> v_fingerprint then
      raise exception 'note_operation_conflict' using errcode = '23505';
    end if;
    -- Terminal evidence is immutable via this RPC. Never reapply an old note,
    -- even after later edits, checkout, or a lost original response.
  else
    if p_replay_only then
      v_operation.outcome := 'not_applied';
      v_operation.reason := 'replay_fenced';
    elsif v_session.lifecycle_status <> 'active' then
      v_operation.outcome := 'not_applied';
      v_operation.reason := 'session_closed';
    else
      update public.work_sessions set employee_note = p_employee_note
        where id = v_session.id;
      v_operation.outcome := 'applied';
      v_operation.reason := null;
    end if;
    -- The row lock remains held through commit. Both the mutation and terminal
    -- evidence commit together; a failure anywhere rolls back both.
    insert into private.employee_note_operations (
      employee_profile_id, company_id, auth_user_id, operation_key,
      work_session_id, request_fingerprint, outcome, reason, settled_at
    ) values (
      v_profile.id, v_profile.company_id, v_profile.auth_user_id, p_operation_key,
      p_work_session_id, v_fingerprint, v_operation.outcome, v_operation.reason,
      clock_timestamp()
    ) returning * into v_operation;
  end if;
  return jsonb_build_object(
    'note_contract_version', 1, 'operation_key', v_operation.operation_key,
    'employee_profile_id', v_operation.employee_profile_id,
    'company_id', v_operation.company_id, 'session_id', v_operation.work_session_id,
    'request_fingerprint', v_operation.request_fingerprint,
    'outcome', v_operation.outcome, 'reason', v_operation.reason,
    'settled_at', v_operation.settled_at
  );
end;
$$;

revoke all on function public.save_employee_note(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.save_employee_note(uuid, text, text, text, boolean) to authenticated;

-- Keep update_employee_note(uuid,text), attendance signatures, receipts and the
-- deployment gate unchanged. Retiring/fencing the unkeyed writer is a cutover
-- prerequisite; keyed evidence does not fence unkeyed or privileged edits.
notify pgrst, 'reload schema';
