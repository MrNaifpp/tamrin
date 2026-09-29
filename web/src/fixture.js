// A deterministic member journey that runs with no backend at all.
//
// Same idea as HomeDebugMemberFixture on iOS: open the site with `?demo=1`
// and every RPC is answered from memory, so the whole walk — the shelf and
// the archive, register, add and remove a guest, pay by card or by transfer,
// an older workout that blocks registering until it is paid, decline, the
// waiting list, a published lineup, rating a player — can be exercised on a
// laptop with no Supabase project, no email code, no card, and no risk of
// writing to a real group. The flag is sticky for the tab so navigation keeps it.

const FLAG_KEY = 'tamrin.demo'

function readFlag() {
  const params = new URLSearchParams(location.search)
  if (params.has('demo')) {
    const on = params.get('demo') !== '0'
    sessionStorage.setItem(FLAG_KEY, on ? '1' : '0')
    return on
  }
  return sessionStorage.getItem(FLAG_KEY) === '1'
}

export const DEMO = readFlag()

const ME = '11111111-1111-4111-8111-111111111111'
const OWNER = '22222222-2222-4222-8222-222222222222'
const FREE_WS = '33333333-3333-4333-8333-333333333333'
const PAID_WS = '99999999-9999-4999-8999-999999999999'
const OWED_WS = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const VOLLEY_WS = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'

const PAID_EVENT = '44444444-4444-4444-8444-444444444444'
const FREE_EVENT = '55555555-5555-4555-8555-555555555555'
const FULL_EVENT = '66666666-6666-4666-8666-666666666666'
const LINEUP_EVENT = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
const OWED_EVENT = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
const NEXT_OWED_EVENT = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
const VOLLEY_EVENT = 'f1f1f1f1-f1f1-4f1f-8f1f-f1f1f1f1f1f1'
const PAST_A = 'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1'
const PAST_B = 'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2'
const PAST_C = 'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3'

const STC_METHOD = '77777777-7777-4777-8777-777777777777'
const CASH_METHOD = '88888888-8888-4888-8888-888888888888'

const hoursFromNow = (hours) => new Date(Date.now() + hours * 3_600_000).toISOString()

let profile = { user_id: ME, name: 'فارس', postion: 'وسط', avatar_url: null, stc_pay_number: null }

const workspace = (fields) => ({
  owner_id: OWNER,
  image_url: null,
  color: 'lime',
  member_count: 14,
  created_at: hoursFromNow(-900),
  ...fields
})

// The groups HomeDebugMemberFixture builds on the phone, plus the two the
// newer walkthroughs need: an unpaid older workout, and a non-football sport.
const workspaces = [
  workspace({ id: FREE_WS, name: 'عضو: قبول فوري وتقييم', invite_code: 'DEMO-USER', sport: 'soccer', symbol: 'figure.soccer', member_count: 18 }),
  workspace({ id: PAID_WS, name: 'عضو: القطة والضيوف', invite_code: 'DEMO-PAID', sport: 'soccer', symbol: 'figure.soccer', color: 'orange', member_count: 16 }),
  workspace({ id: OWED_WS, name: 'عضو: قطة سابقة', invite_code: 'DEMO-OWED', sport: 'basketball', symbol: 'figure.basketball', color: 'red', member_count: 10 }),
  workspace({ id: VOLLEY_WS, name: 'طائرة الشاطئ', invite_code: 'DEMO-VOLL', sport: 'volleyball', symbol: 'figure.volleyball', color: 'blue', member_count: 12 })
]

const event = (fields) => ({
  creator_id: OWNER,
  description: '',
  image_url: null,
  registration_locked: false,
  total_price: 0,
  price_per_person: 0,
  latitude: null,
  longitude: null,
  payment_method_id: null,
  payment_method_ids: [],
  is_recurring: false,
  published_at: hoursFromNow(-40),
  is_published: true,
  cancelled_at: null,
  is_cancelled: false,
  cancellation_reason_code: null,
  cancellation_reason_text: null,
  my_response_status: null,
  capacity_policy: 'waitlist',
  requires_payment_action: false,
  ...fields
})

