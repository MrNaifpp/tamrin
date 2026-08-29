# Backend Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put a database behind the three features on `codex/simulator-demo` that
save only to `UserDefaults`, resolve the ratings migration that staging deleted,
and collapse Home's launch from `1 + 2N + M` requests to one.

**Architecture:** Five migrations, each with a psql suite, plus the Swift wiring
that replaces `UserDefaults` reads with service calls. Every new table is RPC
only, following the `player_ratings` precedent already in this repo: RLS on with
no policies, no grants, and `security definer` functions as the only door.

**Tech Stack:** Postgres 15 (Supabase), plpgsql, Swift 6 / SwiftUI, supabase-swift.

Spec: `docs/superpowers/specs/2026-08-29-backend-coverage-design.md`

## Global Constraints

- **No iOS test target exists. Do NOT scaffold XCTest.** iOS tasks are verified
  by a clean build plus the manual device checks listed in each task.
- iOS build check, must print `BUILD SUCCEEDED`:
  `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
- SQL suites run against the LOCAL stack only:
  `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/<name>_test.sql`
- **`supabase db reset` is broken on this machine.** Apply a new migration with
  `psql ... -f supabase/migrations/<file>.sql`. Do not re-run the whole
  migration set to compare behaviour.
- Test suites follow the existing style: one `begin;` … `rollback;`
  transaction, `pg_temp.set_auth(uid)` for impersonation, and
  `raise exception 'FAIL: ...'` on a failed assertion. This repo does not use
  pgTAP.
- Every new function: `security definer`, `set search_path = public`,
  `returns json`, then
  `revoke execute ... from public, anon; grant execute ... to authenticated;`
  and `notify pgrst, 'reload schema';` at the end of the migration.
- **Never commit `Sirr.xcodeproj/project.pbxproj`.** It carries a local
  `DEVELOPMENT_TEAM` and bundle id. `git add` explicit paths, never `git add -A`.
- No em dashes in anything a person reads, including Arabic copy.
- Migration timestamps must sort after `20260829120000`.

---

### Task 1: The sport enum and the generated symbol column

**Files:**
- Create: `supabase/migrations/20260830100000_workspace_sport_enum.sql`
- Test: `supabase/tests/workspace_sport_enum_test.sql`

**Interfaces:**
- Consumes: nothing.
- Produces: type `public.sport` with labels
  `soccer, basketball, volleyball, padel, tennis, cricket, running, cycling`;
  column `public.workspaces.sport public.sport not null default 'soccer'`;
  column `public.workspaces.symbol text` now **generated**, computed from sport.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/workspace_sport_enum_test.sql`:

```sql
-- Sport enum test suite. Run against the LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_enum_test.sql
-- Everything runs in one transaction and rolls back.

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك');

-- ============================================================
-- Section 1: the type exists, with exactly the eight sports the
-- picker offers, in the picker's order.
-- ============================================================
do $$
declare
  labels text[];
begin
  select array_agg(e.enumlabel::text order by e.enumsortorder)
  into labels
  from pg_enum e
  join pg_type t on t.oid = e.enumtypid
  where t.typname = 'sport';

  if labels is null then
    raise exception 'FAIL: type public.sport does not exist';
  end if;

  if labels <> array['soccer','basketball','volleyball','padel',
                     'tennis','cricket','running','cycling'] then
    raise exception 'FAIL: sport labels are %, expected the eight picker sports in order', labels;
  end if;
end $$;

-- ============================================================
-- Section 2: every sport renders the symbol the app expects.
-- ============================================================
do $$
declare
  pair record;
  got text;
  w_id uuid;
begin
  for pair in
    select * from (values
      ('soccer',     'figure.soccer'),
      ('basketball', 'figure.basketball'),
      ('volleyball', 'figure.volleyball'),
      ('padel',      'figure.pickleball'),
      ('tennis',     'figure.tennis'),
      ('cricket',    'figure.cricket'),
      ('running',    'figure.run'),
      ('cycling',    'figure.outdoor.cycle')
    ) as t(sport, symbol)
  loop
    insert into public.workspaces (name, owner_id, sport)
    values ('نادي', '00000000-0000-0000-0000-000000000001', pair.sport::public.sport)
    returning symbol into got;

    if got is distinct from pair.symbol then
      raise exception 'FAIL: sport % rendered symbol %, expected %',
        pair.sport, got, pair.symbol;
    end if;
  end loop;
end $$;

-- ============================================================
-- Section 3: symbol is computed, not writable.
-- ============================================================
do $$
declare
  ok boolean := false;
begin
  begin
    insert into public.workspaces (name, owner_id, sport, symbol)
    values ('نادي', '00000000-0000-0000-0000-000000000001', 'padel', 'figure.soccer');
  exception when others then
    ok := true;
  end;

  if not ok then
    raise exception 'FAIL: symbol accepted a direct write; it must be generated';
  end if;
end $$;

-- ============================================================
-- Section 4: a workspace created without a sport is soccer, and
-- reads back the soccer symbol. This is the shape every row had
-- before the enum existed.
-- ============================================================
do $$
declare
  w public.workspaces;
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي', '00000000-0000-0000-0000-000000000001')
  returning * into w;

  if w.sport <> 'soccer' then
    raise exception 'FAIL: default sport is %, expected soccer', w.sport;
  end if;
  if w.symbol <> 'figure.soccer' then
    raise exception 'FAIL: default symbol is %, expected figure.soccer', w.symbol;
  end if;
end $$;

select 'workspace_sport_enum: all sections passed' as result;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_enum_test.sql
```

Expected: FAIL. Section 1 raises `FAIL: type public.sport does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260830100000_workspace_sport_enum.sql`:

```sql
-- The sport a group plays, as a value the database understands.
--
-- `workspaces.symbol` held an SF Symbol name chosen in the picker, and the
-- artwork folder was derived from that string by a switch inside the app. The
-- sport is the fact. The symbol and the folder are two renderings of it, so the
-- fact is what is stored and the renderings follow from it.

create type public.sport as enum (
  'soccer', 'basketball', 'volleyball', 'padel',
  'tennis', 'cricket', 'running', 'cycling'
);

alter table public.workspaces
  add column sport public.sport not null default 'soccer';

-- Backfill from the symbol each workspace already carries. This map is the one
-- in SportArtLibrary.folder(for:). A symbol from a build that predates the
-- picker, or any value not on the list, becomes soccer, which is the fallback
-- the app already applies to it.
update public.workspaces
set sport = (case symbol
  when 'figure.soccer'        then 'soccer'
  when 'figure.basketball'    then 'basketball'
  when 'figure.volleyball'    then 'volleyball'
  when 'figure.pickleball'    then 'padel'
  when 'figure.tennis'        then 'tennis'
  when 'figure.cricket'       then 'cricket'
  when 'figure.run'           then 'running'
  when 'figure.outdoor.cycle' then 'cycling'
  else 'soccer'
end)::public.sport;

-- The symbol column stays, computed.
--
-- get_my_workspaces selects it by name and there are builds in the field that
-- decode it, so dropping it outright would break them. Generated rather than a
-- second stored column because two stored columns describing one fact drift,
-- and the drift would show as a group whose icon and artwork disagree.
--
-- The drop takes workspaces_symbol_not_blank with it, which is the point: a
-- generated column cannot be blank.
alter table public.workspaces drop column symbol;

alter table public.workspaces
  add column symbol text generated always as (
    case sport
      when 'soccer'     then 'figure.soccer'
      when 'basketball' then 'figure.basketball'
      when 'volleyball' then 'figure.volleyball'
      when 'padel'      then 'figure.pickleball'
      when 'tennis'     then 'figure.tennis'
      when 'cricket'    then 'figure.cricket'
      when 'running'    then 'figure.run'
      when 'cycling'    then 'figure.outdoor.cycle'
    end
  ) stored;

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Apply the migration and run the test**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260830100000_workspace_sport_enum.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_enum_test.sql
```

