-- The payment sweep's trigger. Every five minutes, if any MyFatoorah payment
-- has sat in `processing` for more than three, ask the payment-sweep function
-- to settle it from MyFatoorah's own answer. Same vault-held URL and secret
-- arrangement as post_refund; an unconfigured stack (local, CI) does nothing.

create or replace function public.retry_processing_payments()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url    text;
  v_secret text;
  v_count  int;
begin
  select count(*) into v_count
  from public.payments
  where status = 'processing'
    and provider = 'myfatoorah'
    and updated_at < now() - interval '3 minutes';

  if v_count = 0 then return 0; end if;

  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'payment_sweep_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'payment_sweep_secret';

  if v_url is null or v_url = '' then return 0; end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || coalesce(v_secret, '')),
    body    := '{}'::jsonb
  );
  return v_count;
end;
$$;

revoke execute on function public.retry_processing_payments() from public, anon, authenticated;
grant execute on function public.retry_processing_payments() to service_role;

-- Unschedule by name first: cron.schedule refuses a duplicate job name, and
-- this file is re-applied on every local rebuild.
do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'retry-processing-payments'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;

  perform cron.schedule(
    'retry-processing-payments',
    '*/5 * * * *',
    $cron$select public.retry_processing_payments();$cron$
  );
end;
$$;
