// Usage: PGLITE_MODULE=/path/to/pglite/dist/index.js node scripts/test-community-database.mjs
const {PGlite}=await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
import {readFileSync,readdirSync} from 'node:fs';
const root=new URL('../',import.meta.url).pathname;
const db=new PGlite();
await db.exec(`
create role anon; create role authenticated; create role service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
create schema auth; create schema extensions; create schema storage; create schema vault; create schema cron;
create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$ select (nullif(current_setting('request.jwt.claims',true),'')::json->>'sub')::uuid $$;
create function auth.role() returns text language sql stable as $$ select nullif(current_setting('request.jwt.claims',true),'')::json->>'role' $$;
create table vault.decrypted_secrets(name text,decrypted_secret text);
create table storage.buckets(id text primary key,name text,public boolean);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid);
create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
create table cron.job(jobid bigserial primary key,jobname text,schedule text,command text);
create function cron.schedule(text,text,text) returns bigint language plpgsql as $$ declare n bigint;begin insert into cron.job(jobname,schedule,command) values($1,$2,$3) returning jobid into n;return n;end $$;
create function cron.unschedule(bigint) returns boolean language sql as $$ delete from cron.job where jobid=$1 returning true $$;
`);
const names=readdirSync(root+'supabase/migrations').filter(n=>n.endsWith('.sql')&&!n.endsWith(' 2.sql')).sort();
// The original users table predates the checked-in migration history.
await db.exec(readFileSync(root+'supabase/migrations/20260131000000_baseline_users_table.sql','utf8'));
for(const name of names){
 const sql=readFileSync(root+'supabase/migrations/'+name,'utf8').replace(/create extension if not exists (pg_net|pg_cron) with schema extensions;/gi,'');
 try {await db.exec(sql);}catch(e){console.error('MIGRATION FAIL',name,e.message,e.where??'');await db.close();process.exit(1);}
}
console.log('PASS all '+names.length+' canonical migrations (network/cron adapters only)');
for(const name of ['player_ratings_test.sql','player_rating_changes_test.sql','create_event_goes_live_test.sql','get_my_feed_test.sql','variable_sessions_test.sql','recurring_events_test.sql']) {
 try {await db.exec(readFileSync(root+'supabase/tests/'+name,'utf8'));console.log('PASS '+name);}catch(e){console.error('TEST FAIL',name,e.message,e.where??'');await db.exec('rollback');process.exitCode=1;}
}
await db.close();