Expected: `workspace_sport_enum: all sections passed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260830100000_workspace_sport_enum.sql supabase/tests/workspace_sport_enum_test.sql
git commit -m "feat(sport): store the sport, and compute the symbol from it"
```

---

### Task 2: Workspace RPCs learn the sport

**Files:**
- Create: `supabase/migrations/20260830110000_workspace_sport_rpcs.sql`
- Test: `supabase/tests/workspace_sport_rpcs_test.sql`

**Interfaces:**
- Consumes: `public.sport`, `workspaces.sport` (Task 1).
- Produces:
  - `public.create_workspace(p_name text, p_sport public.sport) returns json`
  - `public.create_workspace(p_name text, p_symbol text) returns json` (replaced, maps symbol to sport)
  - `public.update_workspace(p_workspace_id uuid, p_name text, p_sport public.sport) returns json`
  - `public.get_my_workspaces()` now returns a `sport` key
  - `public.symbol_to_sport(p_symbol text) returns public.sport`
  - `public.update_exercise_template(...)` writes `sport` instead of `symbol`,
    same 15 arguments, same return shape

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/workspace_sport_rpcs_test.sql`:

```sql
-- Sport-aware workspace RPC suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_rpcs_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك');

-- ============================================================
-- Section 1: the sport overload writes the sport.
-- ============================================================
do $$
declare
  result json;
  w_id uuid;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  result := public.create_workspace('نادي البادل', 'padel'::public.sport);
  w_id := (result->>'id')::uuid;

  select sport into got from public.workspaces where id = w_id;
  if got <> 'padel' then
    raise exception 'FAIL: create_workspace(sport) stored %, expected padel', got;
  end if;

  if result->>'symbol' <> 'figure.pickleball' then
    raise exception 'FAIL: returned symbol is %, expected figure.pickleball', result->>'symbol';
  end if;
end $$;

-- ============================================================
-- Section 2: the legacy symbol overload still works, and no
-- longer writes symbol directly.
-- ============================================================
do $$
declare
  result json;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  result := public.create_workspace('نادي التنس', 'figure.tennis');

  select sport into got from public.workspaces where id = (result->>'id')::uuid;
  if got <> 'tennis' then
    raise exception 'FAIL: symbol overload stored %, expected tennis', got;
  end if;
end $$;

-- ============================================================
-- Section 3: an unknown symbol falls back to soccer rather than
-- failing. Older builds send whatever they had.
-- ============================================================
do $$
declare
  result json;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  result := public.create_workspace('نادي قديم', 'figure.something.unknown');

  select sport into got from public.workspaces where id = (result->>'id')::uuid;
  if got <> 'soccer' then
    raise exception 'FAIL: unknown symbol stored %, expected soccer', got;
  end if;
end $$;

-- ============================================================
-- Section 4: update_workspace changes the sport, owner only.
-- ============================================================
do $$
declare
  w_id uuid;
  got public.sport;
  denied boolean := false;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w_id := (public.create_workspace('نادي', 'soccer'::public.sport)->>'id')::uuid;

  perform public.update_workspace(w_id, 'نادي', 'volleyball'::public.sport);
  select sport into got from public.workspaces where id = w_id;
  if got <> 'volleyball' then
    raise exception 'FAIL: update_workspace stored %, expected volleyball', got;
  end if;

  insert into auth.users (id, email)
  values ('00000000-0000-0000-0000-000000000009', 'outsider@test.local');
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000009');
  begin
    perform public.update_workspace(w_id, 'نادي', 'tennis'::public.sport);
  exception when others then
    denied := true;
  end;
  if not denied then
    raise exception 'FAIL: a non owner changed the sport';
  end if;
end $$;

-- ============================================================
-- Section 5: get_my_workspaces carries the sport.
-- ============================================================
do $$
declare
  feed json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_workspaces();

  if not (feed::text like '%"sport"%') then
    raise exception 'FAIL: get_my_workspaces does not return a sport key';
  end if;
end $$;

-- ============================================================
-- Section 6: editing an exercise still works. update_exercise_template
-- wrote `symbol` directly, which is an error now that the column is
-- generated, so this is the section that catches a half done migration.
-- ============================================================
do $$
declare
  w_id uuid;
  e_id uuid;
  got public.sport;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w_id := (public.create_workspace('نادي', 'soccer'::public.sport)->>'id')::uuid;

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_id, '00000000-0000-0000-0000-000000000001', 'تمرين', now() + interval '1 day', now())
  returning id into e_id;

  perform public.update_exercise_template(
    w_id, e_id, 'occurrence', 'نادي البادل', 'figure.pickleball', 'تمرين',
    'الملعب', now() + interval '1 day', now() + interval '1 day 2 hours',
    14, 250, null, null, null, null
  );

  select sport into got from public.workspaces where id = w_id;
  if got <> 'padel' then
    raise exception 'FAIL: editing the exercise stored sport %, expected padel', got;
  end if;
end $$;

select 'workspace_sport_rpcs: all sections passed' as result;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_rpcs_test.sql
```

Expected: FAIL. Section 1 raises
`function public.create_workspace(unknown, sport) does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260830110000_workspace_sport_rpcs.sql`:

```sql
-- The RPCs that write a sport.
--
-- Both symbol-taking overloads are replaced rather than left alone: they
-- inserted into `symbol`, and an insert into a generated column is an error.
-- They now map the symbol to a sport and let the symbol compute itself, so a
-- build in the field keeps working without knowing the enum exists.

create or replace function public.symbol_to_sport(p_symbol text)
returns public.sport
language sql
immutable
as $$
  select (case coalesce(nullif(trim(p_symbol), ''), 'figure.soccer')
    when 'figure.soccer'        then 'soccer'
    when 'figure.basketball'    then 'basketball'
    when 'figure.volleyball'    then 'volleyball'
    when 'figure.pickleball'    then 'padel'
    when 'figure.tennis'        then 'tennis'
    when 'figure.cricket'       then 'cricket'
    when 'figure.run'           then 'running'
    when 'figure.outdoor.cycle' then 'cycling'
    else 'soccer'
  end)::public.sport;
$$;

create or replace function public.create_workspace(p_name text, p_sport public.sport)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  insert into public.workspaces (name, owner_id, sport)
  values (trim(p_name), v_uid, coalesce(p_sport, 'soccer'))
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

