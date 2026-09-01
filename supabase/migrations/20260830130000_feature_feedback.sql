-- What someone thought of a feature, kept the way a rating is kept.
--
-- The promise the rating onboarding makes, «تقييمك مستور», is a promise about
-- what other people can see, and it is enforced here rather than in the client:
-- the table is RPC only, no function returns a row of it, and no screen can
-- render one. It is read in the dashboard.
--
-- One row per person per feature. A second submission is a correction, not a
-- second opinion.

create table if not exists public.feature_feedback (
  user_id    uuid not null references auth.users(id) on delete cascade,
  feature    text not null check (length(trim(feature)) between 1 and 40),
  stars      smallint not null check (stars between 1 and 5),
  note       text not null default '' check (length(note) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, feature)
);

alter table public.feature_feedback enable row level security;
revoke all on table public.feature_feedback from public, anon, authenticated;

create or replace function public.submit_feature_feedback(
  p_feature text,
  p_stars integer,
  p_note text default ''
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_note text := coalesce(p_note, '');
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  insert into public.feature_feedback (user_id, feature, stars, note)
  values (v_uid, trim(p_feature), p_stars, v_note)
  on conflict (user_id, feature) do update
    set stars = excluded.stars,
        note = excluded.note,
        updated_at = now();

  return json_build_object('ok', true);
end;
$$;

revoke execute on function public.submit_feature_feedback(text, integer, text) from public, anon;
grant execute on function public.submit_feature_feedback(text, integer, text) to authenticated;

notify pgrst, 'reload schema';
