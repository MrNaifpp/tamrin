import { supabase } from './supabase.js'
import { DEMO, demoRpc, demoAuth } from './fixture.js'

/// Every call below goes through a SECURITY DEFINER RPC that identifies the
/// caller with auth.uid(), exactly as the iOS services do — the web client
/// gets no privilege the app does not already have.
async function rpc(name, params) {
  // `?demo=1` answers every call from the local fixture, so the whole member
  // journey works with no project behind it.
  if (DEMO) return demoRpc(name, params)
  const { data, error } = await supabase.rpc(name, params)
  if (error) throw translate(error)
  return data
}

/// Postgres speaks English at the boundary; the person reading it does not.
/// Only the messages a member can actually provoke are worth translating —
/// anything else falls through with its own text, which is better than a
/// blanket «حدث خطأ» that hides what happened.
function translate(error) {
  const raw = String(error?.message ?? '')
  const known = [
    ['Not authenticated', 'انتهت جلستك. سجّل الدخول من جديد.'],
    ['Not a workspace member', 'أنت لست عضوًا في هذه المجموعة.'],
    ['Not authorized', 'ما عندك صلاحية لهذا الإجراء.'],
    ['Event not found', 'ما لقينا هذا الموعد.'],
    ['Event is not published', 'هذا الموعد ما انفتح للتسجيل بعد.'],
    ['Event is cancelled', 'هذا الموعد ملغى.'],
    ['Registration is closed', 'التسجيل مقفل في هذا الموعد.'],
    ['closes at capacity', 'هذا الموعد يقفل عند اكتمال العدد وما فيه قائمة انتظار.'],
    ['owner cannot decline', 'مشرف المجموعة ما يقدر يعتذر عن موعد يديره.'],
    ['Invalid invite code', 'رمز الدعوة غير صحيح.'],
    ['Failed to fetch', 'تعذر الاتصال بالخادم. تأكد من الشبكة.']
  ]
  const match = known.find(([needle]) => raw.includes(needle))
  const message = match ? match[1] : raw || 'صار خطأ غير متوقع.'
  const wrapped = new Error(message)
  wrapped.cause = error
  return wrapped
}

// ── Auth ──────────────────────────────────────────────────────────────────

export async function getSession() {
  if (DEMO) return demoAuth.session()
  const { data } = await supabase.auth.getSession()
  return data.session ?? null
}

export function onAuthChange(handler) {
  if (DEMO) return () => {}
  const { data } = supabase.auth.onAuthStateChange((_event, session) => handler(session))
  return () => data.subscription.unsubscribe()
}

/// Sends the six-digit code. The project's email template carries {{ .Token }}
/// because the app verifies a code rather than following a magic link, so the
/// same call serves both clients.
export async function requestOtp(email) {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: true }
  })
  if (error) throw translate(error)
}

export async function verifyOtp(email, token) {
  const { data, error } = await supabase.auth.verifyOtp({ email, token, type: 'email' })
  if (error) throw translate(error)
  return data.session
}

export async function signOut() {
  if (DEMO) return
  await supabase.auth.signOut()
}

// ── Profile (public.users) ────────────────────────────────────────────────

export async function getProfile(userId) {
  if (DEMO) return demoAuth.profile()
  const { data, error } = await supabase
    .from('users')
    .select('user_id, name, postion, avatar_url, stc_pay_number')
    .eq('user_id', userId)
    .limit(1)
  if (error) throw translate(error)
  return data?.[0] ?? null
}

/// Update first, insert only when nothing matched. `public.users` was created
/// by hand and its user_id carries no unique constraint in this project, so
/// upsert fails with 42P10 — the same reason AuthService.swift walks this way.
export async function saveProfile(userId, { name, position, avatarUrl = null }) {
  if (DEMO) return demoAuth.saveProfile({ name, position, avatarUrl })
  const payload = { name, postion: position, avatar_url: avatarUrl }
  const { data, error } = await supabase
    .from('users')
    .update(payload)
    .eq('user_id', userId)
    .select('user_id')
  if (error) throw translate(error)
  if (data?.length) return

  const { error: insertError } = await supabase
    .from('users')
    .insert({ user_id: userId, ...payload })
  if (insertError) throw translate(insertError)
}

// ── Workspaces ────────────────────────────────────────────────────────────

export const getMyWorkspaces = () => rpc('get_my_workspaces')
export const getWorkspace = (workspaceId) => rpc('get_workspace', { p_workspace_id: workspaceId })
export const getInvitePreview = (code) => rpc('get_workspace_by_invite', { p_code: code })
export const joinWorkspace = (code) => rpc('join_workspace', { p_code: code })
export const leaveWorkspace = (workspaceId) => rpc('leave_workspace', { p_workspace_id: workspaceId })

// ── Events ────────────────────────────────────────────────────────────────

export const getWorkspaceEvents = (workspaceId) =>
  rpc('get_workspace_events', { p_workspace_id: workspaceId })

export const getEventById = (eventId) => rpc('get_event_by_id', { p_event_id: eventId })

export const getEventParticipants = (eventId) =>
  rpc('get_event_participants', { p_event_id: eventId })

/// Takes a seat without paying for it: a paid exercise is joined first and
/// settled afterwards. Returns the server's status string — 'submitted',
/// 'waitlisted', 'already_joined', 'registration_closed_full', … — which the
/// screen reads rather than guessing from the roster.
export const registerEventSeat = (eventId, guestNames = [], expectedPricePerPerson = null) =>
  rpc('register_event_seat', {
    p_event_id: eventId,
    p_guest_names: guestNames,
    ...(expectedPricePerPerson == null ? {} : { p_expected_price_per_person: expectedPricePerPerson })
  })

/// The destination the member is asked to transfer to, plus the price snapshot
/// their own seat was taken at.
export const getEventPaymentDestination = (eventId) =>
  rpc('get_event_payment_destination', { p_event_id: eventId })

/// «حوّلت المبلغ» — stamps the member's seat and the guest seats they are
/// responsible for as declared, awaiting the organizer's confirmation.
export const declareEventPayment = (eventId, paymentMethodId) =>
  rpc('declare_event_payment', { p_event_id: eventId, p_payment_method_id: paymentMethodId })

export const leaveEvent = (eventId, userId) =>
  rpc('leave_event', { p_event_id: eventId, p_user_id: userId })

export const declineEvent = (eventId, reasonCode = null, reasonText = null) =>
  rpc('decline_event', {
    p_event_id: eventId,
    p_reason_code: reasonCode,
    p_reason_text: reasonText
  })

export const joinWaitlist = (eventId, userId) =>
  rpc('join_waitlist', { p_event_id: eventId, p_user_id: userId })

export const leaveWaitlist = (eventId, userId) =>
  rpc('leave_waitlist', { p_event_id: eventId, p_user_id: userId })
