# Backend coverage for the simulator-demo branch

Date: 2026-08-29
Branch: `codex/simulator-demo`

## Why

Commit `cf5ae1e` added roughly 12,850 lines to the app. Most of it is backed by
the database, but three features save to `UserDefaults` on one device and never
reach the server:

* the lineup («التشكيلة»), about 2,650 lines of code, keyed `lineup.plan.<eventID>`;
* the exercise photo, keyed `exercise.art.seed.<eventID>`;
* feature feedback, which the file itself documents as local for now.

Two further problems are not storage gaps but will break in production:

* the app calls `submit_player_rating` and `get_player_rating`, and staging
  deleted the migration that defines them (`a1bc5a4`);
* Home loads every workspace in sequence, so a launch costs `1 + 2N + M`
  requests instead of one.

This spec covers all five.

## 1. Sport enum replaces the symbol as source of truth

Today the sport is a free text SF Symbol name on `workspaces.symbol`, and the
artwork folder is derived from it by a `switch` in the app.

```sql
create type public.sport as enum (
  'soccer', 'basketball', 'volleyball', 'padel',
  'tennis', 'cricket', 'running', 'cycling'
);

alter table public.workspaces
  add column sport public.sport not null default 'soccer';
```

The eight values are exactly the eight `SportPicker.all` offers, in the same
order. Existing rows are backfilled from `symbol` using the map already in
`SportArtLibrary.folder(for:)`:

| symbol                 | sport      |
|------------------------|------------|
| figure.soccer          | soccer     |
| figure.basketball      | basketball |
| figure.volleyball      | volleyball |
| figure.pickleball      | padel      |
| figure.tennis          | tennis     |
| figure.cricket         | cricket    |
| figure.run             | running    |
| figure.outdoor.cycle   | cycling    |

Anything unrecognised backfills to `soccer`, which is the fallback the app
already applies.

### The symbol column stays

`symbol` is kept, not dropped, because `get_my_workspaces` selects it by name
and there are builds in the field that decode it. It becomes a generated column
computed from `sport`, so the two can never drift:

```sql
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
```

The drop and re-add happen inside one migration, after the backfill has read
the original values into `sport`.

### RPCs that change

`create_workspace(text, text)` and `update_exercise_template` currently accept a
symbol. Both gain a sport overload that takes `public.sport`. The symbol
overloads are kept so older builds keep working, and they map their argument
through the same table above before writing `sport`.

Both symbol overloads must be replaced rather than left alone: they insert into
`symbol` directly today, and an insert into a generated column is an error. The
replacement writes `sport` and lets `symbol` compute itself.

`update_workspace` gains an optional sport argument.

### App changes

`SportPicker` writes the enum rather than the symbol. `SportArtLibrary.folder(for:)`
takes the sport directly instead of switching on a symbol string. `FeedTeam`
carries `sport`, and derives the icon from it.

### The photo itself

With the sport authoritative on the server, the photo follows from the sport and
no seed is stored anywhere. `ExerciseArtSeed` and its `UserDefaults` key are
deleted. A sport with photos in its folder shows one of them, chosen by the
existing stable hash of the event id, so every member sees the same photograph.

A sport whose folder is empty (tennis, cricket, running, cycling today) keeps
today's behaviour: one of the three images shipped in `Assets.xcassets`,
`ExerciseArt1` through `ExerciseArt3`, chosen by `stableIndex(ev.id)`. This is
deliberate and unchanged by this spec. Showing no photograph at all would mean
making `artName` optional across the card, the shelf, the event page, both
lineup pages and the archive backdrop, which is user-facing design work and
belongs in its own change.

Re-roll disappears as a concept. The photo is a function of sport and event id,
so there is nothing left to re-roll.

## 2. Lineup: draft, then publish

