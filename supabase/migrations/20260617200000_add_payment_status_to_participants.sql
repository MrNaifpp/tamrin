-- STC Pay: add payment_status + paid_to_number to event_participants.
--
-- payment_status:
--   'confirmed' — free event join, or paid join after creator confirmation.
--   'pending'   — paid event submission awaiting creator confirmation.
--   'rejected'  — terminal; rejected rows are deleted in v1, not kept. Kept in
--                 the check constraint so a future v2 can soft-delete instead.
--
-- paid_to_number is a snapshot of the creator's stc_pay_number at submit time,
-- so the creator's pending inbox always shows the number the joiner actually
-- paid to even if the creator changes their profile number later.

alter table public.event_participants
  add column if not exists payment_status text not null default 'confirmed'
    check (payment_status in ('pending', 'confirmed', 'rejected')),
  add column if not exists paid_to_number text;

create index if not exists idx_event_participants_status
  on public.event_participants(event_id, payment_status);
