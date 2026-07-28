-- Workspaces: private groups that contain events. One owner + equal members.
-- Mutations are RPC-only (see 20260702100200); RLS gives members read access.

-- URL-safe invite token, ambiguous chars (0O1Il o) excluded. 55^12 ≈ 2^69.
create or replace function public.new_invite_code()
returns text
language sql
volatile
set search_path = public
as $$
  select string_agg(
    substr('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789',
           (floor(random() * 55) + 1)::int, 1), '')
  from generate_series(1, 12);
$$;

grant execute on function public.new_invite_code() to authenticated;

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invite_code text not null unique default public.new_invite_code(),
  image_url text,
  created_at timestamptz not null default now()
);

-- The owner also gets a member row, so "members of X" is always one query.
create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create index idx_workspaces_owner_id on public.workspaces(owner_id);
create index idx_workspace_members_user_id on public.workspace_members(user_id);

-- Membership check. SECURITY DEFINER so RLS policies can call it without
-- recursing into workspace_members' own policy (same trick as
-- get_event_ids_visible_to_user).
create or replace function public.is_workspace_member(p_workspace_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.workspace_members
    where workspace_id = p_workspace_id and user_id = p_user_id
  );
$$;

grant execute on function public.is_workspace_member(uuid, uuid) to authenticated;

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;

create policy "Members can select their workspaces"
  on public.workspaces for select
  using (public.is_workspace_member(id, auth.uid()));

create policy "Members can select co-members"
  on public.workspace_members for select
  using (public.is_workspace_member(workspace_id, auth.uid()));
