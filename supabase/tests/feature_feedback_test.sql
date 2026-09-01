-- Feature feedback suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/feature_feedback_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'rater@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'مقيّم');

-- ============================================================
-- Section 1: a verdict is stored.
-- ============================================================
do $$
declare
  got_stars smallint;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.submit_feature_feedback('lineup', 4, 'حلوة');

  select stars into got_stars from public.feature_feedback
  where user_id = '00000000-0000-0000-0000-000000000001' and feature = 'lineup';

  if got_stars is distinct from 4 then
    raise exception 'FAIL: stored % stars, expected 4', got_stars;
  end if;
end $$;

-- ============================================================
-- Section 2: a second verdict corrects the first rather than
-- stacking on top of it.
-- ============================================================
do $$
declare
  rows_kept integer;
  got_stars smallint;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.submit_feature_feedback('lineup', 2, 'غيرت رأيي');

  select count(*), max(stars) into rows_kept, got_stars
  from public.feature_feedback
  where user_id = '00000000-0000-0000-0000-000000000001' and feature = 'lineup';

  if rows_kept <> 1 then
    raise exception 'FAIL: % rows kept, expected one per person per feature', rows_kept;
  end if;
  if got_stars <> 2 then
    raise exception 'FAIL: the correction did not replace the first verdict';
  end if;
end $$;

-- ============================================================
-- Section 3: the bounds the sheet enforces are enforced here too.
-- ============================================================
do $$
declare
  denied boolean;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');

  denied := false;
  begin perform public.submit_feature_feedback('lineup', 6, '');
  exception when others then denied := true; end;
  if not denied then raise exception 'FAIL: six stars accepted'; end if;

  denied := false;
  begin perform public.submit_feature_feedback('lineup', 3, repeat('ا', 301));
  exception when others then denied := true; end;
  if not denied then raise exception 'FAIL: a note past 300 characters accepted'; end if;
end $$;

-- ============================================================
-- Section 4: nobody can read it back through the API.
-- ============================================================
do $$
begin
  if has_table_privilege('authenticated', 'public.feature_feedback', 'select') then
    raise exception 'FAIL: authenticated can select feature_feedback';
  end if;
  if (select count(*) from pg_policies where tablename = 'feature_feedback') > 0 then
    raise exception 'FAIL: feature_feedback has policies; it must be RPC only';
  end if;
end $$;

select 'feature_feedback: all sections passed' as result;

rollback;
