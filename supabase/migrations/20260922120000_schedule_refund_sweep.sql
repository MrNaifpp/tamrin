-- The refund sweep's schedule, in a migration of its own.
--
-- It started life inside 20260922110000, which had already been applied to the
-- sandbox by the time the schedule was added. Supabase records a migration by
-- its version and never re-runs it, so editing that file could not deliver
-- this. A new version can, on every environment, with no hand-run SQL.
--
-- Unschedule by name first: this file is re-applied on every local rebuild, and
-- cron.schedule refuses a duplicate job name. Same shape as recurring-events.
do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'retry-pending-refunds'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;

  perform cron.schedule(
    'retry-pending-refunds',
    '*/5 * * * *',
    $cron$select public.retry_pending_refunds();$cron$
  );
end;
$$;