-- The legacy overload, now a thin translation onto the one above.
create or replace function public.create_workspace(p_name text, p_symbol text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_workspace(p_name, public.symbol_to_sport(p_symbol));
end;
$$;

create or replace function public.update_workspace(
  p_workspace_id uuid,
  p_name text,
  p_sport public.sport
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_owner(p_workspace_id, v_uid) then
    raise exception 'Only the owner can update this exercise';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  update public.workspaces
  set name = trim(p_name),
      sport = coalesce(p_sport, sport)
  where id = p_workspace_id
  returning * into w;

  return row_to_json(w);
end;
$$;

-- The sport joins the explicit select list. get_workspace returns row_to_json(w)
-- and therefore already carries it.
create or replace function public.get_my_workspaces()
returns json
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(json_agg(row_to_json(t) order by t.created_at asc), '[]'::json)
  from (
    select w.id, w.name, w.owner_id, w.invite_code, w.image_url, w.symbol,
           w.sport, w.color, w.created_at,
           (select count(*) from public.workspace_members m2
             where m2.workspace_id = w.id) as member_count
    from public.workspaces w
    join public.workspace_members m
      on m.workspace_id = w.id and m.user_id = auth.uid()
  ) t;
$$;

revoke execute on function public.create_workspace(text, public.sport) from public, anon;
grant execute on function public.create_workspace(text, public.sport) to authenticated;
revoke execute on function public.update_workspace(uuid, text, public.sport) from public, anon;
grant execute on function public.update_workspace(uuid, text, public.sport) to authenticated;
grant execute on function public.symbol_to_sport(text) to authenticated;

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Stop update_exercise_template writing the symbol**

This is the step that keeps editing an exercise working. The function at
`supabase/migrations/20260829120000_update_exercise_template.sql:127` runs:

```sql
  update public.workspaces
  set name = v_workspace_name,
      symbol = v_symbol
  where id = p_workspace_id
  returning * into v_workspace;
```

After Task 1 that statement fails with `column "symbol" can only be updated to
DEFAULT`, and every exercise edit fails with it.

Append the whole function to `20260830110000_workspace_sport_rpcs.sql` by copying
`supabase/migrations/20260829120000_update_exercise_template.sql` verbatim, from
its `create or replace function public.update_exercise_template(` line through
its closing `$$;`, and then making exactly two changes to the copy:

1. The workspace update writes the sport instead of the symbol:

```sql
  update public.workspaces
  set name = v_workspace_name,
      sport = public.symbol_to_sport(v_symbol)
  where id = p_workspace_id
  returning * into v_workspace;
```

2. Above that statement, replace the comment about the symbol with:

```sql
  -- The caller still sends an SF Symbol, because that is what the picker has
  -- always sent. It is translated once, here, and the symbol column computes
  -- itself from the result.
```

Leave the argument list, the validation at lines 46 and 54, and everything else
exactly as it was. The 80 character check on `v_symbol` still applies: an
oversized value is a client bug worth rejecting whether or not it maps.

- [ ] **Step 5: Apply the migration and run the test**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260830110000_workspace_sport_rpcs.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_rpcs_test.sql
```

Expected: `workspace_sport_rpcs: all sections passed`.

- [ ] **Step 6: Re-run Task 1's suite to prove nothing regressed**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/workspace_sport_enum_test.sql
```

Expected: `workspace_sport_enum: all sections passed`.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260830110000_workspace_sport_rpcs.sql supabase/tests/workspace_sport_rpcs_test.sql
git commit -m "feat(sport): let the workspace RPCs take a sport"
```

---

### Task 3: The app sends the sport, and stops seeding photographs

**Files:**
- Modify: `Sirr/core/supabase/WorkspaceService.swift` (WorkspaceRecord, create, update)
- Modify: `Sirr/features/home/SportArtLibrary.swift` (key off the sport, delete `ExerciseArtSeed`)
- Modify: `Sirr/features/home/DesignerHomeView.swift:133-140`
- Modify: `Sirr/features/home/MockHomeFeed.swift` (FeedTeam gains `sport`)

**Interfaces:**
- Consumes: the `sport` key from `get_my_workspaces` and `get_workspace` (Task 2).
- Produces: `WorkspaceRecord.sport: String?`, `FeedTeam.sport: String`,
  `SportArtLibrary.photo(for:sportKey:)` unchanged in signature, its caller now
  passing `team.sport` instead of deriving a key from the symbol.

- [ ] **Step 1: Carry the sport on the record**

In `Sirr/core/supabase/WorkspaceService.swift`, add to `WorkspaceRecord` after
`symbol`:

```swift
    /// The sport as the database stores it. Nil on a server that predates the
    /// enum, where `symbol` is still the only answer.
    let sport: String?
```

and add `sport` to `CodingKeys`:

```swift
        case id, name, symbol, sport, color
```

- [ ] **Step 2: Send the sport when creating and updating**

`createWorkspace` at `Sirr/core/supabase/WorkspaceService.swift:88` already takes
an optional symbol. Add a sport beside it, defaulted so the two existing call
sites keep compiling:

```swift
    func createWorkspace(
        name: String,
        symbol: String? = nil,
        color: String? = nil,
        sport: String = "soccer"
```

and send it, replacing `p_symbol`:

```swift
        let params: [String: AnyJSON] = [
            "p_name": .string(name),
            "p_sport": .string(sport)
        ]
```

`updateWorkspace` gains the same parameter and sends
`"p_sport": .string(sport)` alongside `p_workspace_id` and `p_name`.

The two call sites pass the chosen sport rather than the symbol:
`Sirr/features/home/MockHomeFeed.swift:1382` and
`Sirr/Components/CreateWorkspaceSheet.swift:84`. Where either still holds only a
symbol, translate once at the call site with `Sport.named(symbol)?.key ?? "soccer"`.

- [ ] **Step 3: Key the artwork off the sport**

In `Sirr/features/home/SportArtLibrary.swift`, delete the whole `ExerciseArtSeed`
enum and its `UserDefaults` key. `photo(for:sportKey:)` loses the seed:

```swift
    /// The photo this exercise wears. Fixed for any one exercise, and the same
    /// on every device, because both halves of the choice now come from the
    /// server: the sport is the group's, and the index is a stable hash of the
    /// exercise's own id.
    ///
    /// Nil when the sport has no photos yet, which is the caller's cue to fall
    /// back to the artwork the app ships with.
    static func photo(for eventID: UUID, sportKey: String?) -> String? {
        guard let sportKey else { return nil }
        let all = photos(forSport: sportKey)
        guard !all.isEmpty else { return nil }
        return all[stableIndex(for: eventID, count: all.count)]
    }
```

Delete `reroll(for:)` and every call to it. Re-rolling no longer exists: the
photo is a function of the sport and the exercise id.

- [ ] **Step 4: Read the sport straight off the group**

In `Sirr/features/home/MockHomeFeed.swift`, add to `FeedTeam` after `symbol`:

```swift
    /// The sport this group plays, as the database stores it. Drives the
    /// artwork folder.
    var sport: String = "soccer"
```

and set it where `FeedTeam` is built from a `WorkspaceRecord`:

```swift
            sport: record.sport ?? Sport.named(record.symbol ?? "")?.key ?? "soccer",
```

In `Sirr/features/home/EventDetailView.swift:139`, the pitch style reads the
sport rather than deriving it from the symbol:

```swift
        LineupSportStyle(sport: feed.team(for: occurrence)?.sport)
```

Give `LineupSportStyle` a `sport:` initializer beside its `symbol:` one, mapping
the same eight values, and delete the `symbol:` one once nothing calls it.

In `Sirr/features/home/DesignerHomeView.swift`, replace the body of `art(for:)`:

```swift
    private func art(for occurrence: FeedOccurrence) -> String {
        let sportKey = feed.team(for: occurrence)?.sport
        return SportArtLibrary.photo(for: occurrence.id, sportKey: sportKey)
            ?? artName(occurrence.artIndex)
    }
```

- [ ] **Step 5: Build**

Run:

```
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`. Fix every reference to the deleted `ExerciseArtSeed`
and `reroll` until it does.

- [ ] **Step 6: Hand over for a device check**

The build passing is not the verification. On device, confirm:
1. Creating an exercise and choosing البادل shows a padel photograph.
2. The same exercise shows the same photograph on a second account.
3. Editing the exercise to التنس leaves it on a shipped artwork, since
   `SportArt/tennis/` is empty.

- [ ] **Step 7: Commit**

```bash
git add Sirr/core/supabase/WorkspaceService.swift Sirr/features/home/SportArtLibrary.swift Sirr/features/home/DesignerHomeView.swift Sirr/features/home/MockHomeFeed.swift
git commit -m "feat(sport): read the sport from the server, and drop the photo seed"
```

---

### Task 4: Lineup tables and RPCs

**Files:**
- Create: `supabase/migrations/20260830120000_event_lineups.sql`
- Test: `supabase/tests/event_lineups_test.sql`

**Interfaces:**
- Consumes: `public.events`, `public.event_participants`, `public.is_workspace_owner`.
- Produces:
  - `public.save_event_lineup(p_event_id uuid, p_first uuid[], p_second uuid[], p_positions jsonb) returns json`
  - `public.publish_event_lineup(p_event_id uuid) returns json`
  - `public.get_event_lineup(p_event_id uuid) returns json`
  - Return shape of `get_event_lineup`:
    `{"status": "draft"|"published", "published_at": ts|null, "updated_at": ts, "first": [uuid], "second": [uuid], "positions": {"<participant_id>": "midfielder"}}`
    or SQL `null` when the caller may not see it.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/event_lineups_test.sql`:

```sql
-- Lineup suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_lineups_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local'),
  ('00000000-0000-0000-0000-000000000002', 'player@test.local'),
  ('00000000-0000-0000-0000-000000000003', 'outsider@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك'),
  ('00000000-0000-0000-0000-000000000002', 'لاعب'),
  ('00000000-0000-0000-0000-000000000003', 'غريب');

-- Fixture: one workspace, one event, two participants.
create or replace function pg_temp.fixture(
  out w_id uuid, out e_id uuid, out p_owner uuid, out p_player uuid
) language plpgsql as $$
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي', '00000000-0000-0000-0000-000000000001')
  returning id into w_id;

  insert into public.workspace_members (workspace_id, user_id) values
    (w_id, '00000000-0000-0000-0000-000000000001'),
    (w_id, '00000000-0000-0000-0000-000000000002');

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_id, '00000000-0000-0000-0000-000000000001', 'تمرين', now() + interval '1 day', now())
  returning id into e_id;

  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-000000000001') returning id into p_owner;
  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-000000000002') returning id into p_player;
end;
$$;

-- ============================================================
-- Section 1: the owner saves a split, and reads it back in order.
-- ============================================================
do $$
declare
  f record;
  lineup json;
begin
  f := pg_temp.fixture();
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');

  perform public.save_event_lineup(
    f.e_id,
    array[f.p_owner],
    array[f.p_player],
    json_build_object(f.p_player::text, 'midfielder')::jsonb
  );

  lineup := public.get_event_lineup(f.e_id);
  if lineup is null then
    raise exception 'FAIL: the owner cannot read the lineup he just saved';
  end if;
  if lineup->>'status' <> 'draft' then
    raise exception 'FAIL: a fresh lineup is %, expected draft', lineup->>'status';
  end if;
  if (lineup->'first'->>0)::uuid <> f.p_owner then
    raise exception 'FAIL: side one holds the wrong participant';
  end if;
  if lineup->'positions'->>(f.p_player::text) <> 'midfielder' then
    raise exception 'FAIL: the position override did not survive the save';
  end if;
end $$;

-- ============================================================
-- Section 2: a draft is invisible to a player; publishing shows it.
-- ============================================================
do $$
declare
  f record;
begin
  f := pg_temp.fixture();
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  if public.get_event_lineup(f.e_id) is not null then
    raise exception 'FAIL: a player can see a draft lineup';
  end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  if public.get_event_lineup(f.e_id) is null then
    raise exception 'FAIL: a player cannot see a published lineup';
  end if;
end $$;

-- ============================================================
-- Section 3: everyone else is refused.
-- ============================================================
do $$
declare
  f record;
  denied boolean := false;
begin
  f := pg_temp.fixture();

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  begin
    perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);
  exception when others then
    denied := true;
  end;
  if not denied then
    raise exception 'FAIL: a player saved a lineup';
  end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000003');
  if public.get_event_lineup(f.e_id) is not null then
    raise exception 'FAIL: an outsider read a published lineup';
  end if;
end $$;

-- ============================================================
-- Section 4: the split has to be real. A stranger to this
-- exercise, a duplicate, and an invented position are refused.
-- ============================================================
do $$
declare
  f record;
  other record;
  denied boolean;
begin
  f := pg_temp.fixture();
  other := pg_temp.fixture();
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');

  denied := false;
  begin
    perform public.save_event_lineup(f.e_id, array[other.p_owner], array[f.p_player], '{}'::jsonb);
  exception when others then denied := true; end;
  if not denied then
    raise exception 'FAIL: a participant of another exercise was placed';
  end if;

  denied := false;
  begin
    perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_owner], '{}'::jsonb);
  exception when others then denied := true; end;
  if not denied then
    raise exception 'FAIL: one participant was placed on both sides';
  end if;

  denied := false;
  begin
    perform public.save_event_lineup(
      f.e_id, array[f.p_owner], array[f.p_player],
      json_build_object(f.p_player::text, 'striker')::jsonb
    );
  exception when others then denied := true; end;
  if not denied then
    raise exception 'FAIL: an unknown position was accepted';
  end if;
end $$;

-- ============================================================
-- Section 5: a correction after publishing stays published, and a
-- player who leaves takes his slot with him.
-- ============================================================
do $$
declare
  f record;
  lineup json;
begin
  f := pg_temp.fixture();
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  perform public.save_event_lineup(f.e_id, array[f.p_owner], array[f.p_player], '{}'::jsonb);
  perform public.publish_event_lineup(f.e_id);
  perform public.save_event_lineup(f.e_id, array[f.p_player], array[f.p_owner], '{}'::jsonb);

  lineup := public.get_event_lineup(f.e_id);
  if lineup->>'status' <> 'published' then
    raise exception 'FAIL: correcting a published lineup returned it to %', lineup->>'status';
  end if;

  delete from public.event_participants where id = f.p_player;
  lineup := public.get_event_lineup(f.e_id);
  if json_array_length(lineup->'first') <> 0 then
    raise exception 'FAIL: a departed player kept his slot';
  end if;
end $$;

select 'event_lineups: all sections passed' as result;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_lineups_test.sql
```

Expected: FAIL with `function public.save_event_lineup(...) does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260830120000_event_lineups.sql`:

```sql
-- The split, «التشكيلة», as the group's answer rather than one phone's note.
--
-- A slot points at event_participants, not at auth.users. That is the id the
-- app already carries for a player, and it is the only id a guest or a manually
-- added player has at all. It also means a participant who leaves takes his
-- slot with him through the cascade, which is the line the roster already draws.
--
-- Names, ratings and strength are deliberately absent. They are read fresh from
-- the roster every time the pitch is drawn, so a player who changed his position
-- does not carry a stale one into the next exercise.
--
-- Both tables are RPC only: RLS on with no policies, no grants. The privacy rule
-- lives in get_event_lineup, where it cannot be sidestepped by a hand rolled
-- request.

create table if not exists public.event_lineups (
  event_id     uuid primary key references public.events(id) on delete cascade,
  status       text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  updated_at   timestamptz not null default now(),
  updated_by   uuid not null references auth.users(id)
);

create table if not exists public.event_lineup_slots (
  event_id       uuid not null references public.event_lineups(event_id) on delete cascade,
  participant_id uuid not null references public.event_participants(id) on delete cascade,
  side           smallint not null check (side in (1, 2)),
  ordinal        integer not null,
  position       text check (position in ('goalkeeper', 'defender', 'midfielder', 'forward')),
  primary key (event_id, participant_id)
);

create index if not exists idx_event_lineup_slots_event_side
  on public.event_lineup_slots(event_id, side, ordinal);

alter table public.event_lineups enable row level security;
alter table public.event_lineup_slots enable row level security;
revoke all on table public.event_lineups from public, anon, authenticated;
revoke all on table public.event_lineup_slots from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Saving replaces the whole split in one statement pair. A lineup is one
-- arrangement, not a set of edits, so a partial write has no meaning.
-- --------------------------------------------------------------------------
create or replace function public.save_event_lineup(
  p_event_id uuid,
  p_first uuid[],
  p_second uuid[],
  p_positions jsonb default '{}'::jsonb
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
  v_all uuid[] := coalesce(p_first, '{}') || coalesce(p_second, '{}');
  v_key text;
  v_value text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then raise exception 'Exercise not found'; end if;
  if not public.is_workspace_owner(v_workspace, v_uid) then
    raise exception 'Only the organizer can save a lineup';
  end if;

  if array_length(v_all, 1) is distinct from
     (select count(distinct x) from unnest(v_all) as x) then
    raise exception 'A player cannot hold two places in one lineup';
  end if;

  if exists (
    select 1 from unnest(v_all) as candidate(id)
    where not exists (
      select 1 from public.event_participants p
      where p.id = candidate.id and p.event_id = p_event_id
    )
  ) then
    raise exception 'Every player in a lineup must hold a seat in this exercise';
  end if;

  for v_key, v_value in select * from jsonb_each_text(coalesce(p_positions, '{}'::jsonb))
  loop
    if v_value not in ('goalkeeper', 'defender', 'midfielder', 'forward') then
      raise exception 'Unknown position: %', v_value;
    end if;
    if not (v_key::uuid = any(v_all)) then
      raise exception 'A position was given for a player who is not in the lineup';
    end if;
  end loop;

  insert into public.event_lineups (event_id, updated_by)
  values (p_event_id, v_uid)
  on conflict (event_id) do update
    set updated_at = now(), updated_by = v_uid;

  delete from public.event_lineup_slots where event_id = p_event_id;

  insert into public.event_lineup_slots (event_id, participant_id, side, ordinal, position)
  select p_event_id, id, 1, ordinality - 1,
         nullif(p_positions->>id::text, '')
  from unnest(coalesce(p_first, '{}')) with ordinality as t(id, ordinality)
  union all
  select p_event_id, id, 2, ordinality - 1,
         nullif(p_positions->>id::text, '')
  from unnest(coalesce(p_second, '{}')) with ordinality as t(id, ordinality);

  return public.get_event_lineup(p_event_id);
end;
$$;

create or replace function public.publish_event_lineup(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then raise exception 'Exercise not found'; end if;
  if not public.is_workspace_owner(v_workspace, v_uid) then
    raise exception 'Only the organizer can publish a lineup';
  end if;

  update public.event_lineups
  set status = 'published',
      published_at = coalesce(published_at, now()),
      updated_at = now(),
      updated_by = v_uid
  where event_id = p_event_id;

  if not found then
    raise exception 'There is no lineup to publish yet';
  end if;

  return public.get_event_lineup(p_event_id);
end;
$$;

-- --------------------------------------------------------------------------
-- Reading. The organizer always sees his own working copy. A member holding a
-- seat sees it only once it is published, and receives null before that so the
-- app can say there is no lineup yet rather than show an error. Everyone else
-- receives null.
-- --------------------------------------------------------------------------
create or replace function public.get_event_lineup(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
  v_is_owner boolean;
  v_holds_seat boolean;
  v_lineup public.event_lineups;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then return null; end if;

  select * into v_lineup from public.event_lineups where event_id = p_event_id;
  if v_lineup.event_id is null then return null; end if;

  v_is_owner := public.is_workspace_owner(v_workspace, v_uid);
  v_holds_seat := exists (
    select 1 from public.event_participants p
    where p.event_id = p_event_id and p.user_id = v_uid
  );

  if not v_is_owner and not (v_holds_seat and v_lineup.status = 'published') then
    return null;
  end if;

  return json_build_object(
    'status', v_lineup.status,
    'published_at', v_lineup.published_at,
    'updated_at', v_lineup.updated_at,
    'first', (
      select coalesce(json_agg(s.participant_id order by s.ordinal), '[]'::json)
      from public.event_lineup_slots s
      where s.event_id = p_event_id and s.side = 1
    ),
    'second', (
      select coalesce(json_agg(s.participant_id order by s.ordinal), '[]'::json)
      from public.event_lineup_slots s
      where s.event_id = p_event_id and s.side = 2
    ),
    'positions', (
      select coalesce(json_object_agg(s.participant_id, s.position), '{}'::json)
      from public.event_lineup_slots s
      where s.event_id = p_event_id and s.position is not null
    )
  );
end;
$$;

revoke execute on function public.save_event_lineup(uuid, uuid[], uuid[], jsonb) from public, anon;
grant execute on function public.save_event_lineup(uuid, uuid[], uuid[], jsonb) to authenticated;
revoke execute on function public.publish_event_lineup(uuid) from public, anon;
grant execute on function public.publish_event_lineup(uuid) to authenticated;
revoke execute on function public.get_event_lineup(uuid) from public, anon;
grant execute on function public.get_event_lineup(uuid) to authenticated;

notify pgrst, 'reload schema';
```

- [ ] **Step 4: Apply the migration and run the test**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260830120000_event_lineups.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/event_lineups_test.sql
```

Expected: `event_lineups: all sections passed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260830120000_event_lineups.sql supabase/tests/event_lineups_test.sql
git commit -m "feat(lineup): give the split a table, and a published state"
```

---

### Task 5: The lineup leaves the phone

**Files:**
- Create: `Sirr/core/supabase/LineupService.swift`
- Modify: `Sirr/features/home/Lineup.swift:470-553` (`LineupPositionStore`, `LineupStore`)
- Modify: `Sirr/features/home/LineupFlowView.swift` (publish action)
- Modify: `Sirr/features/home/LineupTeamPage.swift` (reachable by seat holders)

**Interfaces:**
- Consumes: `save_event_lineup`, `publish_event_lineup`, `get_event_lineup` (Task 4).
- Produces:
  - `LineupService.shared.get(eventID: UUID) async throws -> LineupRecord?`
  - `LineupService.shared.save(eventID: UUID, plan: LineupPlan, positions: LineupPositions) async throws -> LineupRecord`
  - `LineupService.shared.publish(eventID: UUID) async throws -> LineupRecord`
  - `struct LineupRecord { let status: String; let publishedAt: Date?; let first: [UUID]; let second: [UUID]; let positions: [String: String] }`
  - `LineupRecord.isPublished: Bool`

- [ ] **Step 1: Write the service**

Create `Sirr/core/supabase/LineupService.swift`:

```swift
//
//  LineupService.swift
//  Sirr
//
//  The split, read and written where the whole group can see it.
//
//  The three calls mirror the three functions LineupStore used to answer from
//  UserDefaults, so the views above them did not have to learn anything new.
//

import Foundation
import Supabase

struct LineupRecord: Decodable {
    let status: String
    let publishedAt: Date?
    let first: [UUID]
    let second: [UUID]
    let positions: [String: String]

    var isPublished: Bool { status == "published" }

    enum CodingKeys: String, CodingKey {
        case status, first, second, positions
        case publishedAt = "published_at"
    }
}

@MainActor
final class LineupService {
    static let shared = LineupService()
    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    func get(eventID: UUID) async throws -> LineupRecord? {
        let response = try await client
            .rpc("get_event_lineup", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        // The RPC answers null for a draft nobody may see yet, which is not an
        // error: it is the app's cue to offer to build one.
        if response.data.isEmpty { return nil }
        return try? EventService.makePostgresDecoder().decode(LineupRecord.self, from: response.data)
    }

    @discardableResult
    func save(
        eventID: UUID,
        plan: LineupPlan,
        positions: LineupPositions
    ) async throws -> LineupRecord {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventID.uuidString),
            "p_first": .array(plan.first.map { .string($0.uuidString) }),
            "p_second": .array(plan.second.map { .string($0.uuidString) }),
            "p_positions": .object(positions.byPlayer.mapValues { AnyJSON.string($0) })
        ]
        let response = try await client
            .rpc("save_event_lineup", params: params)
            .execute()
        return try EventService.makePostgresDecoder().decode(LineupRecord.self, from: response.data)
    }

    @discardableResult
    func publish(eventID: UUID) async throws -> LineupRecord {
        let response = try await client
            .rpc("publish_event_lineup", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        return try EventService.makePostgresDecoder().decode(LineupRecord.self, from: response.data)
    }
}
```

`makePostgresDecoder` is `private static` at
`Sirr/core/supabase/EventService.swift:352`. Drop the `private` so this file can
reuse it, rather than duplicating a second decoder that will drift from it:

```swift
    static func makePostgresDecoder() -> JSONDecoder {
```

- [ ] **Step 2: Point the stores at the service**

In `Sirr/features/home/Lineup.swift`, replace the bodies of `LineupStore` and
`LineupPositionStore` so both read one record. Keep the three function names, and
keep `normalizeLegacyValues` running on what comes back, since a device may still
hold values written by an older build:

```swift
enum LineupStore {
    static func load(eventID: UUID) async -> (plan: LineupPlan, positions: LineupPositions)? {
        guard let record = try? await LineupService.shared.get(eventID: eventID) else { return nil }
        var positions = LineupPositions(byPlayer: record.positions)
        positions.normalizeLegacyValues()
        let plan = LineupPlan(first: record.first, second: record.second, updatedAt: .now)
        return (plan, positions)
    }

    static func save(_ plan: LineupPlan, positions: LineupPositions, eventID: UUID) async {
        _ = try? await LineupService.shared.save(eventID: eventID, plan: plan, positions: positions)
    }

    static func publish(eventID: UUID) async {
        _ = try? await LineupService.shared.publish(eventID: eventID)
    }
}
```

`LineupPlan` gains the memberwise initializer this needs:

```swift
    init(first: [UUID], second: [UUID], updatedAt: Date = .now) {
        self.first = first
        self.second = second
        self.updatedAt = updatedAt
    }
```

Delete `LineupPositionStore` entirely and every call to it. Delete
`LineupStore.clear`, and in `ContentView.swift`'s `LineupDebugScreen` remove the
`LineupStore.clear(eventID:)` line, since a debug screen no longer has local
state to clear.

- [ ] **Step 3: Add the publish action**

In `Sirr/features/home/LineupFlowView.swift`, the button that finishes the flow
publishes before dismissing:

```swift
                Button("نشر التشكيلة") {
                    Task {
                        await LineupStore.save(plan, positions: positions, eventID: occurrence.id)
                        await LineupStore.publish(eventID: occurrence.id)
                        onFinish(plan)
                    }
                }
```

Every drag already calls `save`. Publishing is the separate, deliberate step.

- [ ] **Step 4: Let seat holders open the team page**

`EventDetailView` presents `LineupTeamPage` at line 311 and `LineupFlowView` at
line 532. Gate them on what the server answers rather than on ownership:

```swift
    @State private var lineupRecord: LineupRecord?

    private var canSeeLineup: Bool { lineupRecord != nil }
    private var canEditLineup: Bool { feed.isOwner(of: occurrence) }
```

Load `lineupRecord` in the same `task` that loads the roster. The RPC already
answers null to anyone who may not see the lineup, so the app needs no second
rule of its own: showing the card when a record comes back is the whole check.
`LineupFlowView` stays behind `canEditLineup`, since only the organizer saves.

- [ ] **Step 5: Build**

Run:

```
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Hand over for a device check**

1. Organizer splits an exercise, closes the app, reopens: the split is still there.
2. A player in the same exercise sees no lineup until the organizer publishes.
3. After publishing, the player sees the two sides.
4. The organizer moves one player after publishing; the player sees the change,
   and the lineup does not go back to being hidden.

- [ ] **Step 7: Commit**

```bash
git add Sirr/core/supabase/LineupService.swift Sirr/features/home/Lineup.swift Sirr/features/home/LineupFlowView.swift Sirr/features/home/LineupTeamPage.swift Sirr/ContentView.swift
git commit -m "feat(lineup): save the split to the group, and publish it"
```

---

### Task 6: Feature feedback reaches somewhere it can be read

**Files:**
- Create: `supabase/migrations/20260830130000_feature_feedback.sql`
- Test: `supabase/tests/feature_feedback_test.sql`
- Modify: `Sirr/features/feedback/FeatureFeedback.swift:60-92`

**Interfaces:**
- Consumes: nothing.
- Produces: `public.submit_feature_feedback(p_feature text, p_stars integer, p_note text) returns json`,
  returning `{"ok": true}`.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/feature_feedback_test.sql`:

```sql
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/feature_feedback_test.sql
```

Expected: FAIL with `function public.submit_feature_feedback(...) does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260830130000_feature_feedback.sql`:

```sql
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
```

- [ ] **Step 4: Apply the migration and run the test**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260830130000_feature_feedback.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/feature_feedback_test.sql
```

Expected: `feature_feedback: all sections passed`.

- [ ] **Step 5: Send it from the app**

In `Sirr/features/feedback/FeatureFeedback.swift`, `FeatureFeedbackStore.save`
sends the verdict and keeps only the presentation state locally:

```swift
    /// The verdict goes to the server. The quiet period and the "already asked"
    /// stamp stay here: they are this device's presentation state, not data
    /// worth a table.
    static func save(_ feedback: FeatureFeedback, feature: TamrinFeature) {
        Task {
            _ = try? await SupabaseClientManager.shared.client
                .rpc("submit_feature_feedback", params: [
                    "p_feature": AnyJSON.string(feature.rawValue),
                    "p_stars": AnyJSON.integer(feedback.stars),
                    "p_note": AnyJSON.string(feedback.note)
                ])
                .execute()
        }
        UserDefaults.standard.set(Date(), forKey: askedKey(feature))
    }
```

Delete `answerKey` and the local read of a saved answer: nothing in the app shows
a verdict back, so storing it on the device has no reader.

- [ ] **Step 6: Build**

Run:

```
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260830130000_feature_feedback.sql supabase/tests/feature_feedback_test.sql Sirr/features/feedback/FeatureFeedback.swift
git commit -m "feat(feedback): send the verdict, and keep it unreadable in the app"
```

---

### Task 7: One request for Home

**Files:**
- Create: `supabase/migrations/20260830140000_get_my_feed.sql`
- Test: `supabase/tests/get_my_feed_test.sql`

**Interfaces:**
- Consumes: `public.is_workspace_owner`, the `get_workspace_events` row shape.
- Produces: `public.get_my_feed() returns json`, shaped
  `{"workspaces": [...], "events": [...], "participants": [...], "responses": [...]}`
  where every participant and response row carries an `event_id`.

- [ ] **Step 1: Write the failing test**

Create `supabase/tests/get_my_feed_test.sql`:

```sql
-- Home feed suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/get_my_feed_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local'),
  ('00000000-0000-0000-0000-000000000002', 'member@test.local'),
  ('00000000-0000-0000-0000-000000000003', 'stranger@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك'),
  ('00000000-0000-0000-0000-000000000002', 'عضو'),
  ('00000000-0000-0000-0000-000000000003', 'غريب');

-- Two workspaces the owner runs, one he has nothing to do with.
do $$
declare
  w_a uuid; w_b uuid; w_other uuid; e_id uuid;
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي أ', '00000000-0000-0000-0000-000000000001') returning id into w_a;
  insert into public.workspaces (name, owner_id)
  values ('نادي ب', '00000000-0000-0000-0000-000000000001') returning id into w_b;
  insert into public.workspaces (name, owner_id)
  values ('نادي غريب', '00000000-0000-0000-0000-000000000003') returning id into w_other;

  insert into public.workspace_members (workspace_id, user_id) values
    (w_a, '00000000-0000-0000-0000-000000000001'),
    (w_a, '00000000-0000-0000-0000-000000000002'),
    (w_b, '00000000-0000-0000-0000-000000000001'),
    (w_other, '00000000-0000-0000-0000-000000000003');

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_a, '00000000-0000-0000-0000-000000000001', 'تمرين أ', now() + interval '1 day', now())
  returning id into e_id;
  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-000000000002');

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_b, '00000000-0000-0000-0000-000000000001', 'تمرين ب', now() + interval '2 days', now());

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_other, '00000000-0000-0000-0000-000000000003', 'تمرين غريب', now() + interval '1 day', now());
end $$;

-- ============================================================
-- Section 1: the feed spans the caller's workspaces and stops there.
-- ============================================================
do $$
declare
  feed json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_feed();

  if json_array_length(feed->'workspaces') <> 2 then
    raise exception 'FAIL: % workspaces returned, expected 2', json_array_length(feed->'workspaces');
  end if;
  if json_array_length(feed->'events') <> 2 then
    raise exception 'FAIL: % events returned, expected 2', json_array_length(feed->'events');
  end if;
  if feed::text like '%تمرين غريب%' then
    raise exception 'FAIL: the feed leaked an exercise from a workspace the caller is not in';
  end if;
end $$;

-- ============================================================
-- Section 2: rosters arrive with the events, keyed by event.
-- ============================================================
do $$
declare
  feed json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_feed();

  if json_array_length(feed->'participants') < 1 then
    raise exception 'FAIL: no rosters in the feed';
  end if;
  if (feed->'participants'->0->>'event_id') is null then
    raise exception 'FAIL: a participant row has no event_id to group it by';
  end if;
end $$;

-- ============================================================
-- Section 3: apology reasons reach the organizer and nobody else.
-- ============================================================
do $$
declare
  feed json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  feed := public.get_my_feed();

  if json_array_length(feed->'responses') <> 0 then
    raise exception 'FAIL: a member received invitation responses';
  end if;
  if json_array_length(feed->'workspaces') <> 1 then
    raise exception 'FAIL: the member sees % workspaces, expected 1', json_array_length(feed->'workspaces');
  end if;
end $$;

select 'get_my_feed: all sections passed' as result;

rollback;
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/get_my_feed_test.sql
```

Expected: FAIL with `function public.get_my_feed() does not exist`.

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/20260830140000_get_my_feed.sql`:

```sql
-- Home in one request.
--
-- Home is every exercise the person is part of, nearest first, so it was asking
-- for the workspace list, then each workspace's events, then each workspace's
-- detail, then a roster for every event, and for an organizer the invitation
-- responses on top. That is 1 + 2N + M requests before the first card can be
-- trusted, run in sequence.
--
-- The rows are the ones get_workspace_events already returns, with the
-- workspace filter replaced by membership. The visibility rule travels with
-- them: an unpublished exercise is the organizer's alone.
--
-- Invitation responses are included only for workspaces the caller owns. They
-- carry the reason someone gave for not coming, which is private to the
-- organizer.

create or replace function public.get_my_feed()
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  return json_build_object(
    'workspaces', public.get_my_workspaces(),

    'events', (
      select coalesce(json_agg(row_to_json(x) order by x.start_date asc), '[]'::json)
      from (
        select e.*,
               e.published_at is not null as is_published,
               e.cancelled_at is not null as is_cancelled,
               r.status as my_response_status,
               r.status as current_user_response,
               r.reason_code as current_user_reason_code,
               r.reason_text as current_user_reason_text,
               exists (
                 select 1 from public.event_templates t
                 where t.id = e.template_id and t.ended_at is null
               ) as is_recurring
        from public.events e
        left join public.event_member_responses r
          on r.event_id = e.id and r.user_id = v_uid
        where e.workspace_id in (
                select m.workspace_id from public.workspace_members m
                where m.user_id = v_uid
              )
          and (e.published_at is not null or public.is_workspace_owner(e.workspace_id, v_uid))
          and coalesce(e.end_date, e.start_date) >= now()
      ) x
    ),

    -- Rosters and responses come out of the functions that already answer for
    -- them, one row per event, rather than a second copy of their select lists.
    -- Those functions decide which columns a given reader may see: the payment
    -- destination is the payer's and the organizer's, the reminder stamp is the
    -- organizer's alone. Rewriting that rule here would mean maintaining it
    -- twice and leaking the day the two drift.
    'participants', (
      select coalesce(json_agg(row), '[]'::json)
      from (
        select jsonb_set(elem::jsonb, '{event_id}', to_jsonb(e.id))::json as row
        from public.events e
        cross join lateral json_array_elements(public.get_event_participants(e.id)) as elem
        where e.workspace_id in (
                select m.workspace_id from public.workspace_members m
                where m.user_id = v_uid
              )
          and (e.published_at is not null or public.is_workspace_owner(e.workspace_id, v_uid))
          and coalesce(e.end_date, e.start_date) >= now()
      ) t
    ),

    'responses', (
      select coalesce(json_agg(row), '[]'::json)
      from (
        select jsonb_set(elem::jsonb, '{event_id}', to_jsonb(e.id))::json as row
        from public.events e
        cross join lateral json_array_elements(public.get_event_member_responses(e.id)) as elem
        where public.is_workspace_owner(e.workspace_id, v_uid)
          and coalesce(e.end_date, e.start_date) >= now()
      ) t
    )
  );
end;
$$;

revoke execute on function public.get_my_feed() from public, anon;
grant execute on function public.get_my_feed() to authenticated;

notify pgrst, 'reload schema';
```

Each participant row is exactly what `get_event_participants` returns, with an
`event_id` added, so `ParticipantRecord` decodes it unchanged and the app's
existing `applyParticipants` can consume it as it stands. The same holds for
responses and `EventMemberResponseRecord`.

- [ ] **Step 4: Apply the migration and run the test**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/migrations/20260830140000_get_my_feed.sql && psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/get_my_feed_test.sql
```

Expected: `get_my_feed: all sections passed`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260830140000_get_my_feed.sql supabase/tests/get_my_feed_test.sql
git commit -m "feat(home): answer the whole shelf in one request"
```

---

### Task 8: Home asks once

**Files:**
- Modify: `Sirr/core/supabase/EventService.swift` (add `getMyFeed`)
- Modify: `Sirr/features/home/MockHomeFeed.swift:915-919` (`loadAllTeamsData`)

**Interfaces:**
- Consumes: `get_my_feed` (Task 7).
- Produces: `EventService.shared.getMyFeed() async throws -> MyFeedRecord`,
  where `MyFeedRecord` holds `workspaces: [WorkspaceRecord]`,
  `events: [EventRecord]`, `participants: [FeedParticipantRow]`,
  `responses: [FeedResponseRow]`.

- [ ] **Step 1: Add the call**

In `Sirr/core/supabase/EventService.swift`:

```swift
/// A roster row as the feed returns it: everything `get_event_participants`
/// gives, plus the exercise it belongs to. Composed rather than redeclared, so
/// a column added to ParticipantRecord arrives here too.
struct FeedParticipantRow: Decodable {
    let eventId: UUID
    let participant: ParticipantRecord

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
    }

    init(from decoder: Decoder) throws {
        eventId = try decoder.container(keyedBy: CodingKeys.self)
            .decode(UUID.self, forKey: .eventId)
        participant = try ParticipantRecord(from: decoder)
    }
}

struct FeedResponseRow: Decodable {
    let eventId: UUID
    let response: EventMemberResponseRecord

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
    }

    init(from decoder: Decoder) throws {
        eventId = try decoder.container(keyedBy: CodingKeys.self)
            .decode(UUID.self, forKey: .eventId)
        response = try EventMemberResponseRecord(from: decoder)
    }
}

struct MyFeedRecord: Decodable {
    let workspaces: [WorkspaceRecord]
    let events: [EventRecord]
    let participants: [FeedParticipantRow]
    let responses: [FeedResponseRow]
}

extension EventService {
    func getMyFeed() async throws -> MyFeedRecord {
        let response = try await client.rpc("get_my_feed").execute()
        let feed = try Self.makePostgresDecoder().decode(MyFeedRecord.self, from: response.data)
        eventLogger.info(
            "API getMyFeed succeeded (workspaces: \(feed.workspaces.count), events: \(feed.events.count))"
        )
        return feed
    }
}
```

- [ ] **Step 2: Replace the loop**

In `Sirr/features/home/MockHomeFeed.swift`, `loadAllTeamsData` becomes:

```swift
    /// Home in one request. The shelf spans every workspace, so asking each one
    /// in turn made a launch cost a round trip per group plus a roster per card,
    /// in sequence. get_my_feed answers all of it at once.
    ///
    /// loadTeamData stays for the single workspace refresh after a write.
    func loadAllTeamsData() async {
        guard let feed = try? await EventService.shared.getMyFeed() else { return }

        for event in feed.events { eventRecordsByID[event.id] = event }

        // EventRecord.workspaceId is optional, so an event that predates
        // workspaces groups under no team rather than crashing the shelf.
        let eventsByTeam = Dictionary(
            grouping: feed.events.filter { $0.workspaceId != nil },
            by: { $0.workspaceId! }
        )
        for team in teams {
            let events = eventsByTeam[team.id] ?? []
            occurrencesByTeam[team.id] = events.map(mapOccurrence)
            plansByTeam[team.id] = events.map(synthesizePlan)
            for event in events {
                memberResponseByEvent[event.id] =
                    event.myResponseStatus.flatMap(FeedMemberResponse.init(rawValue:))
            }
        }

        // The rows are ParticipantRecords, so the existing mapping applies
        // unchanged. An event with an empty roster still has to be applied, or
        // a card that emptied since the last launch keeps its stale count.
        var rostersByEvent: [UUID: [ParticipantRecord]] = [:]
        for event in feed.events { rostersByEvent[event.id] = [] }
        for row in feed.participants { rostersByEvent[row.eventId, default: []].append(row.participant) }
        for (eventId, parts) in rostersByEvent { applyParticipants(parts, to: eventId) }

        for event in feed.events { memberResponseRecordsByEvent[event.id] = nil }
        var responsesByEvent: [UUID: [EventMemberResponseRecord]] = [:]
        for row in feed.responses { responsesByEvent[row.eventId, default: []].append(row.response) }
        for (eventId, responses) in responsesByEvent {
            memberResponseRecordsByEvent[eventId] = responses
        }
    }
```

- [ ] **Step 3: Build**

Run:

```
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Hand over for a device check**

1. Home shows every exercise across every group, nearest first, as before.
2. Each card shows the right seat count on first paint, with no flicker from a
   roster arriving late.
3. An organizer still sees apology reasons; a member still does not.
4. Registering for an exercise still updates that card, through `loadTeamData`.

- [ ] **Step 5: Commit**

```bash
git add Sirr/core/supabase/EventService.swift Sirr/features/home/MockHomeFeed.swift
git commit -m "perf(home): load the whole shelf in one request"
```

---

### Task 9: The ratings migration survives the merge

**Files:**
- Modify: `docs/superpowers/specs/2026-08-29-backend-coverage-design.md` (record the outcome)

**Interfaces:**
- Consumes: `supabase/tests/player_ratings_test.sql`, already on this branch.
- Produces: a verified answer to whether `submit_player_rating` and
  `get_player_rating` exist after merging.

This task has no new code. It exists because the app calls two RPCs that staging
deleted, and nothing else in this plan would catch it.

- [ ] **Step 1: Confirm the branch still defines them**

Run:

```
git show HEAD:supabase/migrations/20260818100000_player_ratings.sql | grep -c "create or replace function public.submit_player_rating"
```

Expected: `1`.

- [ ] **Step 2: Confirm staging deletes them**

Run:

```
git log --oneline HEAD..staging -- supabase/migrations/20260818100000_player_ratings.sql
```

Expected: `a1bc5a4 revert(ratings): hold player ratings out of this sprint`.

- [ ] **Step 3: Run the ratings suite against the local schema**

Run:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/player_ratings_test.sql
```

Expected: the suite's own pass line. If it fails because the functions are
missing, the local stack was built from staging, and the migration must be
applied before any rating screen is tested.

- [ ] **Step 4: Write the merge instruction into the spec**

Add to the spec's ratings section:

```markdown
Verified on 2026-08-29: the migration is present on `codex/simulator-demo` and
deleted on `staging` by `a1bc5a4`. Whoever merges must keep this branch's copy.
A merge that takes staging's side ships an app calling two functions that do not
exist.
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-29-backend-coverage-design.md
git commit -m "docs(spec): record how the ratings migration must survive the merge"
```

---

## Verification

After Task 9, all five suites pass against one schema:

```bash
for suite in workspace_sport_enum workspace_sport_rpcs event_lineups feature_feedback get_my_feed player_ratings; do
  psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f "supabase/tests/${suite}_test.sql" || echo "SUITE FAILED: $suite"
done
```

Expected: six pass lines, no `SUITE FAILED`.

And the app builds:

```bash
xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

The device checks in Tasks 3, 5 and 8 are the real verification and cannot be
skipped. A build that compiles proves nothing about whether a player can see the
lineup.