const events = [
  event({
    id: OWED_EVENT, workspace_id: OWED_WS, name: 'سلة الأسبوع الماضي',
    location: 'صالة الملقا', start_date: hoursFromNow(-52), end_date: hoursFromNow(-50.5),
    max_participants: 10, total_price: 300, price_per_person: 30,
    payment_method_id: CASH_METHOD, payment_method_ids: [STC_METHOD, CASH_METHOD],
    requires_payment_action: true
  }),
  event({
    id: PAID_EVENT, workspace_id: PAID_WS, name: 'مدفوع: جرّب القطة وإضافة ضيف',
    location: 'ملعب الندى', start_date: hoursFromNow(30), end_date: hoursFromNow(31.5),
    max_participants: 16, total_price: 480, price_per_person: 30, latitude: 24.82, longitude: 46.63,
    payment_method_id: STC_METHOD, payment_method_ids: [STC_METHOD, CASH_METHOD], is_recurring: true
  }),
  event({
    id: LINEUP_EVENT, workspace_id: FREE_WS, name: 'التشكيلة نزلت',
    location: 'ملعب الريان', start_date: hoursFromNow(40), end_date: hoursFromNow(41.5),
    max_participants: 12, latitude: 24.7, longitude: 46.68
  }),
  event({
    id: FREE_EVENT, workspace_id: FREE_WS, name: 'مجاني: سجّل ويتأكد فورًا',
    location: 'ملعب النخيل', start_date: hoursFromNow(54), end_date: hoursFromNow(55),
    max_participants: 18, latitude: 24.77, longitude: 46.72
  }),
  event({
    id: NEXT_OWED_EVENT, workspace_id: OWED_WS, name: 'سلة نص الأسبوع',
    location: 'صالة الملقا', start_date: hoursFromNow(64), end_date: hoursFromNow(65.5),
    max_participants: 10, total_price: 300, price_per_person: 30,
    payment_method_ids: [STC_METHOD, CASH_METHOD]
  }),
  event({
    id: FULL_EVENT, workspace_id: FREE_WS, name: 'مكتمل: جرّب قائمة الانتظار',
    location: 'ملعب الروابي', start_date: hoursFromNow(78), end_date: hoursFromNow(79.5),
    max_participants: 2
  }),
  event({
    id: VOLLEY_EVENT, workspace_id: VOLLEY_WS, name: 'طائرة مفتوحة على الرمل',
    location: 'شاطئ نصف القمر', start_date: hoursFromNow(90), end_date: hoursFromNow(92),
    max_participants: 12, cancelled_at: hoursFromNow(-2), is_cancelled: true,
    cancellation_reason_code: 'weather'
  })
]

const pastEvents = [
  event({ id: PAST_A, workspace_id: VOLLEY_WS, name: 'طائرة الأسبوع الماضي', location: 'شاطئ نصف القمر',
          start_date: hoursFromNow(-72), end_date: hoursFromNow(-70), max_participants: 12 }),
  event({ id: PAST_B, workspace_id: FREE_WS, name: 'كورة الخميس', location: 'ملعب النخيل',
          start_date: hoursFromNow(-240), end_date: hoursFromNow(-238.5), max_participants: 18 }),
  event({ id: PAST_C, workspace_id: PAID_WS, name: 'مدفوع: الجولة الأولى', location: 'ملعب الندى',
          start_date: hoursFromNow(-960), end_date: hoursFromNow(-958.5), max_participants: 16,
          cancelled_at: hoursFromNow(-970), is_cancelled: true })
]