```sql
create table public.event_lineups (
  event_id     uuid primary key references public.events(id) on delete cascade,
  status       text not null default 'draft' check (status in ('draft', 'published')),
  published_at timestamptz,
  updated_at   timestamptz not null default now(),
  updated_by   uuid not null references auth.users(id)
);

create table public.event_lineup_slots (
  event_id       uuid not null references public.event_lineups(event_id) on delete cascade,
  participant_id uuid not null references public.event_participants(id) on delete cascade,
  side           smallint not null check (side in (1, 2)),
  ordinal        integer not null,
  position       text check (position in ('goalkeeper', 'defender', 'midfielder', 'forward')),
  primary key (event_id, participant_id)
);

create index idx_event_lineup_slots_event_side
  on public.event_lineup_slots(event_id, side, ordinal);
```

Slots reference `event_participants.id`, not `auth.users`. That is what
`LineupPlayer.id` already holds, and it is the only key a guest or a manually
added player has. A participant who leaves takes their slot with them through
the cascade, which is what `LineupPlan.resolve` does client side today.

`position` is the per exercise override that `LineupPositions.byPlayer` holds.
Null means read the position off the player's profile. Names, ratings and
strength are deliberately not stored: `LineupPlan` reads those fresh from the
roster on every draw so a player who changed position does not carry a stale one
into the next exercise.

Both tables are RPC only, following the `player_ratings` precedent: RLS enabled,
no policies, `revoke all` from `public`, `anon` and `authenticated`.

### RPCs

```sql
save_event_lineup(p_event_id uuid, p_first uuid[], p_second uuid[], p_positions jsonb) returns json
publish_event_lineup(p_event_id uuid) returns json
get_event_lineup(p_event_id uuid) returns json
```

`save_event_lineup` is owner only. It replaces every slot for the event in one
transaction and rejects the write when:

* the caller does not own the event's workspace;
* any id in either array is not a participant of this event;
* an id appears twice, in either array or across both;
* a position value is outside the four known values.

Array order becomes `ordinal`, which is what preserves the order within a band.
`p_positions` is a JSON object keyed by participant id.

Saving an already published lineup keeps it published and updates in place. The
organizer moving one player after publishing is a correction, not a new draft.

`publish_event_lineup` sets `status` to `published` and stamps `published_at`.
It is owner only, and it errors when no lineup has been saved yet.

`get_event_lineup` returns the two ordered arrays and the position map. The
owner always sees it. A member holding a seat sees it only once published, and
receives null before that, so the app can show "no lineup yet" rather than an
error. Anyone else receives null.

### App changes

`LineupStore.load`, `.save` and `.clear` become async calls into a new
`LineupService`, and `LineupPositionStore` folds into the same calls, since the
positions now travel with the plan. The file already anticipates this: every
caller goes through those three functions, so no view changes.

`LineupFlowView` gains a publish action. `LineupTeamPage` is reachable by any
seat holder once published, where today it is organizer only.

## 3. Feature feedback

```sql
create table public.feature_feedback (
  user_id    uuid not null references auth.users(id) on delete cascade,
  feature    text not null check (length(trim(feature)) between 1 and 40),
  stars      smallint not null check (stars between 1 and 5),
  note       text not null default '' check (length(note) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, feature)
);
```

Locked down exactly like `player_ratings`: RLS on with no policies, no grants on
the table, and writes only through a `security definer` RPC.

```sql
submit_feature_feedback(p_feature text, p_stars integer, p_note text) returns json
```

Upserts on `(user_id, feature)`, so a second submission corrects the first
rather than stacking. No RPC reads this table back. Nothing in the app can
display it, and it is read in the Supabase dashboard.

The 300 character limit matches `maximumNoteLength` in the sheet. The three day
quiet period and the "already asked" bookkeeping stay in `UserDefaults`: they
are per device presentation state, not data worth a table.

## 4. Player ratings

`20260818100000_player_ratings.sql` stays on this branch unchanged. The work
here is a merge instruction rather than code.

Staging reverted the migration in `a1bc5a4` while keeping the app code that
calls it. Merging this branch into staging must un-revert it in the same merge.
If it does not, the app ships calling `submit_player_rating` and
`get_player_rating` against a database where neither exists, and every rating
screen fails at runtime.

The pgTAP suite `supabase/tests/player_ratings_test.sql` is already on this
branch and covers the RPCs, so the check after merging is that this suite runs
green against the merged schema.

## 5. One request for Home

```sql
get_my_feed() returns json
```

Returns a single object:

