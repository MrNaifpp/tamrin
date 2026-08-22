import { html, useState, useEffect, useCallback } from '../../vendor/preact.js'
import {
  getEventById, getEventParticipants, getEventPaymentDestination,
  leaveWaitlist, joinWaitlist, getMyWorkspaces
} from '../api.js'
import { goBack, navigate } from '../router.js'
import { Spinner, Icon, Toast, RowCard, artFor } from '../ui.js'
import { parseDate, arabicDay, arabicTime, counted, NOUNS } from '../format.js'
import { APP_STORE_URL } from '../config.js'
import { DeclineSheet } from './decline.js'
import { RegistrationSheet } from './registration.js'

/// EventHeroDetailView: artwork at the top, then one panel carrying its own
/// frost, so no card is ever left sitting on bare artwork.
export function EventScreen({ eventId, entry, session, profile }) {
  const userId = session.user.id
  const [event, setEvent] = useState(null)
  const [roster, setRoster] = useState(null)
  const [destination, setDestination] = useState(null)
  const [ownedWorkspaces, setOwnedWorkspaces] = useState([])
  const [error, setError] = useState(null)
  const [toast, setToast] = useState(null)
  const [sheet, setSheet] = useState(null)
  const [busy, setBusy] = useState(false)
  const [handledEntry, setHandledEntry] = useState(false)
  // Where the panel's top edge currently sits, so its frost dissolves in at
  // the panel's own edge rather than at a fixed point on the screen — the
  // same thing panelTop does on the phone.
  const [panelTop, setPanelTop] = useState(300)

  useEffect(() => {
    const onScroll = () => setPanelTop(Math.max(300 - window.scrollY, 0))
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  const load = useCallback(async () => {
    const record = await getEventById(eventId)
    setEvent(record)
    const [rows, payment] = await Promise.all([
      getEventParticipants(eventId).catch(() => null),
      Number(record.total_price ?? 0) > 0
        ? getEventPaymentDestination(eventId).catch(() => null)
        : Promise.resolve(null)
    ])
    setRoster(rows)
    setDestination(payment)
    return { record, rows }
  }, [eventId])

  useEffect(() => {
    let live = true
    load()
      .then(({ record, rows }) => {
        if (!live || handledEntry || !entry) return
        setHandledEntry(true)
        const mine = rows?.find((row) => row.user_id === userId && !row.is_waitlisted)
        // The card's own button opens the same sheet it would have taken two
        // taps to reach — «سجّل حضورك» lands on registration, «دفع القطة» on
        // the transfer.
        if (entry === 'register' && !mine) setSheet('register')
        if (entry === 'pay' && mine) setSheet('pay')
      })
      .catch((failure) => live && setError(failure.message))
    getMyWorkspaces()
      .then((list) => live && setOwnedWorkspaces(list.filter((w) => w.owner_id === userId).map((w) => w.id)))
      .catch(() => {})
    return () => { live = false }
  }, [load])

  const refresh = useCallback(async () => {
    try { await load() } catch (failure) { setError(failure.message) }
  }, [load])

  const flash = useCallback((text) => {
    setToast(text)
    setTimeout(() => setToast(null), 2600)
  }, [])

  if (error) {
    return html`
      <div class="app"><div class="event"><div class="event-panel" style="padding-top:80px">
        <div class="notice notice-error">${error}</div>
        <button class="action action-glass" onClick=${() => navigate({ name: 'home' })}>رجوع للمواعيد</button>
      </div></div></div>
    `
  }
  if (!event) return html`<div class="app"><${Spinner} /></div>`

  const art = artFor(event.id)
  const startAt = parseDate(event.start_date)
  const cancelled = Boolean(event.cancelled_at)
  const price = Number(event.price_per_person ?? 0)
  const isPaid = Number(event.total_price ?? 0) > 0
  const seats = roster?.filter((row) => !row.is_waitlisted) ?? []
  const waiting = roster?.filter((row) => row.is_waitlisted) ?? []
  const mine = roster?.find((row) => row.user_id === userId && !row.is_waitlisted) ?? null
  const myWait = roster?.find((row) => row.user_id === userId && row.is_waitlisted) ?? null
  const myGuests = roster?.filter((row) => !row.user_id && row.added_by === userId) ?? []
  const isOwner = ownedWorkspaces.includes(event.workspace_id)
  const capacity = event.max_participants ?? 0
  const full = capacity > 0 && seats.length >= capacity
  const closedAtCapacity = full && event.capacity_policy === 'closed'
  const owes = isPaid && mine && mine.payment_status === 'pending' && !mine.payment_declared_at
  const awaiting = isPaid && mine?.payment_declared_at && mine.payment_status === 'pending'
  const settled = isPaid && mine?.payment_status === 'confirmed'

  async function run(work, success) {
    setBusy(true)
    try {
      await work()
      if (success) flash(success)
      await refresh()
    } catch (failure) {
      flash(failure.message)
    } finally {
      setBusy(false)
    }
  }

  return html`
    <div class="app">
      <div class="event" style=${`--fade-start:${Math.max(panelTop - 60, 0)}px;--fade-end:${Math.max(panelTop - 60, 0) + 150}px`}>
        <div class="event-art"><img src=${art} alt="" /></div>
        <div class="event-art-blur"><img src=${art} alt="" /></div>
        <div class="event-shade"></div>

        <button class="glass-circle event-back" onClick=${goBack} aria-label="إغلاق">
          <${Icon.back} />
        </button>

        <div class="event-scroll">
          <div class="event-window"></div>
          <div class="event-panel">
            <div class="hero">
              ${cancelled && html`<span class="skipped">هذا الموعد متخطّى</span>`}
              <h1>${event.name}</h1>
              <div class="when">يوم ${arabicDay(startAt)}، الساعة ${arabicTime(startAt)}</div>
            </div>

            ${cancelled
              ? html`
                  <div class="card">
                    <div style="font-size:14px;font-weight:700;margin-bottom:8px">ⓘ سبب التخطي</div>
                    <div style="font-size:14px;color:rgba(255,255,255,0.76)">
                      ${event.cancellation_reason_text
                        || reasonLabel(event.cancellation_reason_code)
                        || 'موعد هذا الأسبوع متخطّى، وتستمر المواعيد القادمة كالمعتاد.'}
                    </div>
                  </div>
                `
              : isOwner
                ? html`<${OwnerNote} />`
                : html`
                    <${MemberCTA}
                      mine=${mine}
                      myWait=${myWait}
                      myGuests=${myGuests}
                      isPaid=${isPaid}
                      owes=${owes}
                      awaiting=${awaiting}
                      settled=${settled}
                      full=${full}
                      closedAtCapacity=${closedAtCapacity}
                      locked=${Boolean(event.registration_locked)}
                      busy=${busy}
                      onRegister=${() => setSheet('register')}
                      onPay=${() => setSheet('pay')}
                      onGuests=${() => setSheet('guests')}
                      onDecline=${() => setSheet('decline')}
                      onLeaveQueue=${() => run(() => leaveWaitlist(event.id, userId), 'انسحبت من قائمة الانتظار')}
                      onJoinQueue=${() => run(() => joinWaitlist(event.id, userId), 'انضممت لقائمة الانتظار')}
                    />
                  `}

            ${event.location &&
            html`
              <a class="link-row"
                 href=${event.latitude != null
                   ? `https://maps.google.com/?q=${event.latitude},${event.longitude}`
                   : `https://maps.google.com/?q=${encodeURIComponent(event.location)}`}
                 target="_blank" rel="noopener">
                <${Icon.directions} />
                <span class="truncate">${event.location}</span>
                <span class="chev"><${Icon.chevronStart} /></span>
              </a>
            `}

            ${event.description &&
            html`<div class="card" style="font-size:14px;color:rgba(255,255,255,0.8)">${event.description}</div>`}

            <div class="card">
              <div class="progress-head">
                <span class="label">المسجلون في الموعد</span>
                <span class="value">${seats.length} من ${capacity || seats.length}</span>
              </div>
              <div class="progress-track">
                <div class="progress-fill"
                     style=${`width:${capacity > 0 ? Math.min(seats.length / capacity, 1) * 100 : 100}%`}></div>
              </div>
              ${waiting.length > 0
                ? html`<div class="progress-note waiting">${waiting.length} في قائمة الانتظار</div>`
                : event.capacity_policy === 'closed'
                  ? html`<div class="progress-note closed">يقفل التسجيل عند اكتمال العدد</div>`
                  : null}
            </div>

            <div class="section-label">القائمة</div>
            ${roster === null
              ? html`<${Spinner} />`
              : seats.length
                ? html`
                    <div class="row-stack">
                      ${seats.map(
                        (person) => html`
                          <${RowCard}
                            key=${person.participant_id}
                            name=${person.display_name ?? person.guest_name ?? 'لاعب'}
                            subtitle=${rosterSubtitle(person, userId)}
                            avatarUrl=${person.avatar_url}
                            accessory=${statusAccessory(person, isPaid, userId)}
                          />
                        `
                      )}
                    </div>
                  `
                : html`<div class="empty-roster">كن أول المسجلين.</div>`}

            ${waiting.length > 0 &&
            html`
              <div class="section-label">قائمة الانتظار</div>
              <div class="section-hint">أول ما يعتذر أحد، ينحجز المكان لأول واحد بالقائمة تلقائيًا.</div>
              <div class="row-stack">
                ${waiting.map(
                  (person, position) => html`
                    <${RowCard}
                      key=${person.participant_id}
                      name=${person.display_name ?? 'لاعب'}
                      subtitle=${position === 0 ? 'التالي على الدور' : null}
                      avatarUrl=${person.avatar_url}
                      accessory=${html`<span class="queue-number">${position + 1}</span>`}
                    />
                  `
                )}
              </div>
            `}
          </div>
        </div>
      </div>

      ${toast && html`<${Toast} text=${toast} />`}

      ${(sheet === 'register' || sheet === 'guests' || sheet === 'pay') &&
      html`<${RegistrationSheet}
        event=${event}
        profile=${profile}
        destination=${destination}
        mine=${mine}
        myGuests=${myGuests}
        mode=${sheet}
        onClose=${() => setSheet(null)}
        onDone=${async (message) => {
          setSheet(null)
          if (message) flash(message)
          await refresh()
        }}
      />`}

      ${sheet === 'decline' &&
      html`<${DeclineSheet}
        eventId=${event.id}
        onClose=${() => setSheet(null)}
        onDone=${async () => {
          setSheet(null)
          flash('سُجّل اعتذارك عن الموعد')
          await refresh()
        }}
      />`}
    </div>
  `
}

/// participationCTA — what the member can do, in the app's order: the seat,
/// then the money, then the way out.
function MemberCTA({
  mine, myWait, myGuests, isPaid, owes, awaiting, settled, full, closedAtCapacity, locked,
  busy, onRegister, onPay, onGuests, onDecline, onLeaveQueue, onJoinQueue
}) {
  if (myWait) {
    return html`
      <div class="vstack">
        <div class="state-row"><span class="dot-check dot-orange"><${Icon.clock} /></span>أنت في قائمة الانتظار</div>
        <button class="status-row" disabled=${busy} onClick=${onLeaveQueue}>
          <span class="dot-check dot-orange"><${Icon.clock} /></span>
          مكانك في الدور محفوظ
          <span class="leave">انسحب</span>
        </button>
      </div>
    `
  }

  if (mine) {
    return html`
      <div class="vstack">
        ${owes && html`
          <button class="action action-money" onClick=${onPay}>
            <${Icon.banknote} /> دفع القطة
          </button>`}
        ${awaiting && html`
          <div class="state-row"><span class="dot-check dot-orange"><${Icon.clock} /></span>بانتظار تأكيد وصول القطة</div>`}
        ${settled && html`
          <div class="state-row"><span class="dot-check dot-green"><${Icon.seal} /></span>القطة مدفوعة</div>`}
        <button class="action action-glass" onClick=${onGuests}>
          <${Icon.personPlus} /> سجّل معك أحد
        </button>
        <button class="status-row" onClick=${onDecline}>
          <span class="dot-check dot-lime"><${Icon.seal} /></span>
          مكانك محفوظ${myGuests.length ? ` ومعك ${counted(myGuests.length, NOUNS.player)}` : ''}
          <span class="leave">اعتذر</span>
        </button>
      </div>
    `
  }

  if (locked) {
    return html`<div class="action action-quiet">التسجيل مقفل</div>`
  }

  if (closedAtCapacity) {
    return html`<div class="action action-quiet">🔒 التسجيل مغلق</div>`
  }

  return html`
    <button class="action action-prominent" disabled=${busy}
            onClick=${full ? onJoinQueue : onRegister}>
      ${full ? '⏳ سجل كاحتياط' : '+ سجل في التمرين'}
    </button>
  `
}

function OwnerNote() {
  return html`
    <div class="notice notice-info">
      أنت مشرف هذا التمرين. أدوات المشرف — فتح المواعيد وتعديلها، تأكيد وصول القطات، تنبيه الأعضاء —
      موجودة في التطبيق.
      <div style="margin-top:10px">
        <a class="action action-glass" style="height:42px;font-size:14px"
           href=${APP_STORE_URL} target="_blank" rel="noopener">افتح التطبيق</a>
      </div>
    </div>
  `
}

function rosterSubtitle(person, userId) {
  if (!person.user_id) {
    if (person.added_manually) return 'سجّله المشرف'
    return person.added_by === userId ? 'سجّلته أنت' : 'ضيف'
  }
  if (person.user_id === userId) return 'أنت'
  return null
}

function statusAccessory(person, isPaid, userId) {
  if (!isPaid) return null
  if (person.payment_status === 'pending' && !person.payment_declared_at) {
    return html`<span class="dot-check dot-orange" title="باقي السداد">﷼</span>`
  }
  if (person.payment_status === 'pending') {
    return html`<span class="dot-check dot-orange" title="بانتظار التأكيد"><${Icon.clock} /></span>`
  }
  if (person.payment_status === 'confirmed') {
    return html`<span class="dot-check dot-green" title="القطة مدفوعة"><${Icon.seal} /></span>`
  }
  return null
}

function reasonLabel(code) {
  return {
    weather: 'ظرف الطقس',
    match_or_event_conflict: 'تعارض مع مباراة أو حدث مهم',
    low_attendance: 'قلة العدد',
    occasion: 'وجود مناسبة',
    other: 'سبب آخر'
  }[code] ?? null
}