let seq = 0
const seat = (fields) => ({
  participant_id: `seat-${String(++seq).padStart(4, '0')}`,
  user_id: null,
  joined_at: hoursFromNow(-6 + seq * 0.1),
  display_name: null,
  avatar_url: null,
  player_position: null,
  payment_status: 'confirmed',
  payment_provider: null,
  payment_declared_at: hoursFromNow(-5),
  payment_method_id: null,
  paid_to_number: null,
  paid_to_iban: null,
  paid_to_account_number: null,
  paid_price_per_person: null,
  payment_group_size: null,
  guest_name: null,
  added_by: null,
  added_manually: false,
  guest_only: false,
  payment_reminder_sent_at: null,
  is_waitlisted: false,
  ...fields
})

const CAST = [
  ['سلمان العتيبي', 'وسط'], ['عبدالعزيز القحطاني', 'هجوم'], ['تركي الشهري', 'دفاع'], ['ماجد الدوسري', 'حارس'],
  ['خالد الحربي', 'وسط'], ['نواف المطيري', 'دفاع'], ['ريان الزهراني', 'هجوم'], ['حمزة الغامدي', 'وسط'],
  ['ياسر العنزي', 'دفاع'], ['زياد السبيعي', 'هجوم']
]
const castSeat = ([name, position], i, extra = {}) =>
  seat({ user_id: `p${i}`, display_name: name, player_position: position, ...extra })

const rosters = {
  [PAID_EVENT]: [
    seat({ user_id: OWNER, display_name: 'نايف', player_position: 'هجوم' }),
    ...CAST.slice(0, 8).map((person, i) =>
      castSeat(person, i, {
        payment_status: i > 5 ? 'pending' : 'confirmed',
        payment_declared_at: i === 6 ? hoursFromNow(-2) : i > 5 ? null : hoursFromNow(-5)
      })
    ),
    seat({ guest_name: 'ضيف تركي', added_by: 'p2', payment_status: 'pending', payment_declared_at: null })
  ],
  [LINEUP_EVENT]: [
    seat({ user_id: OWNER, display_name: 'نايف', player_position: 'هجوم' }),
    seat({ user_id: ME, display_name: 'فارس', player_position: 'وسط' }),
    ...CAST.map((person, i) => castSeat(person, i))
  ],
  [FREE_EVENT]: CAST.map((person, i) => castSeat(person, i)),
  [FULL_EVENT]: [
    seat({ user_id: OWNER, display_name: 'نايف', player_position: 'هجوم' }),
    seat({ user_id: 'a1', display_name: 'مشعل', player_position: 'دفاع' }),
    seat({ user_id: 'a3', display_name: 'سلطان', is_waitlisted: true, payment_status: null, payment_declared_at: null })
  ],
  [OWED_EVENT]: [
    seat({ user_id: OWNER, display_name: 'نايف' }),
    seat({ user_id: ME, display_name: 'فارس', player_position: 'وسط', payment_status: 'pending', payment_declared_at: null,
           paid_price_per_person: 30, payment_group_size: 1 }),
    ...CAST.slice(0, 6).map((person, i) => castSeat(person, i))
  ],
  [NEXT_OWED_EVENT]: CAST.slice(0, 5).map((person, i) => castSeat(person, i, { payment_status: 'pending', payment_declared_at: null })),
  [VOLLEY_EVENT]: CAST.slice(0, 7).map((person, i) => castSeat(person, i))
}

/// The split on LINEUP_EVENT, published: the member is on the second side.
const lineupSeats = rosters[LINEUP_EVENT]
const lineups = {
  [LINEUP_EVENT]: {
    status: 'published',
    published_at: hoursFromNow(-1),
    updated_at: hoursFromNow(-1),
    first: [0, 2, 4, 6, 8, 10].map((i) => lineupSeats[i].participant_id),
    second: [1, 3, 5, 7, 9, 11].map((i) => lineupSeats[i].participant_id),
    positions: { [lineupSeats[5].participant_id]: 'goalkeeper' }
  }
}

const methods = {
  [STC_METHOD]: { payment_method_id: STC_METHOD, provider: 'stc_bank', mobile_number: '0551234567', iban: null, account_number: null },
  [CASH_METHOD]: { payment_method_id: CASH_METHOD, provider: 'cash', mobile_number: null, iban: null, account_number: null }
}

