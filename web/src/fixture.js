// A deterministic member journey that runs with no backend at all.
//
// Same idea as HomeDebugMemberFixture on iOS: open the site with `?demo=1`
// and every RPC is answered from memory, so the whole walk — register, add a
// guest, declare payment, decline, waiting list — can be exercised on a
// laptop with no Supabase project, no email code, and no risk of writing to
// a real group. The flag is sticky for the tab so navigation keeps it.

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
const WORKSPACE = '33333333-3333-4333-8333-333333333333'
const PAID_WORKSPACE = '99999999-9999-4999-8999-999999999999'
const PAID_EVENT = '44444444-4444-4444-8444-444444444444'
const FREE_EVENT = '55555555-5555-4555-8555-555555555555'
const FULL_EVENT = '66666666-6666-4666-8666-666666666666'
const STC_METHOD = '77777777-7777-4777-8777-777777777777'
const CASH_METHOD = '88888888-8888-4888-8888-888888888888'

const hoursFromNow = (hours) => new Date(Date.now() + hours * 3_600_000).toISOString()

let profile = { user_id: ME, name: 'فارس', postion: 'وسط', avatar_url: null, stc_pay_number: null }

// The same three groups HomeDebugMemberFixture builds on the phone, so a
// walkthrough here and a walkthrough there land on the same screens.
const workspaces = [
  {
    id: WORKSPACE,
    name: '١ — عضو: قبول فوري',
    owner_id: OWNER,
    invite_code: 'DEMO-USER',
    image_url: null,
    symbol: 'figure.soccer',
    color: '#c2eb63',
    member_count: 18
  },
  {
    id: PAID_WORKSPACE,
    name: '٢ — عضو: القطة والضيوف',
    owner_id: OWNER,
    invite_code: 'DEMO-PAID',
    image_url: null,
    symbol: 'person.3.fill',
    color: '#f28b30',
    member_count: 16
  }
]

const events = [
  {
    id: PAID_EVENT,
    creator_id: OWNER,
    workspace_id: PAID_WORKSPACE,
    name: 'مدفوع — جرّب القطة وإضافة ضيف',
    location: 'ملعب الندى',
    description: 'نلعب ساعة ونص، والحضور قبل الموعد بعشر دقائق.',
    start_date: hoursFromNow(30),
    end_date: hoursFromNow(31.5),
    image_url: null,
    max_participants: 16,
    registration_locked: false,
    total_price: 480,
    price_per_person: 30,
    latitude: 24.82,
    longitude: 46.63,
    payment_method_id: STC_METHOD,
    payment_method_ids: [STC_METHOD, CASH_METHOD],
    is_recurring: true,
    published_at: hoursFromNow(-40),
    cancelled_at: null,
    my_response_status: null,
    capacity_policy: 'waitlist'
  },
  {
    id: FREE_EVENT,
    creator_id: OWNER,
    workspace_id: WORKSPACE,
    name: 'مجاني — سجّل ويتأكد فورًا',
    location: 'ملعب النخيل',
    description: '',
    start_date: hoursFromNow(54),
    end_date: hoursFromNow(55),
    image_url: null,
    max_participants: 18,
    registration_locked: false,
    total_price: 0,
    price_per_person: 0,
    latitude: 24.77,
    longitude: 46.72,
    payment_method_id: null,
    payment_method_ids: [],
    is_recurring: false,
    published_at: hoursFromNow(-20),
    cancelled_at: null,
    my_response_status: null,
    capacity_policy: 'waitlist'
  },
  {
    id: FULL_EVENT,
    creator_id: OWNER,
    workspace_id: WORKSPACE,
    name: 'مكتمل — جرّب قائمة الانتظار',
    location: 'ملعب الروابي',
    description: '',
    start_date: hoursFromNow(78),
    end_date: hoursFromNow(79.5),
    image_url: null,
    max_participants: 2,
    registration_locked: false,
    total_price: 0,
    price_per_person: 0,
    latitude: null,
    longitude: null,
    payment_method_id: null,
    payment_method_ids: [],
    is_recurring: false,
    published_at: hoursFromNow(-10),
    cancelled_at: null,
    my_response_status: null,
    capacity_policy: 'waitlist'
  }
]

