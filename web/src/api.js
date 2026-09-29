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

/// What the person reads when the server refuses — ServerErrorMessage.swift,
/// line for line. A refusal a member can reach gets Arabic that says what to
/// do next; anything else gets the general apology, because an English
/// sentence from Postgres tells them nothing and reads as a crash.
export const GENERAL_ERROR = 'تعذر إكمال العملية. حاول مرة أخرى.'

const SERVER_MESSAGES = new Map([
  ['عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.', 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.'],
  ['Previous event payment is required', 'عندك قطة تمرين سابق ما أعلنت دفعها. افتح التمرين السابق واضغط «حوّلت المبلغ»، وبعدها تقدر تسجل.'],
  ['Event has ended', 'انتهى هذا التمرين.'],
  ['Event is cancelled', 'هذا التمرين ملغى.'],
  ['Registration is closed for this event', 'التسجيل مقفل في هذا الموعد.'],
  ['This event closes at capacity and has no waiting list', 'اكتمل العدد، وما فيه قائمة انتظار لهذا الموعد.'],
  ['Series has ended', 'انتهت هذه السلسلة.'],
  ['Pending guest request must be resolved before self registration', 'عندك طلب ضيوف معلّق. أنهِه قبل ما تسجل نفسك.'],
  ['A guest must be added by a workspace member', 'الضيف لازم يضيفه عضو في التمرين.'],
  ['Guest registration mode is required', 'اختر طريقة تسجيل الضيوف.'],
  ['Not authenticated', 'انتهت جلستك. سجّل الدخول مرة ثانية.'],
  ['Not a workspace member', 'ما أنت عضو في هذا التمرين.'],
  ['Player is not a workspace member', 'هذا اللاعب مو عضو في التمرين.'],
  ['Invalid invite link', 'رابط الدعوة غير صالح.'],
  ['Event not found', 'ما لقينا الموعد. حدّث الصفحة وحاول مرة أخرى.'],
  ['Exercise not found', 'ما لقينا التمرين. حدّث الصفحة وحاول مرة أخرى.'],
  ['Workspace not found', 'ما لقينا التمرين. حدّث الصفحة وحاول مرة أخرى.'],
  ['Template not found', 'ما لقينا قالب التمرين.'],
  ['Owner cannot leave the workspace; delete it instead', 'المشرف ما يقدر يغادر تمرينه. احذف التمرين بدل كذا.'],
  ['Owner cannot remove themselves; delete the workspace instead', 'المشرف ما يقدر يشيل نفسه. احذف التمرين بدل كذا.'],
  ['Event creator cannot leave their own event', 'ما تقدر تغادر موعدًا أنت منشئه.'],
  ['Workspace owner cannot decline an event they administer', 'ما تقدر تعتذر عن موعد أنت مشرفه.'],
  ['Workspace name is required', 'اسم التمرين مطلوب.'],
  ['Event name is required', 'اسم الموعد مطلوب.'],
  ['Event end must be after its start', 'وقت النهاية لازم يكون بعد وقت البداية.'],
  ['Total price cannot be negative', 'المبلغ ما يصير بالسالب.'],
  ['Player count must be greater than zero', 'عدد اللاعبين لازم يكون أكبر من صفر.'],
  ['Player count is required when total price is greater than zero', 'حدد عدد اللاعبين حتى نحسب قطة كل واحد.'],
  ['A payment method is required when total price is greater than zero', 'أضف طريقة دفع، لأن على التمرين قطة.'],
  ['Workspace sport symbol is invalid', 'اختر رياضة التمرين.'],
  ['Reason text is too long', 'السبب طويل. اختصره شوي.'],
  ['A valid Saudi mobile number is required', 'أدخل رقم جوال سعودي صحيح.'],
  ['A valid Saudi IBAN is required', 'أدخل آيبان سعودي صحيح.'],
  ['Account number must contain 6 to 24 digits', 'رقم الحساب لازم يكون من ٦ إلى ٢٤ رقمًا.'],
  ['Mobile wallet methods only accept a mobile number', 'محفظة الجوال تقبل رقم جوال فقط.'],
  ['Bank methods do not accept a mobile number', 'التحويل البنكي ما يقبل رقم جوال.'],
  ['Cash does not accept destination details', 'الدفع في الملعب ما يحتاج تفاصيل تحويل.'],
  ['Payment providers must be unique', 'ما ينفع تكرر نفس وسيلة الدفع.'],
  ['Unsupported payment provider', 'وسيلة الدفع هذي غير مدعومة.'],
  ['Unable to save payment method', 'ما قدرنا نحفظ طريقة الدفع. حاول مرة أخرى.'],
  ['Payment method does not belong to the event workspace', 'طريقة الدفع هذي مو تابعة لهذا التمرين.'],
  ['There is no lineup to publish yet', 'ما فيه تشكيلة تنشرها بعد.'],
  ['Every player in a lineup must hold a seat in this exercise', 'كل لاعب في التشكيلة لازم يكون مسجلًا في الموعد.'],
  ['A player cannot hold two places in one lineup', 'اللاعب ما يجي في الفريقين.'],
  ['Event not found or you are not the creator', 'ما لقينا الموعد، أو ما أنت منشئه.'],
  ['Event not found or you are not the workspace owner', 'ما لقينا الموعد، أو ما أنت مشرف التمرين.'],
  ['Event not found, cancelled, or you are not the workspace owner', 'ما لقينا الموعد، أو هو ملغى، أو ما أنت مشرف التمرين.'],
  ['Only a manually added registration can be removed this way', 'هذا التسجيل ما ينشال بهذي الطريقة. شيله من قائمة المسجلين.'],
  ['OWNS_SHARED_WORKSPACE', 'عندك تمرين فيه أعضاء آخرين. احذف التمرين أو انقل ملكيته أولًا، ثم احذف الحساب.'],
])

/// The server names the unpaid workout that blocks a registration in the
/// error's hint (guard_event_registration_insert), the same thing
/// PaymentOwed.swift reads on the phone.
const PAYMENT_OWED_PREFIX = 'payment_owed:'

export function arabicServerMessage(raw) {
  const message = String(raw ?? '').trim()
  if (!message) return GENERAL_ERROR
  if (SERVER_MESSAGES.has(message)) return SERVER_MESSAGES.get(message)
  if (message.startsWith('Not authorized') || message.startsWith('Only the ')) return 'هذا الإجراء للمشرف فقط.'
  if (message.startsWith('Not the ')) return 'هذا الإجراء لمنشئ التمرين فقط.'
  return GENERAL_ERROR
}

function translate(error) {
  const raw = String(error?.message ?? '')
  let message
  if (/Failed to fetch|NetworkError|Load failed/i.test(raw) || (typeof navigator !== 'undefined' && navigator.onLine === false)) {
    message = navigator.onLine === false
      ? 'ما فيه اتصال بالإنترنت. تأكد من الشبكة وحاول مرة أخرى.'
      : 'تعذر الاتصال بالخادم. حاول مرة أخرى.'
  } else {
    message = arabicServerMessage(raw)
  }
  const wrapped = new Error(message)
  wrapped.cause = error
  const hint = String(error?.hint ?? '')
  if (hint.startsWith(PAYMENT_OWED_PREFIX)) wrapped.paymentOwedEventId = hint.slice(PAYMENT_OWED_PREFIX.length)
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
  // The walkthrough must never send a real email, so the fixture answers here
  // too — its session is already signed in, but a stray call cannot escape.
  if (DEMO) return
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: true }
  })
  if (error) throw translate(error)
}

