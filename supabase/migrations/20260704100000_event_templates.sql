-- Recurring workout templates (F1). A template stores the weekly series;
-- occurrences are ordinary events rows linked by template_id.
-- Spec: docs/superpowers/specs/2026-07-03-recurring-workouts-design.md

create table public.event_templates (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  creator_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  location text not null default '',
  description text not null default '',
  image_url text,
  latitude double precision,
  longitude double precision,
  total_price int not null default 0,
  price_per_person decimal(10,2) not null default 0,
  max_participants int,
  duration_minutes int,          -- end - start of the first event; null when it had no end date
  recurrence text not null check (recurrence in ('weekly')),  -- relaxes when more rules ship
  next_occurrence_at timestamptz not null,  -- single source of truth for "when is the next one"
  lead_days int not null default 3,         -- occurrence created when now() >= next_occurrence_at - lead_days
  skip_next boolean not null default false, -- one-shot flag consumed by the generator
  ended_at timestamptz,                     -- set by إنهاء التكرار; generator ignores ended templates
  created_at timestamptz not null default now()
);

create index idx_event_templates_workspace_id on public.event_templates(workspace_id);
-- Generator scan: live templates by due date.
create index idx_event_templates_due on public.event_templates(next_occurrence_at) where ended_at is null;

-- Occurrences link back to their series. Deleting a template stops future
-- generation but keeps all generated events (history preserved).
alter table public.events
  add column template_id uuid references public.event_templates(id) on delete set null;
create index idx_events_template_id on public.events(template_id);

alter table public.event_templates enable row level security;

-- Members can read their workspace's templates; all writes go through
-- SECURITY DEFINER RPCs (codebase pattern).
create policy "Members can select workspace templates"
  on public.event_templates for select
  using (public.is_workspace_member(workspace_id, auth.uid()));
