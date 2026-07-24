-- Workspace-scoped manual payment methods.
--
-- A workspace owner stores destination details once. Events reference the
-- selected method, while payment submissions snapshot its details so later
-- edits cannot change what a participant actually paid to.

-- --------------------------------------------------------------------------
-- Normalization helpers. These intentionally return null for malformed input;
-- the table trigger turns that into a useful validation error for every write
-- path (RPC and direct SQL alike).
-- --------------------------------------------------------------------------
create or replace function public.normalize_sa_mobile(p_value text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_compact text;
begin
  if p_value is null or length(trim(p_value)) = 0 then
    return null;
  end if;

  v_compact := regexp_replace(
    translate(
      trim(p_value),
      '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
      '01234567890123456789'
    ),
    '[[:space:]().-]', '', 'g'
  );

  -- Exact accepted forms; a misplaced/duplicate plus or any letter is invalid.
  if v_compact ~ '^05[0-9]{8}$' then
    return '+966' || substring(v_compact from 2);
  elsif v_compact ~ '^5[0-9]{8}$' then
    return '+966' || v_compact;
  elsif v_compact ~ '^009665[0-9]{8}$' then
    return '+' || substring(v_compact from 3);
  elsif v_compact ~ '^9665[0-9]{8}$' then
    return '+' || v_compact;
  elsif v_compact ~ '^\+9665[0-9]{8}$' then
    return v_compact;
  end if;

  return null;
end;
$$;

create or replace function public.normalize_sa_iban(p_value text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_value is null or length(trim(p_value)) = 0 then null
    else upper(regexp_replace(
      translate(
        trim(p_value),
        '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
        '01234567890123456789'
      ),
      '[[:space:]-]', '', 'g'
    ))
  end;
$$;

create or replace function public.is_valid_sa_iban(p_value text)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  v_iban text := public.normalize_sa_iban(p_value);
  v_numeric text;
begin
  if v_iban is null or v_iban !~ '^SA[0-9]{22}$' then
    return false;
  end if;

  -- ISO 13616 MOD-97: move SA + check digits to the end; S=28, A=10.
  v_numeric := substring(v_iban from 5) || '2810' || substring(v_iban from 3 for 2);
  return (v_numeric::numeric % 97) = 1;
exception
  when numeric_value_out_of_range or invalid_text_representation then
    return false;
end;
$$;

revoke execute on function public.normalize_sa_mobile(text) from public, anon, authenticated;
revoke execute on function public.normalize_sa_iban(text) from public, anon, authenticated;
revoke execute on function public.is_valid_sa_iban(text) from public, anon, authenticated;
grant execute on function public.is_valid_sa_iban(text) to authenticated;

-- --------------------------------------------------------------------------
-- Saved destinations are immutable versions. Editing a provider creates a new
-- row, so an older event can never silently start pointing at new bank details.
-- Sensitive details are owner-readable only; members receive the destination
-- of an event through a guarded RPC below.
-- --------------------------------------------------------------------------
create table public.workspace_payment_methods (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  provider text not null check (
    provider in ('cash', 'stc_bank', 'barq', 'al_rajhi', 'snb', 'alinma', 'riyad')
  ),
  mobile_number text,
  iban text,
  account_number text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (mobile_number is null or mobile_number ~ '^\+9665[0-9]{8}$'),
  check (iban is null or public.is_valid_sa_iban(iban)),
  check (account_number is null or account_number ~ '^[0-9]{6,24}$'),
  check (
    (provider in ('stc_bank', 'barq')
      and mobile_number is not null and iban is null and account_number is null)
    or
    (provider in ('al_rajhi', 'snb', 'alinma', 'riyad')
      and mobile_number is null and iban is not null)
    or
    (provider = 'cash'
      and mobile_number is null and iban is null and account_number is null)
  )
);

create index idx_workspace_payment_methods_workspace_id
  on public.workspace_payment_methods(workspace_id);

create unique index uq_workspace_payment_method_version
  on public.workspace_payment_methods (
    workspace_id,
    provider,
    coalesce(mobile_number, ''),
    coalesce(iban, ''),
    coalesce(account_number, '')
  );

create or replace function public.normalize_workspace_payment_method()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raw_mobile text := nullif(trim(new.mobile_number), '');
  v_raw_iban text := nullif(trim(new.iban), '');
  v_raw_account text := nullif(trim(new.account_number), '');
begin
  new.provider := lower(trim(new.provider));
  if new.provider is null
    or new.provider not in ('cash', 'stc_bank', 'barq', 'al_rajhi', 'snb', 'alinma', 'riyad') then
    raise exception 'Unsupported payment provider';
  end if;
  if tg_op = 'UPDATE' then
    raise exception 'Payment method records are immutable; create a new version instead';
  end if;

  new.mobile_number := public.normalize_sa_mobile(v_raw_mobile);
  new.iban := public.normalize_sa_iban(v_raw_iban);
  new.account_number := case
    when v_raw_account is null then null
    else regexp_replace(
      translate(
        v_raw_account,
        '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
        '01234567890123456789'
      ),
      '[[:space:]-]', '', 'g'
    )
  end;

  if new.provider in ('stc_bank', 'barq') then
    if new.mobile_number is null then
      raise exception 'A valid Saudi mobile number is required';
    end if;
    if v_raw_iban is not null or v_raw_account is not null then
      raise exception 'Mobile wallet methods only accept a mobile number';
    end if;
    new.iban := null;
    new.account_number := null;
  elsif new.provider in ('al_rajhi', 'snb', 'alinma', 'riyad') then
    if not public.is_valid_sa_iban(new.iban) then
      raise exception 'A valid Saudi IBAN is required';
    end if;
    if new.account_number is not null and new.account_number !~ '^[0-9]{6,24}$' then
      raise exception 'Account number must contain 6 to 24 digits';
    end if;
    if v_raw_mobile is not null then
      raise exception 'Bank methods do not accept a mobile number';
    end if;
    new.mobile_number := null;
  else
    if v_raw_mobile is not null or v_raw_iban is not null or v_raw_account is not null then
      raise exception 'Cash does not accept destination details';
    end if;
    new.mobile_number := null;
    new.iban := null;
    new.account_number := null;
  end if;

  new.created_at := now();
  new.updated_at := new.created_at;
  return new;
end;
$$;

create trigger trg_normalize_workspace_payment_method
before insert or update on public.workspace_payment_methods
for each row execute function public.normalize_workspace_payment_method();

revoke execute on function public.normalize_workspace_payment_method() from public, anon, authenticated;

alter table public.workspace_payment_methods enable row level security;

create policy "Owners can select workspace payment methods"
  on public.workspace_payment_methods for select
  using (exists (
    select 1 from public.workspaces w
    where w.id = workspace_id and w.owner_id = auth.uid()
  ));

create policy "Owners can insert workspace payment methods"
  on public.workspace_payment_methods for insert
  with check (exists (
    select 1 from public.workspaces w
    where w.id = workspace_id and w.owner_id = auth.uid()
  ));

revoke all on table public.workspace_payment_methods from anon;
grant select, insert on table public.workspace_payment_methods to authenticated;

-- --------------------------------------------------------------------------
-- Event/template selection and immutable participant-side snapshots.
-- --------------------------------------------------------------------------
alter table public.events
  add column payment_method_id uuid
    references public.workspace_payment_methods(id) on delete set null,
  add column payment_method_ids uuid[] not null default '{}'::uuid[];

alter table public.event_templates
  add column payment_method_id uuid
    references public.workspace_payment_methods(id) on delete set null,
  add column payment_method_ids uuid[] not null default '{}'::uuid[];

create index idx_events_payment_method_id on public.events(payment_method_id);
create index idx_event_templates_payment_method_id on public.event_templates(payment_method_id);
create index idx_events_payment_method_ids on public.events using gin(payment_method_ids);
create index idx_event_templates_payment_method_ids on public.event_templates using gin(payment_method_ids);

alter table public.event_participants
  add column payment_method_id uuid
    references public.workspace_payment_methods(id) on delete set null,
  add column payment_provider text,
  add column paid_to_iban text,
  add column paid_to_account_number text,
  add column paid_price_per_person decimal(10,2),
  add column payment_group_size int,
  add constraint event_participants_payment_provider_check check (
    payment_provider is null
    or payment_provider in ('cash', 'stc_bank', 'barq', 'al_rajhi', 'snb', 'alinma', 'riyad')
  ),
  add constraint event_participants_payment_group_size_check check (
    payment_group_size is null or payment_group_size > 0
  );

create index idx_event_participants_payment_method_id
  on public.event_participants(payment_method_id)
  where payment_method_id is not null;

-- Enforce that a selected method belongs to the event's workspace even for
-- direct table writes outside create_event.
create or replace function public.validate_event_payment_method_workspace()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_method_ids uuid[];
  v_distinct_count int;
begin
  -- A scalar-only update comes from an older client and intentionally replaces
  -- the selection with one method. Otherwise the array is authoritative and
  -- the scalar mirrors its first entry for read compatibility.
  if tg_op = 'UPDATE'
    and new.payment_method_id is distinct from old.payment_method_id
    and new.payment_method_ids is not distinct from old.payment_method_ids then
    v_method_ids := case
      when new.payment_method_id is null then '{}'::uuid[]
      else array[new.payment_method_id]
    end;
  else
    v_method_ids := coalesce(new.payment_method_ids, '{}'::uuid[]);
    if cardinality(v_method_ids) = 0 and new.payment_method_id is not null then
      v_method_ids := array[new.payment_method_id];
    end if;
  end if;

  select count(distinct selected_id)
  into v_distinct_count
  from unnest(v_method_ids) as selected(selected_id);

  if v_distinct_count <> cardinality(v_method_ids) then
    raise exception 'Payment methods must be non-null and unique';
  end if;

  if exists (
    select 1
    from unnest(v_method_ids) as selected(selected_id)
    left join public.workspace_payment_methods pm
      on pm.id = selected.selected_id
     and pm.workspace_id = new.workspace_id
    where pm.id is null
  ) then
    raise exception 'Every payment method must belong to the event workspace';
  end if;

  new.payment_method_ids := v_method_ids;
  new.payment_method_id := v_method_ids[1];
  return new;
end;
$$;

create trigger trg_validate_event_payment_method_workspace
before insert or update of workspace_id, payment_method_id, payment_method_ids on public.events
for each row execute function public.validate_event_payment_method_workspace();

create trigger trg_validate_template_payment_method_workspace
before insert or update of workspace_id, payment_method_id, payment_method_ids on public.event_templates
for each row execute function public.validate_event_payment_method_workspace();

revoke execute on function public.validate_event_payment_method_workspace() from public, anon, authenticated;

-- The server owns price_per_person. The client supplies venue total and player
-- count only; both events and recurring templates follow the same calculation.
create or replace function public.calculate_price_per_person()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.total_price is not null and new.total_price < 0 then
    raise exception 'Total price cannot be negative';
  end if;
  if new.max_participants is not null and new.max_participants <= 0 then
    raise exception 'Player count must be greater than zero';
  end if;
  new.total_price := coalesce(new.total_price, 0);
  new.price_per_person := case
    when new.total_price > 0 and new.max_participants is not null
      then round(new.total_price::numeric / new.max_participants::numeric, 2)
    else 0
  end;
  return new;
end;
$$;

create trigger trg_calculate_event_price_per_person
before insert or update of total_price, max_participants, price_per_person on public.events
for each row execute function public.calculate_price_per_person();

create trigger trg_calculate_template_price_per_person
before insert or update of total_price, max_participants, price_per_person on public.event_templates
for each row execute function public.calculate_price_per_person();

revoke execute on function public.calculate_price_per_person() from public, anon, authenticated;

-- Recalculate all existing rows once. The triggers perform the calculation.
update public.events
set total_price = greatest(coalesce(total_price, 0), 0),
    max_participants = case when max_participants is not null and max_participants <= 0 then null else max_participants end;

update public.event_templates
set total_price = greatest(coalesce(total_price, 0), 0),
    max_participants = case when max_participants is not null and max_participants <= 0 then null else max_participants end;

-- --------------------------------------------------------------------------
-- Backfill the legacy creator-level STC Pay number into each owned workspace,
-- then attach it to existing paid events/templates and participant snapshots.
-- Invalid legacy numbers are preserved on users but are not promoted.
-- --------------------------------------------------------------------------
insert into public.workspace_payment_methods (workspace_id, provider, mobile_number)
select w.id, 'stc_bank', public.normalize_sa_mobile(u.stc_pay_number)
from public.workspaces w
join public.users u on u.user_id = w.owner_id
where public.normalize_sa_mobile(u.stc_pay_number) is not null
on conflict do nothing;

update public.events e
set payment_method_id = pm.id
from public.workspace_payment_methods pm
where pm.workspace_id = e.workspace_id
  and pm.provider = 'stc_bank'
  and e.total_price > 0
  and e.payment_method_id is null;

update public.event_templates t
set payment_method_id = pm.id
from public.workspace_payment_methods pm
where pm.workspace_id = t.workspace_id
  and pm.provider = 'stc_bank'
  and t.total_price > 0
  and t.payment_method_id is null;

-- Array backfill also covers a database where the scalar version of this
-- migration was tested before the multi-method revision was applied.
update public.events
set payment_method_ids = array[payment_method_id]
where payment_method_id is not null
  and cardinality(payment_method_ids) = 0;

update public.event_templates
set payment_method_ids = array[payment_method_id]
where payment_method_id is not null
  and cardinality(payment_method_ids) = 0;

update public.event_participants ep
set payment_method_id = e.payment_method_id,
    payment_provider = 'stc_bank',
    paid_to_number = coalesce(public.normalize_sa_mobile(ep.paid_to_number), ep.paid_to_number),
    paid_price_per_person = e.price_per_person
from public.events e
where e.id = ep.event_id
  and ep.paid_to_number is not null;

update public.event_participants payer
set payment_group_size = 1 + (
  select count(*)
  from public.event_participants guest
  where guest.event_id = payer.event_id
    and guest.added_by = payer.user_id
)
where payer.user_id is not null
  and payer.payment_provider is not null;

-- --------------------------------------------------------------------------
-- Owner management RPCs.
-- --------------------------------------------------------------------------
create or replace function public.upsert_workspace_payment_method(
  p_workspace_id uuid,
  p_provider text,
  p_mobile_number text default null,
  p_iban text default null,
  p_account_number text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_method public.workspace_payment_methods;
  v_provider text := lower(trim(p_provider));
  v_mobile text := public.normalize_sa_mobile(p_mobile_number);
  v_iban text := public.normalize_sa_iban(p_iban);
  v_account text := case
    when nullif(trim(p_account_number), '') is null then null
    else regexp_replace(
      translate(
        trim(p_account_number),
        '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
        '01234567890123456789'
      ),
      '[[:space:]-]', '', 'g'
    )
  end;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if not exists (
    select 1 from public.workspaces
    where id = p_workspace_id and owner_id = v_uid
  ) then
    raise exception 'Not authorized: only the workspace owner can manage payment methods';
  end if;

  insert into public.workspace_payment_methods
    (workspace_id, provider, mobile_number, iban, account_number)
  values
    (p_workspace_id, p_provider, p_mobile_number, p_iban, p_account_number)
  on conflict do nothing
  returning * into v_method;

  if v_method.id is null then
    select * into v_method
    from public.workspace_payment_methods
    where workspace_id = p_workspace_id
      and provider = v_provider
      and mobile_number is not distinct from v_mobile
      and iban is not distinct from v_iban
      and account_number is not distinct from v_account
    order by created_at desc
    limit 1;
  end if;

  if v_method.id is null then
    raise exception 'Unable to save payment method';
  end if;

  return row_to_json(v_method);
end;
$$;

revoke execute on function public.upsert_workspace_payment_method(uuid, text, text, text, text) from public, anon;
grant execute on function public.upsert_workspace_payment_method(uuid, text, text, text, text) to authenticated;

create or replace function public.get_my_workspace_payment_methods(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if not exists (
    select 1 from public.workspaces
    where id = p_workspace_id and owner_id = v_uid
  ) then
    raise exception 'Not authorized: only the workspace owner can view payment methods';
  end if;

  return (
    select coalesce(json_agg(
      row_to_json(pm)
      order by case pm.provider
        when 'cash' then 0
        when 'stc_bank' then 1
        when 'barq' then 2
        when 'al_rajhi' then 3
        when 'snb' then 4
        when 'alinma' then 5
        when 'riyad' then 6
      end, pm.created_at desc
    ), '[]'::json)
    from public.workspace_payment_methods pm
    where pm.workspace_id = p_workspace_id
  );
end;
$$;

revoke execute on function public.get_my_workspace_payment_methods(uuid) from public, anon;
grant execute on function public.get_my_workspace_payment_methods(uuid) to authenticated;

-- --------------------------------------------------------------------------
-- Member-facing destination. Details are released only for a workspace event;
-- direct reads of the saved workspace record remain owner-only.
-- --------------------------------------------------------------------------
create or replace function public.get_event_payment_destination(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_event public.events;
  v_submission public.event_participants;
  v_method_ids uuid[];
  v_methods jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;

  -- Pending/confirmed joiners review the immutable snapshot they actually
  -- submitted, even if the organizer later changes this event's destination.
  select * into v_submission
  from public.event_participants
  where event_id = p_event_id
    and user_id = auth.uid()
    and payment_provider is not null
  order by created_at desc
  limit 1;

  if v_submission.id is not null then
    return json_build_object(
      'status', 'available',
      'event_id', v_event.id,
      'payment_method_id', v_submission.payment_method_id,
      'provider', v_submission.payment_provider,
      'mobile_number', v_submission.paid_to_number,
      'iban', v_submission.paid_to_iban,
      'account_number', v_submission.paid_to_account_number,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', coalesce(v_submission.paid_price_per_person, v_event.price_per_person),
      'group_size', v_submission.payment_group_size
    );
  end if;

  if v_event.total_price <= 0 then
    return json_build_object(
      'status', 'free',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;

  if cardinality(v_method_ids) = 0 then
    return json_build_object(
      'status', 'payment_method_required',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'payment_method_id', pm.id,
        'provider', pm.provider,
        'mobile_number', pm.mobile_number,
        'iban', pm.iban,
        'account_number', pm.account_number
      )
      order by array_position(v_method_ids, pm.id)
    ),
    '[]'::jsonb
  )
  into v_methods
  from public.workspace_payment_methods pm
  where pm.id = any(v_method_ids)
    and pm.workspace_id = v_event.workspace_id;

  if jsonb_array_length(v_methods) = 0 then
    return json_build_object(
      'status', 'payment_method_required',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  return json_build_object(
    'status', 'available',
    'event_id', v_event.id,
    'payment_method_id', null,
    'provider', null,
    'mobile_number', null,
    'iban', null,
    'account_number', null,
    'payment_methods', v_methods,
    'total_price', v_event.total_price,
    'price_per_person', v_event.price_per_person,
    'group_size', null
  );
end;
$$;

revoke execute on function public.get_event_payment_destination(uuid) from public, anon;
grant execute on function public.get_event_payment_destination(uuid) to authenticated;

-- --------------------------------------------------------------------------
-- Modern submission: the caller is always auth.uid(); no client-supplied user
-- id is trusted. The destination is copied onto every row in the group.
-- --------------------------------------------------------------------------
drop function if exists public.submit_payment_v2(uuid, text[], uuid, decimal);

create or replace function public.submit_payment_v2(
  p_event_id uuid,
  p_guest_names text[] default '{}',
  p_expected_payment_method_id uuid default null,
  p_expected_price_per_person decimal default null,
  p_payment_method_id uuid default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_method public.workspace_payment_methods;
  v_current_seats int;
  v_existing_status text;
  v_guests text[];
  v_group_size int;
  v_method_ids uuid[];
  v_selected_method_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into v_existing_status
  from public.event_participants
  where event_id = p_event_id and user_id = v_uid;
  if v_existing_status is not null then
    return json_build_object(
      'status', 'already_joined',
      'payment_status', v_existing_status
    );
  end if;

  select coalesce(array_agg(trim(g)), '{}')
  into v_guests
  from unnest(coalesce(p_guest_names, '{}'::text[])) as g
  where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

  -- The player reviewed a particular choice and amount. Refuse to create a
  -- row if the organizer removed that choice while the half sheet was open.
  if p_payment_method_id is not null
    and p_expected_payment_method_id is not null
    and p_payment_method_id is distinct from p_expected_payment_method_id then
    return json_build_object('status', 'event_terms_changed');
  end if;
  v_selected_method_id := coalesce(p_payment_method_id, p_expected_payment_method_id);

  if p_expected_price_per_person is not null
    and abs(p_expected_price_per_person - coalesce(v_event.price_per_person, 0)) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  if v_event.max_participants is not null then
    select count(*) into v_current_seats
    from public.event_participants
    where event_id = p_event_id
      and payment_status in ('pending', 'confirmed');
    if v_current_seats + v_group_size > v_event.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  -- Legacy free events remain registerable. They bypass payment entirely but
  -- keep the same atomic seat-count and guest behavior as a paid registration.
  if v_event.total_price <= 0 then
    insert into public.event_participants
      (event_id, user_id, payment_status, paid_price_per_person, payment_group_size)
    values
      (p_event_id, v_uid, 'confirmed', v_event.price_per_person, v_group_size);

    insert into public.event_participants
      (event_id, user_id, guest_name, added_by, payment_status, paid_price_per_person)
    select p_event_id, null, g, v_uid, 'confirmed', v_event.price_per_person
    from unnest(v_guests) as g;

    delete from public.event_waitlist
    where event_id = p_event_id and user_id = v_uid;

    return json_build_object(
      'status', 'submitted',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', v_group_size
    );
  end if;

  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;
  if cardinality(v_method_ids) = 0 then
    return json_build_object('status', 'payment_method_required');
  end if;

  -- A one-method event remains compatible with older clients. Modern clients
  -- always submit the explicit choice made in the half sheet.
  if v_selected_method_id is null and cardinality(v_method_ids) = 1 then
    v_selected_method_id := v_method_ids[1];
  end if;
  if v_selected_method_id is null then
    return json_build_object('status', 'payment_method_required');
  end if;
  if not (v_selected_method_id = any(v_method_ids)) then
    return json_build_object('status', 'event_terms_changed');
  end if;

  select * into v_method
  from public.workspace_payment_methods
  where id = v_selected_method_id
    and workspace_id = v_event.workspace_id
  for share;
  if v_method.id is null then
    return json_build_object('status', 'payment_method_required');
  end if;

  insert into public.event_participants
    (event_id, user_id, payment_status, payment_method_id, payment_provider,
     paid_to_number, paid_to_iban, paid_to_account_number,
     paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_uid, 'pending', v_method.id, v_method.provider,
     v_method.mobile_number, v_method.iban, v_method.account_number,
     v_event.price_per_person, v_group_size);

  insert into public.event_participants
    (event_id, user_id, guest_name, added_by, payment_status,
     payment_method_id, payment_provider, paid_to_number, paid_to_iban,
     paid_to_account_number, paid_price_per_person)
  select p_event_id, null, g, v_uid, 'pending',
         v_method.id, v_method.provider, v_method.mobile_number,
         v_method.iban, v_method.account_number, v_event.price_per_person
  from unnest(v_guests) as g;

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_uid;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'payment_submitted', p_event_id);

  return json_build_object(
    'status', 'submitted',
    'creator_id', v_event.creator_id,
    'event_id', v_event.id,
    'payment_method_id', v_method.id,
    'provider', v_method.provider,
    'mobile_number', v_method.mobile_number,
    'iban', v_method.iban,
    'account_number', v_method.account_number,
    'payment_methods', '[]'::jsonb,
    'total_price', v_event.total_price,
    'price_per_person', v_event.price_per_person,
    'group_size', v_group_size
  );
end;
$$;

revoke execute on function public.submit_payment_v2(uuid, text[], uuid, decimal, uuid) from public, anon;
grant execute on function public.submit_payment_v2(uuid, text[], uuid, decimal, uuid) to authenticated;

-- Legacy STC-only endpoint. Old clients must never silently submit against a
-- bank, Barq, or cash destination using their STC screen.
create or replace function public.submit_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_guest_names text[] default '{}'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_method public.workspace_payment_methods;
  v_result jsonb;
  v_method_ids uuid[];
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.total_price <= 0 then
    return json_build_object('status', 'free_event');
  end if;
  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;
  if cardinality(v_method_ids) = 0 then
    return json_build_object('status', 'payment_method_required');
  end if;

  select * into v_method
  from public.workspace_payment_methods pm
  where pm.id = any(v_method_ids)
    and pm.workspace_id = v_event.workspace_id
    and pm.provider = 'stc_bank'
  order by array_position(v_method_ids, pm.id)
  limit 1
  for share;

  if v_method.id is null then
    select * into v_method
    from public.workspace_payment_methods pm
    where pm.id = any(v_method_ids)
      and pm.workspace_id = v_event.workspace_id
    order by array_position(v_method_ids, pm.id)
    limit 1;
    if v_method.id is null then
      return json_build_object('status', 'payment_method_required');
    end if;
    return json_build_object(
      'status', 'client_upgrade_required',
      'provider', v_method.provider
    );
  end if;

  v_result := public.submit_payment_v2(
    p_event_id => p_event_id,
    p_guest_names => p_guest_names,
    p_payment_method_id => v_method.id
  )::jsonb;
  if v_result ->> 'status' = 'submitted' then
    v_result := v_result || jsonb_build_object('paid_to_number', v_method.mobile_number);
  end if;
  return v_result::json;
end;
$$;

revoke execute on function public.submit_payment(uuid, uuid, text[]) from public, anon;
grant execute on function public.submit_payment(uuid, uuid, text[]) to authenticated;

-- A joiner may cancel only their own pending group. The legacy implementation
-- trusted p_user_id, which allowed an authenticated caller to target another
-- member if both ids were known.
create or replace function public.cancel_pending(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid)
    and payment_status = 'pending';
  get diagnostics v_deleted_rows = row_count;

  if v_deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'cancelled',
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.cancel_pending(uuid, uuid) from public, anon;
grant execute on function public.cancel_pending(uuid, uuid) to authenticated;

-- Apply the same caller binding to confirmed withdrawals and waitlist exits.
-- A confirmed payer owns the guest rows they added, so leaving releases the
-- whole group instead of leaving orphaned seats behind.
create or replace function public.leave_event(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.creator_id = v_uid then
    raise exception 'Event creator cannot leave their own event';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid);
  get diagnostics v_deleted_rows = row_count;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', case when v_deleted_rows > 0 then 'left' else 'not_participant' end,
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.leave_event(uuid, uuid) from public, anon;
grant execute on function public.leave_event(uuid, uuid) to authenticated;

create or replace function public.leave_waitlist(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace_id uuid;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select workspace_id into v_workspace_id
  from public.events
  where id = p_event_id;
  if v_workspace_id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_uid;
  return json_build_object('status', 'left');
end;
$$;

revoke execute on function public.leave_waitlist(uuid, uuid) from public, anon;
grant execute on function public.leave_waitlist(uuid, uuid) to authenticated;

-- --------------------------------------------------------------------------
-- create_event keeps the old client price argument for wire compatibility but
-- ignores it: the trigger computes the authoritative per-player amount.
-- --------------------------------------------------------------------------
drop function if exists public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision, text);
drop function if exists public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision, text, uuid);

create or replace function public.create_event(
  p_creator_id uuid,
  p_workspace_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null,
  p_total_price int default 0,
  p_price_per_person decimal default 0,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_recurrence text default 'none',
  p_payment_method_id uuid default null,
  p_payment_method_ids uuid[] default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_template_id uuid;
  v_duration_minutes int;
  v_payment_method_ids uuid[];
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Invalid recurrence: %', p_recurrence;
  end if;
  if p_total_price < 0 then
    raise exception 'Total price cannot be negative';
  end if;
  if p_max_participants is not null and p_max_participants <= 0 then
    raise exception 'Player count must be greater than zero';
  end if;
  if p_total_price > 0 and p_max_participants is null then
    raise exception 'Player count is required when total price is greater than zero';
  end if;
  v_payment_method_ids := coalesce(p_payment_method_ids, '{}'::uuid[]);
  if cardinality(v_payment_method_ids) = 0 and p_payment_method_id is not null then
    v_payment_method_ids := array[p_payment_method_id];
  end if;
  if p_total_price > 0 and cardinality(v_payment_method_ids) = 0 then
    raise exception 'A payment method is required when total price is greater than zero';
  end if;
  if cardinality(v_payment_method_ids) <> (
    select count(distinct selected_id)
    from unnest(v_payment_method_ids) as selected(selected_id)
  ) then
    raise exception 'Payment methods must be non-null and unique';
  end if;
  if exists (
    select 1
    from unnest(v_payment_method_ids) as selected(selected_id)
    left join public.workspace_payment_methods pm
      on pm.id = selected.selected_id
     and pm.workspace_id = p_workspace_id
    where pm.id is null
  ) then
    raise exception 'Payment method does not belong to the event workspace';
  end if;

  if p_recurrence = 'weekly' then
    if p_end_date is not null then
      v_duration_minutes := (extract(epoch from (p_end_date - p_start_date)) / 60)::int;
    end if;
    insert into public.event_templates
      (workspace_id, creator_id, name, location, description, image_url,
       latitude, longitude, total_price, price_per_person, max_participants,
       duration_minutes, recurrence, next_occurrence_at, payment_method_id,
       payment_method_ids)
    values
      (p_workspace_id, v_uid, p_name, p_location, p_description, p_image_url,
       p_latitude, p_longitude, p_total_price, 0, p_max_participants,
       v_duration_minutes, 'weekly', p_start_date + interval '7 days',
       v_payment_method_ids[1], v_payment_method_ids)
    returning id into v_template_id;
  end if;

  insert into public.events
    (creator_id, workspace_id, name, location, description, start_date,
     end_date, image_url, max_participants, total_price, price_per_person,
     latitude, longitude, template_id, payment_method_id, payment_method_ids)
  values
    (v_uid, p_workspace_id, p_name, p_location, p_description, p_start_date,
     p_end_date, p_image_url, p_max_participants, p_total_price, 0,
     p_latitude, p_longitude, v_template_id, v_payment_method_ids[1],
     v_payment_method_ids)
  returning * into v_event;

  insert into public.event_participants (event_id, user_id)
  values (v_event.id, v_uid);

  return row_to_json(v_event);
end;
$$;

revoke execute on function public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision, text, uuid, uuid[]) from public, anon;
grant execute on function public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision, text, uuid, uuid[]) to authenticated;

-- --------------------------------------------------------------------------
-- Recurrence copies the selected payment method into every occurrence.
-- --------------------------------------------------------------------------
create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl record;
  v_event public.events;
begin
  for tpl in
    select * from public.event_templates t
    where t.ended_at is null
      and now() >= t.next_occurrence_at - make_interval(days => t.lead_days)
    order by t.next_occurrence_at
    for update
  loop
    if tpl.skip_next then
      update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at + interval '7 days',
          skip_next = false
      where id = tpl.id;
      continue;
    end if;

    while tpl.next_occurrence_at <= now() loop
      tpl.next_occurrence_at := tpl.next_occurrence_at + interval '7 days';
    end loop;

    if now() < tpl.next_occurrence_at - make_interval(days => tpl.lead_days) then
      update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at
      where id = tpl.id;
      continue;
    end if;

    insert into public.events
      (creator_id, workspace_id, name, location, description, start_date,
       end_date, image_url, max_participants, total_price, price_per_person,
       latitude, longitude, template_id, payment_method_id, payment_method_ids)
    values
      (tpl.creator_id, tpl.workspace_id, tpl.name, tpl.location, tpl.description,
       tpl.next_occurrence_at,
       case when tpl.duration_minutes is not null
         then tpl.next_occurrence_at + make_interval(mins => tpl.duration_minutes) end,
       tpl.image_url, tpl.max_participants, tpl.total_price, 0,
       tpl.latitude, tpl.longitude, tpl.id, tpl.payment_method_id,
       tpl.payment_method_ids)
    returning * into v_event;

    insert into public.event_participants (event_id, user_id)
    values (v_event.id, tpl.creator_id);

    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, 'event_opened', v_event.id
    from public.workspace_members wm
    where wm.workspace_id = tpl.workspace_id
      and wm.user_id <> tpl.creator_id;

    update public.event_templates
    set next_occurrence_at = tpl.next_occurrence_at + interval '7 days'
    where id = tpl.id;
  end loop;
end;
$$;

revoke execute on function public.generate_recurring_events() from public, anon, authenticated;

create or replace function public.enable_recurrence(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_template public.event_templates;
  v_duration_minutes int;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if v_event.creator_id is distinct from auth.uid() then
    raise exception 'Not the event creator';
  end if;

  if v_event.template_id is not null then
    select * into v_template
    from public.event_templates
    where id = v_event.template_id
    for update;
  end if;

  if v_template.id is not null and v_template.ended_at is null then
    return row_to_json(v_template);
  end if;

  if v_template.id is not null then
    update public.event_templates
    set ended_at = null, skip_next = false
    where id = v_template.id
    returning * into v_template;
    return row_to_json(v_template);
  end if;

  if v_event.end_date is not null then
    v_duration_minutes := (extract(epoch from (v_event.end_date - v_event.start_date)) / 60)::int;
  end if;

  insert into public.event_templates
    (workspace_id, creator_id, name, location, description, image_url,
     latitude, longitude, total_price, price_per_person, max_participants,
     duration_minutes, recurrence, next_occurrence_at, payment_method_id,
     payment_method_ids)
  values
    (v_event.workspace_id, v_event.creator_id, v_event.name, v_event.location,
     v_event.description, v_event.image_url, v_event.latitude, v_event.longitude,
     v_event.total_price, 0, v_event.max_participants, v_duration_minutes,
     'weekly', v_event.start_date + interval '7 days',
     v_event.payment_method_id, v_event.payment_method_ids)
  returning * into v_template;

  update public.events set template_id = v_template.id where id = p_event_id;
  return row_to_json(v_template);
end;
$$;

revoke execute on function public.enable_recurrence(uuid) from public, anon;
grant execute on function public.enable_recurrence(uuid) to authenticated;

-- --------------------------------------------------------------------------
-- Confirmation/rejection authorize the authenticated caller, not a trusted
-- client parameter. Signatures stay unchanged for current clients.
-- --------------------------------------------------------------------------
create or replace function public.confirm_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_updated_rows int;
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can confirm payments';
  end if;

  update public.event_participants
  set payment_status = 'confirmed'
  where event_id = p_event_id
    and (user_id = p_user_id or added_by = p_user_id)
    and payment_status = 'pending';
  get diagnostics v_updated_rows = row_count;

  if v_updated_rows = 0 then
    return json_build_object('status', 'no_pending_row');
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_confirmed', p_event_id);
  return json_build_object('status', 'confirmed', 'joiner_id', p_user_id);
end;
$$;

revoke execute on function public.confirm_payment(uuid, uuid, uuid) from public, anon;
grant execute on function public.confirm_payment(uuid, uuid, uuid) to authenticated;

create or replace function public.reject_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = p_user_id or added_by = p_user_id)
    and payment_status = 'pending';
  get diagnostics v_deleted_rows = row_count;

  if v_deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'rejected',
    'joiner_id', p_user_id,
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.reject_payment(uuid, uuid, uuid) from public, anon;
grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

-- Payment destination snapshots are visible only to the event creator and the
-- participant who submitted that group. Other workspace members still receive
-- names and status, but never account/mobile details.
create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_event public.events;
  v_uid uuid := auth.uid();
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(x) order by x.joined_at asc), '[]'::json)
    from (
      select
        ep.id as participant_id,
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, au.email, ep.guest_name) as display_name,
        null::text as avatar_url,
        ep.payment_status,
        ep.payment_provider,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.payment_method_id else null end as payment_method_id,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_number else null end as paid_to_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_iban else null end as paid_to_iban,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_account_number else null end as paid_to_account_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_price_per_person else null end as paid_price_per_person,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id
          then ep.payment_group_size else null end as payment_group_size,
        ep.guest_name,
        ep.added_by
      from public.event_participants ep
      left join auth.users au on au.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id
    ) x
  );
end;
$$;

revoke execute on function public.get_event_participants(uuid) from public, anon;
grant execute on function public.get_event_participants(uuid) to authenticated;

-- Make newly-created RPC signatures visible immediately to PostgREST after
-- the transaction commits (Supabase also performs its normal DDL reload).
notify pgrst, 'reload schema';
