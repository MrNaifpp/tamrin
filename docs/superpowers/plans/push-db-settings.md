# Push DB settings (run per environment — NOT committed as a migration)

These set the function URL + shared secret the trigger reads via `current_setting`.
They contain a secret, so they live here as an ops runbook rather than in a
committed migration.

> After any `ALTER DATABASE ... SET`, open a **new** DB connection for the
> setting to take effect (existing sessions keep their old GUCs).

## Local

```sql
alter database postgres set app.send_push_url = 'http://host.docker.internal:54321/functions/v1/send-push';
alter database postgres set app.send_push_secret = 'local-dev-secret';
```

Run via:
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "alter database postgres set app.send_push_url = 'http://host.docker.internal:54321/functions/v1/send-push';"
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c \
  "alter database postgres set app.send_push_secret = 'local-dev-secret';"
```

## Staging (run against the staging DB)

```sql
alter database postgres set app.send_push_url = 'https://kpcdinxusxycenfnitjc.supabase.co/functions/v1/send-push';
alter database postgres set app.send_push_secret = '<same value as the SEND_PUSH_SECRET function secret>';
```

The `app.send_push_secret` value MUST match the `SEND_PUSH_SECRET` Edge Function
secret, or the function will reject the trigger's call with 401.