/// Ratings the member can reveal by giving their own.
const ratings = {}
const ATTRS = ['pace', 'passing', 'shooting', 'stamina', 'defending', 'awareness']
const seedAverage = (userId) => {
  const base = 55 + (String(userId).charCodeAt(1) % 30)
  return Object.fromEntries(ATTRS.map((key, i) => [key, Math.min(99, base + ((i * 7) % 13) - 4)]))
}

const eventById = (id) => events.find((e) => e.id === id) ?? pastEvents.find((e) => e.id === id)
const rosterOf = (id) => (rosters[id] ??= [])
const mySeat = (id) => rosterOf(id).find((row) => row.user_id === ME && !row.guest_name && !row.is_waitlisted)
const liveSeats = (id) => rosterOf(id).filter((row) => !row.is_waitlisted)
const isOver = (e) => new Date(e.end_date ?? e.start_date).getTime() < Date.now()
const myPending = (id) => rosterOf(id).filter((row) => (row.user_id === ME || row.added_by === ME) && row.payment_status === 'pending')

/// guard_event_registration_insert: an ended, unpaid workout in the same
/// group refuses the insert and names itself in the hint.
function guardDebt(eventId) {
  const target = eventById(eventId)
  const owed = events.find((e) => e.workspace_id === target.workspace_id && e.id !== eventId &&
    !e.cancelled_at && isOver(e) && myPending(e.id).length)
  if (!owed) return
  const error = new Error('عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.')
  error.paymentOwedEventId = owed.id
  throw error
}

/// A demo payment settles every pending seat the member is responsible for.
function settle(eventId) {
  myPending(eventId).forEach((row) => { row.payment_status = 'confirmed'; row.payment_declared_at = hoursFromNow(0) })
  const e = eventById(eventId)
  if (e) e.requires_payment_action = false
}

const payments = {}

export const demoAuth = {
  session: () => ({ user: { id: ME, email: 'demo@tamrien.app', user_metadata: {} } }),
  profile: () => profile,
  saveProfile: (fields) => {
    profile = { ...profile, name: fields.name, postion: fields.position, avatar_url: fields.avatarUrl ?? null }
  }
}

function feedEvents() {
  return events.filter((e) => !isOver(e) || (!e.cancelled_at && myPending(e.id).length))
    .map((e) => ({ ...e, requires_payment_action: isOver(e) && !e.cancelled_at && myPending(e.id).length > 0 }))
}