let seq = 0
const seat = (fields) => ({
  participant_id: `seat-${++seq}`,
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
  ['سلمان', 'وسط'], ['عبدالعزيز', 'مهاجم'], ['تركي', 'مدافع'], ['ماجد', 'حارس'],
  ['خالد', 'وسط'], ['نواف', 'مدافع'], ['ريان', 'مهاجم'], ['حمزة', 'وسط'],
  ['ياسر', 'مدافع'], ['زياد', 'مهاجم']
]

const rosters = {
  [PAID_EVENT]: [
    seat({ user_id: OWNER, display_name: 'نايف', player_position: 'هجوم' }),
    ...CAST.slice(0, 8).map(([name, position], i) =>
      seat({
        user_id: `p${i}`,
        display_name: name,
        player_position: position,
        payment_status: i > 5 ? 'pending' : 'confirmed',
        payment_declared_at: i > 5 ? null : hoursFromNow(-5)
      })
    ),
    seat({ guest_name: 'ضيف تركي', added_by: 'p2', payment_status: 'pending', payment_declared_at: null })
  ],
  [FREE_EVENT]: CAST.map(([name, position], i) =>
    seat({ user_id: `f${i}`, display_name: name, player_position: position })
  ),
  [FULL_EVENT]: [
    seat({ user_id: OWNER, display_name: 'نايف', player_position: 'هجوم' }),
    seat({ user_id: 'a1', display_name: 'مشعل', player_position: 'دفاع' }),
    seat({ user_id: 'a3', display_name: 'سلطان', is_waitlisted: true, payment_status: null, payment_declared_at: null })
  ]
}

const methods = {
  [STC_METHOD]: { payment_method_id: STC_METHOD, provider: 'stc_bank', mobile_number: '0551234567', iban: null, account_number: null },
  [CASH_METHOD]: { payment_method_id: CASH_METHOD, provider: 'cash', mobile_number: null, iban: null, account_number: null }
}

const eventById = (id) => events.find((event) => event.id === id)
const rosterOf = (id) => (rosters[id] ??= [])
const mySeat = (id) => rosterOf(id).find((row) => row.user_id === ME && !row.is_waitlisted)
const liveSeats = (id) => rosterOf(id).filter((row) => !row.is_waitlisted)

export const demoAuth = {
  session: () => ({ user: { id: ME, email: 'demo@tamrin.app', user_metadata: {} } }),
  profile: () => profile,
  saveProfile: (fields) => {
    profile = { ...profile, name: fields.name, postion: fields.position, avatar_url: fields.avatarUrl ?? null }
  }
}

/// Answers an RPC out of the fixture. Unknown names throw, so a call this
/// walkthrough has not thought about is loud rather than silently empty.
export function demoRpc(name, params = {}) {
  switch (name) {
    case 'get_my_workspaces':
      return workspaces
    case 'get_workspace': {
      const workspace = workspaces.find((w) => w.id === params.p_workspace_id) ?? workspaces[0]
      return {
        workspace,
        members: [
          { user_id: OWNER, display_name: 'نايف', avatar_url: null, postion: 'هجوم', is_owner: true },
          { user_id: ME, display_name: profile.name, avatar_url: null, postion: profile.postion, is_owner: false },
          ...CAST.map(([name, position], i) => ({
            user_id: `m${i}`, display_name: name, avatar_url: null, postion: position, is_owner: false
          }))
        ]
      }
    }
    case 'get_workspace_events':
      return events.filter((event) => event.workspace_id === params.p_workspace_id)
    case 'get_event_by_id':
      return eventById(params.p_event_id)
    case 'get_event_participants':
      return rosterOf(params.p_event_id)
    case 'get_event_payment_destination': {
      const event = eventById(params.p_event_id)
      const mine = mySeat(event.id)
      if (mine?.payment_method_id) {
        return {
          status: 'available',
          provider: methods[mine.payment_method_id].provider,
          payment_method_id: mine.payment_method_id,
          mobile_number: methods[mine.payment_method_id].mobile_number,
          iban: null,
          account_number: null,
          payment_methods: [],
          total_price: event.total_price,
          price_per_person: mine.paid_price_per_person,
          group_size: mine.payment_group_size
        }
      }
      if (event.total_price <= 0) return { status: 'free', payment_methods: [] }
      return {
        status: 'available',
        provider: null,
        payment_method_id: null,
        payment_methods: event.payment_method_ids.map((id) => methods[id]),
        total_price: event.total_price,
        price_per_person: event.price_per_person,
        group_size: null
      }
    }
    case 'register_event_seat': {
      const event = eventById(params.p_event_id)
      if (mySeat(event.id)) return { status: 'already_joined', payment_status: 'pending' }
      const guests = (params.p_guest_names ?? []).map((raw) => raw.trim()).filter(Boolean)
      const groupSize = 1 + guests.length
      const paid = event.total_price > 0
      if (event.max_participants != null && liveSeats(event.id).length + groupSize > event.max_participants) {
        rosterOf(event.id).push(seat({
          participant_id: ME, user_id: ME, display_name: profile.name, player_position: profile.postion,
          is_waitlisted: true, payment_status: null, payment_declared_at: null
        }))
        return { status: 'waitlisted', group_size: 1 }
      }
      rosterOf(event.id).push(seat({
        user_id: ME,
        display_name: profile.name,
        player_position: profile.postion,
        payment_status: paid ? 'pending' : 'confirmed',
        payment_declared_at: paid ? null : hoursFromNow(0),
        paid_price_per_person: event.price_per_person,
        payment_group_size: groupSize
      }))
      guests.forEach((guestName) =>
        rosterOf(event.id).push(seat({
          guest_name: guestName,
          added_by: ME,
          payment_status: paid ? 'pending' : 'confirmed',
          payment_declared_at: paid ? null : hoursFromNow(0),
          paid_price_per_person: event.price_per_person
        }))
      )
      return { status: 'submitted', group_size: groupSize, requires_payment: paid }
    }
    case 'declare_event_payment': {
      const event = eventById(params.p_event_id)
      const method = methods[params.p_payment_method_id]
      const due = rosterOf(event.id).filter(
        (row) => (row.user_id === ME || row.added_by === ME) && row.payment_status === 'pending' && !row.payment_declared_at
      )
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
      const event = eventById(params.p_event_id)
      rosters[event.id] = rosterOf(event.id).filter((row) => row.user_id !== ME && row.added_by !== ME)
      event.my_response_status = 'declined'
      return { status: 'declined' }
    }
    case 'join_waitlist':
      rosterOf(params.p_event_id).push(seat({
        participant_id: ME, user_id: ME, display_name: profile.name,
        is_waitlisted: true, payment_status: null, payment_declared_at: null
      }))
      return { status: 'joined' }
    case 'leave_waitlist':
      rosters[params.p_event_id] = rosterOf(params.p_event_id).filter(
        (row) => !(row.user_id === ME && row.is_waitlisted)
      )
      return { status: 'left' }
    case 'get_workspace_by_invite':
      return { id: WORKSPACE, name: workspaces[0].name, owner_name: 'نايف', member_count: 14, is_member: true }
    case 'join_workspace':
      return { workspace_id: WORKSPACE }
    default:
      throw new Error(`نداء غير مغطى في وضع التجربة: ${name}`)
  }
}
