-- Baseline: capture the public.users table that was originally created in the
-- Supabase Studio SQL editor for tamrin-stg but never committed as a
-- migration. All statements are `if not exists` so this is a no-op against
-- any environment where the table already exists.
--
-- Column name `postion` is misspelled in the original schema; preserved here
-- because the Swift client (AuthService.UserRecord) already maps to it.

create table if not exists public.users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  postion text not null default '',
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.users enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'users' and policyname = 'Users can read own row'
  ) then
    create policy "Users can read own row"
      on public.users for select
      using (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'users' and policyname = 'Users can insert own row'
  ) then
    create policy "Users can insert own row"
      on public.users for insert
      with check (user_id = auth.uid());
  end if;

  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'users' and policyname = 'Users can update own row'
  ) then
    create policy "Users can update own row"
      on public.users for update
      using (user_id = auth.uid());
  end if;
end $$;
