-- Single-row table the app reads at launch to decide whether the installed
-- version is still allowed to run.
--
-- This exists because 1.1 shipped pointing at the development project. Once
-- 1.2 moves to production, anyone left on 1.1 keeps writing to a database we
-- intend to treat as disposable, and without a gate they can stay there
-- indefinitely. Raising minimum_version is how we push them off.

create table if not exists public.app_config (
  -- Singleton: a boolean primary key that must be true means the table can
  -- physically hold only one row, so there is never a question of which row
  -- is the live one, and no way to accidentally insert a second.
  id              boolean primary key default true,
  minimum_version text        not null,
  update_url      text        not null,
  updated_at      timestamptz not null default now(),
  constraint app_config_singleton check (id)
);

alter table public.app_config enable row level security;

-- Readable without a session on purpose: the gate has to work before the user
-- signs in, and there is nothing sensitive in it.
drop policy if exists "App config is world readable" on public.app_config;
create policy "App config is world readable"
  on public.app_config
  for select
  to anon, authenticated
  using (true);

-- Deliberately no insert/update/delete policies. The only way to change the
-- gate is the dashboard or SQL editor, which run as service_role and bypass
-- RLS — so a leaked anon key cannot brick the app or unlock an old version.

-- Seeded inert: every shipped version is >= 1.0, so this blocks nobody. The
-- mechanism ships and gets proven in production before it is ever enforced;
-- raising the floor is then a one-line update with no release.
insert into public.app_config (id, minimum_version, update_url)
values (true, '1.0', 'https://apps.apple.com/app/id6757168784')
on conflict (id) do nothing;