export async function verifyOtp(email, token) {
  if (DEMO) return demoAuth.session()
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

/// A guest this member added, taken back off the roster. The seat is freed
/// for the waiting list, and a card-paid seat is refunded before kickoff —
/// `refund_id` is set when money is on its way back.
export const removeMyGuest = (participantId) =>
  rpc('remove_my_guest', { p_participant_id: participantId })

// ── Home feed ─────────────────────────────────────────────────────────────

/// The whole shelf in one request: every group, every live workout across
/// them, their rosters and the member's own responses — the same call
/// EventService.getMyFeed makes on the phone.
export const getMyFeed = () => rpc('get_my_feed')

export const getWorkspacePastEvents = (workspaceId, limit = 60) =>
  rpc('get_workspace_past_events', { p_workspace_id: workspaceId, p_limit: limit })

// ── Lineup ────────────────────────────────────────────────────────────────

/// The split, once the organizer publishes it. Null for anyone without a seat
/// and for a draft — a player never sees a lineup that is still being made.
export const getEventLineup = (eventId) => rpc('get_event_lineup', { p_event_id: eventId })

// ── Card payments (Moyasar) ───────────────────────────────────────────────

/// Edge functions answer with a status the screen reads rather than an
/// exception; a non-2xx is a failure worth one sentence, not a stack.
async function invoke(name, body) {
  if (DEMO) return demoRpc(`fn:${name}`, body)
  const { data, error } = await supabase.functions.invoke(name, { body })
  if (error) {
    let payload = null
    try { payload = await error.context?.json?.() } catch {}
    if (payload?.status) return payload
    const status = error.context?.status
    throw new Error(status === 401 ? 'انتهت الجلسة. سجّل الدخول مرة أخرى.' : GENERAL_ERROR)
  }
  return data
}

/// Prices every unpaid seat the member is responsible for, on the server.
/// `ready` carries what the Moyasar form needs; `recipient_not_onboarded`
/// means the organizer takes transfers by hand, and the manual flow stands in.
export const createCardPayment = (eventId) => invoke('create-payment', { event_id: eventId })

export const verifyCardPayment = (paymentId, moyasarPaymentId) =>
  invoke('verify-payment', { payment_id: paymentId, moyasar_payment_id: moyasarPaymentId })

// ── Player ratings (football groups) ──────────────────────────────────────

/// The group's anonymous verdict on a player, and the caller's own when they
/// have given one. Rater ids never leave the server.
export const getPlayerRating = (workspaceId, userId) =>
  rpc('get_player_rating', { p_workspace_id: workspaceId, p_user_id: userId })

export const submitPlayerRating = (workspaceId, userId, values) =>
  rpc('submit_player_rating', {
    p_workspace_id: workspaceId,
    p_user_id: userId,
    p_pace: values.pace,
    p_passing: values.passing,
    p_shooting: values.shooting,
    p_stamina: values.stamina,
    p_defending: values.defending,
    p_awareness: values.awareness
  })

// ── Guests ────────────────────────────────────────────────────────────────

/// Guests alongside a seat the member already holds. On a paid exercise they
/// take their seats unpaid and are settled with the member's own payment.
export const registerEventGuests = (eventId, guestNames, expectedPricePerPerson = null) =>
  rpc('register_event_guests', {
    p_event_id: eventId,
    p_guest_names: guestNames,
    p_payment_method_id: null,
    p_expected_payment_method_id: null,
    p_expected_price_per_person: expectedPricePerPerson
  })

/// Guests without the member: «سجّل ضيف بدونك».
export const registerEventGuestOnly = (eventId, guestNames, expectedPricePerPerson = null) =>
  rpc('register_event_guest_only', {
    p_event_id: eventId,
    p_guest_names: guestNames,
    p_payment_method_id: null,
    p_expected_payment_method_id: null,
    p_expected_price_per_person: expectedPricePerPerson
  })