```
{
  "workspaces":   [ ... same shape as get_my_workspaces ... ],
  "events":       [ ... same shape as get_workspace_events, across all workspaces ... ],
  "participants": [ { "event_id": uuid, ...ParticipantRecord fields }, ... ],
  "responses":    [ { "event_id": uuid, ...EventMemberResponseRecord fields }, ... ]
}
```

`events` is the query `get_workspace_events` already runs, with the workspace
filter replaced by membership:

```sql
where e.workspace_id in (
  select m.workspace_id from public.workspace_members m where m.user_id = v_uid
)
and coalesce(e.end_date, e.start_date) >= now()
```

`responses` is included only for workspaces the caller owns, matching the
`isOwner` branch that fetches them today. Apology reasons are private organizer
data and no other member receives them.

`HomeStore.loadAllTeamsData` becomes one call. The sequential loop over
workspaces, and the two task groups inside `loadTeamData`, are replaced by
mapping this single payload. `loadTeamData` is kept for the single workspace
refresh after a write, so nothing else changes.

Past exercises stay on `get_workspace_past_events`, which is already lazy and
paged.

## Migrations

Four files, dated after the branch's latest (`20260829120000`):

| file | contents |
|------|----------|
| `20260830100000_workspace_sport_enum.sql`   | enum type, `sport` column, backfill, generated `symbol`, RPC overloads |
| `20260830110000_event_lineups.sql`          | two tables, three RPCs |
| `20260830120000_feature_feedback.sql`       | table, one RPC |
| `20260830130000_get_my_feed.sql`            | the feed RPC |

Each ships a suite in the existing style, run with:

```
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/<name>_test.sql
```

* `workspace_sport_enum_test.sql`: backfill correctness for all eight symbols and
  for an unrecognised one, generated column agreement, both RPC overloads.
* `event_lineups_test.sql`: owner writes, non owner rejected, foreign participant
  rejected, duplicate id rejected, bad position rejected, draft invisible to a
  seat holder, published visible, non member sees null, cascade on participant
  removal, save after publish stays published.
* `feature_feedback_test.sql`: insert, upsert replaces rather than stacks, star
  and note bounds, table unreadable through PostgREST.
* `get_my_feed_test.sql`: only the caller's workspaces, responses present for
  owned workspaces and absent otherwise, shape matches `get_workspace_events`.

`supabase db reset` is broken on this machine, so the suites run against a
rebuilt schema rather than a reset.

## Swift changes

| file | change |
|------|--------|
| `Lineup.swift`             | three store functions become service calls; `LineupPositionStore` folds in |
| `LineupFlowView.swift`     | publish action |
| `LineupTeamPage.swift`     | reachable by seat holders once published |
| `SportArtLibrary.swift`    | keyed by sport enum; `ExerciseArtSeed` deleted |
| `SportPicker.swift`        | writes the enum |
| `FeatureFeedback.swift`    | submit goes through an RPC; quiet period stays local |
| `MockHomeFeed.swift`       | `loadAllTeamsData` becomes one `get_my_feed` call |
| `EventService.swift`       | new lineup, feedback and feed calls |
| `WorkspaceService.swift`   | sport on create and update |

## Out of scope

* The empty card for a sport with no photographs. Today's shipped artwork
  fallback stays.
* The duplicate fill notification implementations. This branch has
  `20260829110000_event_capacity_notifications.sql` and staging has
  `20260827110000_event_fill_notifications.sql`. Choosing between them is a
  merge decision that this spec does not make.
* Reading feedback inside the app.

## Risks

* Dropping and re-adding `symbol` as a generated column rewrites the workspaces
  table. The table is small, and the migration runs inside one transaction, so a
  failure leaves the original column in place.
* `get_my_feed` returns rosters for every upcoming exercise in every workspace.
  For a member of many large groups this payload is larger than any single
  request today, though smaller than the sum it replaces. If it grows a problem,
  the fix is a limit argument, not a return to per workspace fetching.
* This branch is sixteen commits behind staging. These migrations are dated
  after everything on both branches, so they apply cleanly either way, but the
  Swift files they touch overlap with staging's guest and waitlist work.
