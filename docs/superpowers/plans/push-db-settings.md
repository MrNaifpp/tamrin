# Push DB settings (run per environment — NOT committed as a migration)

The trigger (`fire_push_outbox`) reads the function URL + shared secret from
**Supabase Vault** (hosted Supabase forbids `ALTER DATABASE ... SET` for custom
GUCs because `postgres` is not a superuser there). Store two Vault secrets named
`send_push_url` and `send_push_secret`. Run these in the Dashboard SQL Editor.

> The `send_push_secret` value MUST match the `SEND_PUSH_SECRET` Edge Function
> secret, or the function rejects the trigger's call with 401.

## Verify Vault is reachable (optional sanity check)

```sql
select vault.create_secret('ok', 'tmp_vault_test');
select decrypted_secret from vault.decrypted_secrets where name = 'tmp_vault_test';
-- expect: 'ok'   then clean up:
delete from vault.secrets where name = 'tmp_vault_test';
```

## Store the secrets (first time)

```sql
select vault.create_secret(
  'https://kpcdinxusxycenfnitjc.supabase.co/functions/v1/send-push',
  'send_push_url'
);
select vault.create_secret(
  '<your SEND_PUSH_SECRET value>',
  'send_push_secret'
);
```

## Update an existing secret (re-runs)

`vault.create_secret` errors if the name already exists. To change a value:

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'send_push_secret'),
  '<new value>'
);
```

## Local

Local Supabase ships Vault too; use the same `vault.create_secret` calls but with
the local function URL `http://host.docker.internal:54321/functions/v1/send-push`
and `send_push_secret` = `local-dev-secret`.