/// Answers an RPC out of the fixture. Unknown names throw, so a call this
/// walkthrough has not thought about is loud rather than silently empty.
export function demoRpc(name, params = {}) {
  switch (name) {
    case 'get_my_workspaces':
      return workspaces
    case 'get_my_feed': {
      const list = feedEvents()
      return {
        workspaces,
        events: list,
        participants: list.flatMap((e) => rosterOf(e.id).map((row) => ({ ...row, event_id: e.id }))),
        responses: []
      }
    }
    case 'get_workspace_past_events':
      return pastEvents.filter((e) => e.workspace_id === params.p_workspace_id)
    case 'get_workspace': {
      const found = workspaces.find((w) => w.id === params.p_workspace_id) ?? workspaces[0]
      return {
        workspace: found,
        members: [
          { user_id: OWNER, display_name: 'نايف', avatar_url: null, postion: 'هجوم', is_owner: true },
          { user_id: ME, display_name: profile.name, avatar_url: null, postion: profile.postion, is_owner: false },
          ...CAST.map(([memberName, position], i) => ({
            user_id: `p${i}`, display_name: memberName, avatar_url: null, postion: position, is_owner: false
          }))
        ]
      }
    }
    case 'get_workspace_events':
      return feedEvents().filter((e) => e.workspace_id === params.p_workspace_id)
    case 'get_event_by_id':
      return eventById(params.p_event_id)
    case 'get_event_participants':
      return rosterOf(params.p_event_id)
    case 'get_event_lineup':
      return mySeat(params.p_event_id) ? lineups[params.p_event_id] ?? null : null
    case 'get_event_payment_destination': {
      const e = eventById(params.p_event_id)
      const mine = mySeat(e.id)
      if (mine?.payment_method_id) {
        const method = methods[mine.payment_method_id]
        return {
          status: 'available', provider: method.provider, payment_method_id: method.payment_method_id,
          mobile_number: method.mobile_number, iban: null, account_number: null, payment_methods: [],
          total_price: e.total_price, price_per_person: mine.paid_price_per_person, group_size: mine.payment_group_size
        }
      }
      if (e.total_price <= 0) return { status: 'free', payment_methods: [] }
      return {
        status: 'available', provider: null, payment_method_id: null,
        payment_methods: e.payment_method_ids.map((id) => methods[id]),
        total_price: e.total_price, price_per_person: e.price_per_person, group_size: null
      }
    }
    case 'register_event_seat': {
      const e = eventById(params.p_event_id)
      if (mySeat(e.id)) return { status: 'already_joined', payment_status: 'pending' }
      guardDebt(e.id)
      const guests = (params.p_guest_names ?? []).map((raw) => raw.trim()).filter(Boolean)
      const groupSize = 1 + guests.length
      const paid = e.total_price > 0
      if (e.max_participants != null && liveSeats(e.id).length + groupSize > e.max_participants) {
        if (e.capacity_policy === 'closed') return { status: 'registration_closed_full' }
        rosterOf(e.id).push(seat({
          participant_id: ME, user_id: ME, display_name: profile.name, player_position: profile.postion,
          is_waitlisted: true, payment_status: null, payment_declared_at: null
        }))
        return { status: 'waitlisted', group_size: 1 }
      }
      rosterOf(e.id).push(seat({
        user_id: ME, display_name: profile.name, player_position: profile.postion, joined_at: hoursFromNow(0),
        payment_status: paid ? 'pending' : 'confirmed', payment_declared_at: paid ? null : hoursFromNow(0),
        paid_price_per_person: e.price_per_person, payment_group_size: groupSize
      }))
      guests.forEach((guestName) => rosterOf(e.id).push(seat({
        guest_name: guestName, added_by: ME, joined_at: hoursFromNow(0),
        payment_status: paid ? 'pending' : 'confirmed', payment_declared_at: paid ? null : hoursFromNow(0),
        paid_price_per_person: e.price_per_person
      })))
      e.my_response_status = null
      return { status: 'submitted', group_size: groupSize, requires_payment: paid }
    }
    case 'register_event_guests':
    case 'register_event_guest_only': {
      const e = eventById(params.p_event_id)
      const guests = (params.p_guest_names ?? []).map((raw) => raw.trim()).filter(Boolean)
      if (!guests.length) return { status: 'empty_guests' }
      if (name === 'register_event_guests' && !mySeat(e.id)) return { status: 'not_registered' }
      if (name === 'register_event_guest_only' && mySeat(e.id)) return { status: 'self_already_registered' }
      guardDebt(e.id)
      if (e.max_participants != null && liveSeats(e.id).length + guests.length > e.max_participants) return { status: 'seats_full' }
      const paid = e.total_price > 0
      guests.forEach((guestName) => rosterOf(e.id).push(seat({
        guest_name: guestName, added_by: ME, joined_at: hoursFromNow(0), guest_only: name === 'register_event_guest_only',
        payment_status: paid ? 'pending' : 'confirmed', payment_declared_at: paid ? null : hoursFromNow(0),
        paid_price_per_person: e.price_per_person
      })))
      return { status: 'submitted', group_size: guests.length }
    }
    case 'remove_my_guest': {
      const list = Object.values(rosters).find((rows) => rows.some((row) => row.participant_id === params.p_participant_id))
      if (!list) return { status: 'not_found', refund_id: null }
      const index = list.findIndex((row) => row.participant_id === params.p_participant_id)
      const [row] = list.splice(index, 1)
      return { status: 'removed', refund_id: row.payment_status === 'confirmed' ? 'demo-refund' : null }
    }
    case 'declare_event_payment': {
      const e = eventById(params.p_event_id)
      const method = methods[params.p_payment_method_id]
      const due = myPending(e.id).filter((row) => !row.payment_declared_at)
      if (!due.length) return { status: 'nothing_due' }
      due.forEach((row) => {
        row.payment_declared_at = hoursFromNow(0)
        row.payment_method_id = method.payment_method_id
        row.payment_provider = method.provider
        row.paid_to_number = method.mobile_number
      })
      return { status: 'declared', seats: due.length }
    }
    case 'decline_event': {
      const e = eventById(params.p_event_id)
      rosters[e.id] = rosterOf(e.id).filter((row) => row.user_id !== ME && row.added_by !== ME)
      e.my_response_status = 'declined'
      return { status: 'declined' }
    }
    case 'join_waitlist':
      guardDebt(params.p_event_id)
      rosterOf(params.p_event_id).push(seat({
        participant_id: ME, user_id: ME, display_name: profile.name,
        is_waitlisted: true, payment_status: null, payment_declared_at: null
      }))
      return { status: 'joined' }
    case 'leave_waitlist':
      rosters[params.p_event_id] = rosterOf(params.p_event_id).filter((row) => !(row.user_id === ME && row.is_waitlisted))
      return { status: 'left' }
    case 'get_player_rating': {
      const key = `${params.p_workspace_id}:${params.p_user_id}`
      const record = ratings[key]
      const person = CAST.find((_, i) => `p${i}` === params.p_user_id)
      const position = params.p_user_id === ME ? profile.postion : person?.[1] ?? 'هجوم'
      const average = seedAverage(params.p_user_id)
      const overallOf = (values) => Math.round(ATTRS.reduce((sum, k) => sum + values[k], 0) / ATTRS.length)
      return {
        position,
        has_rated: Boolean(record),
        ratings_count: 4 + (record ? 1 : 0),
        mine: record ? { ...record, overall: overallOf(record), updated_at: hoursFromNow(0) } : null,
        average: { ...average, overall: overallOf(average) }
      }
    }
    case 'submit_player_rating': {
      if (params.p_user_id === ME) return { status: 'is_self' }
      ratings[`${params.p_workspace_id}:${params.p_user_id}`] = {
        pace: params.p_pace, passing: params.p_passing, shooting: params.p_shooting,
        stamina: params.p_stamina, defending: params.p_defending, awareness: params.p_awareness
      }
      return { status: 'saved', rating: demoRpc('get_player_rating', params) }
    }
    // Edge functions, answered the same way.
    case 'fn:create-payment': {
      const e = eventById(params.event_id)
      const due = myPending(e.id)
      if (!due.length) return { status: 'nothing_due' }
      // The unpaid basketball group takes transfers by hand; the paid football
      // group has a verified recipient and takes cards.
      if (e.workspace_id === OWED_WS) return { status: 'recipient_not_onboarded' }
      const id = `pay-${e.id.slice(0, 8)}`
      payments[id] = e.id
      return {
        status: 'ready', payment_id: id, given_id: `given-${id}`,
        amount: Math.round(Number(e.price_per_person) * 100) * due.length, currency: 'SAR', seat_count: due.length,
        publishable_key: 'pk_test_demo', description: `تمرين: ${e.name}`,
        metadata: { payment_id: id, event_id: e.id, user_id: ME }, splits: []
      }
    }
    case 'fn:verify-payment': {
      const eventId = payments[params.payment_id]
      if (!eventId) return { status: 'failed', reason: 'status' }
      settle(eventId)
      return { status: 'paid' }
    }
    case 'get_workspace_by_invite':
      return { id: FREE_WS, name: workspaces[0].name, owner_name: 'نايف', member_count: 14, is_member: true }
    case 'join_workspace':
      return { workspace_id: FREE_WS }
    default:
      throw new Error(`نداء غير مغطى في وضع التجربة: ${name}`)
  }
}
