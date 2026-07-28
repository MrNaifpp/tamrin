-- STC Pay: add stc_pay_number to users table.
-- Validated/normalized client-side (Swift) to +9665XXXXXXXX before save.

alter table public.users
  add column if not exists stc_pay_number text;

-- Optional index for any future lookup-by-number flows (not used in v1).
create index if not exists idx_users_stc_pay_number on public.users(stc_pay_number)
  where stc_pay_number is not null;
