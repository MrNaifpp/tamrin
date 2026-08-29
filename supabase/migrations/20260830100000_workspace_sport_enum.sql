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
