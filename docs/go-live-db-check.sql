-- Go-live check: what production has of staging's database work since 2026-09-12.
-- Read-only. Run it in the SQL editor of BOTH projects (sandbox first, then
-- production) and compare the two results row by row. The sandbox has every
-- migration, so any row where production differs is something still to apply.
-- A function compares by a fingerprint of its body, not its name, because a
-- migration can be marked applied while an older body runs (see PR #27).

with funcs(name) as (values
  ('announce_event_fill'), ('announce_registration_opening_internal'),
  ('announce_registration_openings'), ('apply_workspace_registration_defaults'),
  ('begin_card_payment'), ('cancel_event_occurrence'), ('decline_event'),
  ('delete_web_push_subscription'), ('fire_refund_outbox'),
  ('generate_recurring_events'), ('get_event_participants'),
  ('get_event_registration_requests'), ('get_my_registration_request'),
  ('get_player_rating'), ('get_workspace_events'),
  ('guard_event_registration_insert'), ('guard_registration_settings'),
  ('hold_invites_until_registration_opens'), ('open_event_registration_now'),
  ('post_refund'), ('promote_from_waitlist'), ('register_event_guest_batch_impl'),
  ('register_event_seat'), ('registration_opens_at_for'), ('reject_payment'),
  ('remove_event_participant'), ('remove_my_guest'), ('request_refund'),
  ('reset_payment_declaration'), ('respond_registration_request'),
  ('retry_pending_refunds'), ('save_web_push_subscription'),
  ('seat_registration_request_internal'), ('settle_payment'), ('settle_refund'),
  ('submit_player_rating'), ('touch_updated_at'), ('unpaid_debt_event'),
  ('update_event_registration_settings'), ('withdraw_registration_request')
),
tabs(name) as (values
  ('payments'), ('workspace_moyasar_recipients'), ('moyasar_webhook_events'),
  ('refunds'), ('player_rating_changes'), ('event_registration_requests'),
  ('web_push_subscriptions')
)
select 'function' as kind,
       f.name || coalesce('(' || pg_get_function_identity_arguments(p.oid) || ')', '') as object,
       case when p.oid is null then 'MISSING' else left(md5(p.prosrc), 10) end as state
from funcs f
left join pg_proc p
  on p.proname = f.name and p.pronamespace = 'public'::regnamespace
union all
select 'table', t.name,
       case when to_regclass('public.' || t.name) is null then 'MISSING' else 'present' end
from tabs t
union all
select 'cron', jobname, schedule
from cron.job
union all
select 'migration', version, 'recorded'
from supabase_migrations.schema_migrations
where version >= '20260912'
order by 1, 2;
