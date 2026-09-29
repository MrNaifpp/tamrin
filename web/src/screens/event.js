import { html, useState, useEffect, useCallback } from '../../vendor/preact.js'
import {
  getEventById, getEventParticipants, getEventPaymentDestination, getMyWorkspaces,
  getEventLineup, createCardPayment, removeMyGuest
} from '../api.js'
import { goBack, navigate } from '../router.js'
import { Spinner, Icon, Toast, RowCard, eventArt, sportOf, usesFootballFeatures, fadeInImage } from '../ui.js'
import { parseDate, arabicDay, arabicTime, counted, NOUNS, isPast } from '../format.js'
import { APP_STORE_URL } from '../config.js'
import { DeclineSheet } from './decline.js'
import { RegistrationSheet } from './registration.js'
import { CardPaymentSheet, resumeCardPayment, verifyMessage } from './card.js'
import { LineupSection, resolveLineup } from './lineup.js'
import { PlayerSheet } from './rating.js'
import { ConfirmSheet } from './confirm.js'

/// EventDetailView: artwork at the top, then one panel carrying its own
/// frost. Everything the member does with an exercise happens here now —
/// the poster on Home only opens it.
export function EventScreen({ eventId, entry, session, profile }) {
  const userId = session.user.id
  const [event, setEvent] = useState(null)
  const [roster, setRoster] = useState(null)
  const [destination, setDestination] = useState(null)
  const [workspace, setWorkspace] = useState(null) // the member's groups, once loaded
  const [lineupRecord, setLineupRecord] = useState(null)
  const [error, setError] = useState(null)
  const [toast, setToast] = useState(null)
  const [sheet, setSheet] = useState(null) // register | guests | pay | decline | card
  const [quote, setQuote] = useState(null)
  const [paying, setPaying] = useState(false)
  const [player, setPlayer] = useState(null)
  const [removing, setRemoving] = useState(null)
  const [busy, setBusy] = useState(false)
  const [handledEntry, setHandledEntry] = useState(false)
  // Where the panel's top edge currently sits, so its frost dissolves in at
  // the panel's own edge rather than at a fixed point on the screen.
  const [panelTop, setPanelTop] = useState(300)

  useEffect(() => {
    const onScroll = () => setPanelTop(Math.max(300 - window.scrollY, 0))
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  const load = useCallback(async () => {
    const record = await getEventById(eventId)
    setEvent(record)
    const paid = Number(record.total_price ?? 0) > 0 || Number(record.price_per_person ?? 0) > 0
    const [rows, payment, lineup] = await Promise.all([
      getEventParticipants(eventId).catch(() => null),
      paid ? getEventPaymentDestination(eventId).catch(() => null) : Promise.resolve(null),
      getEventLineup(eventId).catch(() => null)
    ])
    setRoster(rows)
    setDestination(payment)
    setLineupRecord(lineup)
    return { record, rows }
  }, [eventId])

  const refresh = useCallback(async () => {
    try { await load() } catch (failure) { setError(failure.message) }
  }, [load])

  const flash = useCallback((text) => setToast(text), [])

  /// «دفع القطة»: the payment is created on the tap, not when the page opens.
  /// A group with a verified recipient pays by card; one that takes transfers
  /// by hand gets the transfer sheet.
  const beginPayment = useCallback(async (current) => {
    setPaying(true)
    try {
      const answer = await createCardPayment(current.id)
      switch (answer?.status) {
        case 'ready': setQuote(answer); setSheet('card'); break
        case 'recipient_not_onboarded': setSheet('pay'); break
        case 'event_closed': flash('أُغلق التسجيل لهذا الموعد.'); break
        default: await refresh()
      }
    } catch (failure) {
      flash(failure.message)
    } finally {
      setPaying(false)
    }
  }, [refresh])

  useEffect(() => {
    let live = true
    load()
      .then(async ({ record, rows }) => {
        if (!live) return
        // Back from the bank's 3-D Secure page: settle before anything else.
        const returned = await resumeCardPayment(record.id).catch(() => null)
        if (returned) {
          const message = verifyMessage(returned)
          flash(message ?? 'دُفعت القطة وتأكد مقعدك')
          await refresh()
          return
        }
        if (handledEntry || !entry) return
        setHandledEntry(true)
        const mine = rows?.find((row) => row.user_id === userId && !row.guest_name && !row.is_waitlisted)
        // The entry segment opens the step it names: registration for
        // «سجّل», and the payment for an exercise still owed.
        if (entry === 'register' && !mine && !isPast(record)) setSheet('register')
        if (entry === 'pay') beginPayment(record)
      })
      .catch((failure) => live && setError(failure.message))
    // The group decides the sport, and the sport decides the photo, so the
    // page waits for it rather than drawing one picture and swapping it.
    getMyWorkspaces()
      .then((list) => live && setWorkspace(list ?? []))
      .catch(() => live && setWorkspace([]))
    return () => { live = false }
  }, [load])

  if (error) {
    return html`
      <div class="app"><div class="event"><div class="event-panel" style="padding-top:80px">
        <div class="notice notice-error">${error}</div>
        <button class="action action-glass" onClick=${() => navigate({ name: 'home' })}>رجوع للمواعيد</button>
      </div></div></div>
    `
  }
  if (!event || workspace === null) return html`<div class="app"><${Spinner} /></div>`

  const group = Array.isArray(workspace) ? workspace.find((w) => w.id === event.workspace_id) ?? null : null
  const sport = sportOf(group)
  const football = usesFootballFeatures(sport)
  const art = eventArt(event.id, sport)
  const startAt = parseDate(event.start_date)
  const cancelled = Boolean(event.cancelled_at)
  const past = isPast(event)
  const started = startAt ? startAt.getTime() <= Date.now() : false
  const price = Number(event.price_per_person ?? 0)
  const isPaid = Number(event.total_price ?? 0) > 0 || price > 0
  const seats = roster?.filter((row) => !row.is_waitlisted) ?? []
  const waiting = roster?.filter((row) => row.is_waitlisted) ?? []
  const mine = roster?.find((row) => row.user_id === userId && !row.guest_name && !row.is_waitlisted) ?? null
  const myWait = roster?.find((row) => row.user_id === userId && row.is_waitlisted) ?? null
  const myGuests = roster?.filter((row) => !row.user_id && row.added_by === userId && !row.is_waitlisted) ?? []
  const isOwner = group?.owner_id === userId
  const capacity = event.max_participants ?? 0
  const full = capacity > 0 && seats.length >= capacity
  const closedAtCapacity = full && event.capacity_policy === 'closed'

  // Owed covers the member's own seat and any guest they added: a guest added
  // after paying brings the pay button back.
  const awaiting = (row) => row.payment_status === 'pending' && !row.payment_declared_at
  const owes = isPaid && Boolean(mine) && [mine, ...myGuests].some(awaiting)
  const declared = isPaid && mine?.payment_status === 'pending' && Boolean(mine?.payment_declared_at)
  const settled = isPaid && Boolean(mine) && !owes && !declared
  const overdue = past && !cancelled && !isOwner && isPaid && [mine, ...myGuests].filter(Boolean).some(awaiting)

  const lineup = !cancelled ? resolveLineup(lineupRecord, roster) : null

  const refundNotice = isPaid
    ? (started ? 'بدأ التمرين، فلن يُسترجع المبلغ.' : 'ما دفعته بالبطاقة يُسترجع إليها. التحويل البنكي يُرتَّب مع المشرف.')
    : null

  const ctaKey = [
    cancelled ? 'cancelled' : overdue ? 'overdue' : past ? 'past' : myWait ? 'queue' : mine ? 'seat' : full ? 'full' : 'open',
    owes ? 'owes' : declared ? 'declared' : settled ? 'settled' : '',
    myGuests.length,
    paying ? 'paying' : ''
  ].join('-')

  const nameOf = (row) => row.display_name ?? row.guest_name ?? 'لاعب'

  function openPlayer(row, seatNumber) {
    const adder = row.added_by ? roster?.find((r) => r.user_id === row.added_by && !r.guest_name) : null
    const mayRemove = !row.user_id && row.added_by === userId && !row.added_manually && !past
    setPlayer({
      userId: row.user_id,
      participantId: row.participant_id,
      name: nameOf(row),
      avatarUrl: row.avatar_url,
      position: row.player_position,
      seatNumber,
      registeredBy: !row.user_id ? (row.added_manually ? 'المشرف' : adder ? nameOf(adder) : null) : null,
      joinedAt: row.joined_at,
      removable: mayRemove
    })
  }

  async function removeGuest(row) {
    setBusy(true)
    try {
      await removeMyGuest(row.participant_id)
      flash(`أُزيل ${nameOf(row)} وتحرر مقعده`)
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
        <div class="event-art"><img class="fade-img" ref=${fadeInImage} src=${art} alt="" /></div>
        <div class="event-art-blur"><img class="fade-img" ref=${fadeInImage} src=${art} alt="" /></div>
        <div class="event-shade"></div>

        <button class="glass-circle event-back" onClick=${goBack} aria-label="إغلاق">
          <${Icon.close} />
        </button>
        <button class="glass-circle event-details" disabled=${!event.workspace_id}
                onClick=${() => navigate({ name: 'team', workspaceId: event.workspace_id, eventId: event.id })}
                aria-label="تفاصيل التمرين" title="يفتح قالب التمرين وأعضاءه وطرق الدفع">
          <${Icon.details} />
        </button>

        <div class="event-scroll">
          <div class="event-window"></div>
          <div class="event-panel">
            <div class="hero enter" style="--i:0">
              ${cancelled && html`<span class="skipped">هذا الموعد متخطّى</span>`}
              <h1>${event.name}</h1>
              <div class="when">يوم ${arabicDay(startAt)}، الساعة ${arabicTime(startAt)}</div>
            </div>

            <div class="change" key=${ctaKey}>
              ${cancelled
                ? html`<${CancellationPanel} event=${event} />`
                : overdue
                  ? html`
                      <div class="card vstack enter" style="--i:1;gap:12px">
                        <div class="panel-title"><${Icon.banknote} /> باقي دفع القطة</div>
                        <div class="panel-body">انتهى الموعد، وتقدر تسدد قطتك الآن قبل الانتقال للموعد القادم.</div>
                        <${PayControl} paying=${paying} onPay=${() => beginPayment(event)} />
                      </div>
                    `
                  : past
                    ? html`
                        <div class="card historical enter" style="--i:1">
                          <span class="historical-icon"><${Icon.history} /></span>
                          <span>
                            <strong>تمرين سابق</strong>
                            <span>انتهى التسجيل والتعديل لهذا الموعد</span>
                          </span>
                        </div>
                      `
                    : isOwner
                      ? html`<${OwnerNote} />`
                      : html`<${MemberCTA}
                          mine=${mine}
                          myWait=${myWait}
                          myGuests=${myGuests}
                          isPaid=${isPaid}
                          owes=${owes}
                          declared=${declared}
                          settled=${settled}
                          full=${full}
                          closedAtCapacity=${closedAtCapacity}
                          rosterFailed=${roster === null}
                          busy=${busy}
                          paying=${paying}
                          onRetry=${refresh}
                          onRegister=${() => setSheet('register')}
                          onPay=${() => beginPayment(event)}
                          onReview=${() => setSheet('pay')}
                          onGuests=${() => setSheet('guests')}
                          onDecline=${() => setSheet('decline')}
                          onRemoveGuest=${(row) => setRemoving(row)}
                        />`}
            </div>

            ${(event.location?.trim() || event.latitude != null) &&
            html`
              <a class="link-row enter" style="--i:2"
                 href=${directionsUrl(event)} target="_blank" rel="noopener"
                 aria-label=${event.location ? `الاتجاهات إلى ${event.location}` : 'الاتجاهات'}>
                <${Icon.directions} />
                <span class="truncate">${event.location?.trim() || 'الاتجاهات'}</span>
                <span class="chev"><${Icon.chevronStart} /></span>
              </a>
            `}

            <div class="card enter" style="--i:3">
              <div class="progress-head">
                <span class="label">المسجلون في الموعد</span>
                <span class="value change" key=${seats.length}>${seats.length} من ${capacity || seats.length}</span>
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

            ${lineup && html`<${LineupSection} lineup=${lineup} sport=${sport} meId=${userId} art=${art} />`}

            <div class="section-label enter" style="--i:4">القائمة</div>
            ${roster === null
              ? html`<${Spinner} />`
              : seats.length
                ? html`
                    <div class="row-stack">
                      ${seats.map(
                        (person, position) => html`
                          <${RowCard}
                            key=${person.participant_id}
                            index=${5 + position}
                            name=${nameOf(person)}
                            subtitle=${rosterSubtitle(person, roster)}
                            avatarUrl=${person.avatar_url}
                            accessory=${statusAccessory(person, isPaid)}
                            onClick=${() => openPlayer(person, position + 1)}
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
                      index=${position}
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

      ${toast && html`<${Toast} text=${toast} onDone=${() => setToast(null)} />`}

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

      ${sheet === 'card' && quote &&
      html`<${CardPaymentSheet}
        event=${event}
        quote=${quote}
        onClose=${() => { setSheet(null); setQuote(null) }}
        onPaid=${async () => {
          setSheet(null)
          setQuote(null)
          flash('دُفعت القطة وتأكد مقعدك')
          await refresh()
        }}
      />`}

      ${sheet === 'decline' &&
      html`<${DeclineSheet}
        eventId=${event.id}
        refundNotice=${refundNotice}
        onClose=${() => setSheet(null)}
        onDone=${async () => {
          setSheet(null)
          flash('سُجّل اعتذارك عن الموعد')
          await refresh()
        }}
      />`}

      ${player &&
      html`<${PlayerSheet}
        player=${player}
        workspaceId=${event.workspace_id}
        football=${football}
        meId=${userId}
        onClose=${() => setPlayer(null)}
        onRemove=${player.removable
          ? () => { const row = roster.find((r) => r.participant_id === player.participantId); setPlayer(null); if (row) setRemoving(row) }
          : null}
      />`}

      ${removing &&
      html`<${ConfirmSheet}
        title="إزالة اللاعب؟"
        message=${`سيُزال ${nameOf(removing)} من قائمة «${event.name}» ويتحرر مقعده.${isPaid && !started ? ' وما دفعته عنه بالبطاقة يُسترجع إليها.' : ''}`}
        confirm="إزالة"
        cancel="تراجع"
        onClose=${() => setRemoving(null)}
        onConfirm=${() => { const row = removing; setRemoving(null); removeGuest(row) }}
      />`}
    </div>
  `
}

/// participationCTA — what the member can do, in the app's order: the seat,
/// then the money, then their guests, then the way out.
function MemberCTA({
  mine, myWait, myGuests, isPaid, owes, declared, settled, full, closedAtCapacity, rosterFailed,
  busy, paying, onRetry, onRegister, onPay, onReview, onGuests, onDecline, onRemoveGuest
}) {
  if (rosterFailed) {
    return html`<button class="action action-glass" onClick=${onRetry}>تعذر التحقق من تسجيلك. حاول مجددًا</button>`
  }

  if (myWait) {
    return html`
      <button class="status-row" disabled=${busy} onClick=${onDecline} title="يفتح تأكيد الاعتذار عن الموعد">
        <span class="dot-check dot-orange"><${Icon.clock} /></span>
        أنت في قائمة الانتظار
        <span class="leave">انسحب</span>
      </button>
    `
  }

  if (mine && declared) {
    return html`
      <div class="card vstack" style="gap:12px">
        <div class="state-row" style="padding:0"><span class="dot-check dot-orange"><${Icon.clock} /></span>بانتظار تأكيد الدفع</div>
        <div class="hstack" style="gap:8px">
          <button class="pill-button grow" onClick=${onReview}>مراجعة التفاصيل</button>
          <button class="pill-button pill-danger grow" onClick=${onDecline}>إلغاء الطلب</button>
        </div>
      </div>
    `
  }

  if (mine) {
    return html`
      <div class="vstack">
        ${owes && html`<${PayControl} paying=${paying} onPay=${onPay} />`}
        ${settled && isPaid && html`
          <div class="paid-pill"><span class="dot-check dot-green"><${Icon.seal} /></span>القطة مدفوعة</div>`}
        ${myGuests.length > 0 && html`
          <div class="my-guests">
            <div class="my-guests-title">ضيوفك</div>
            ${myGuests.map((guest) => html`
              <div class="guest-pill" key=${guest.participant_id}>
                <span class="grow truncate">${guest.guest_name}</span>
                <button class="guest-minus" disabled=${busy} onClick=${() => onRemoveGuest(guest)}
                        aria-label=${`إزالة ${guest.guest_name}`}><${Icon.minus} /></button>
              </div>
            `)}
          </div>`}
        <button class="action action-glass" onClick=${onGuests} title="يفتح تسجيل ضيوف جدد دون تغيير تسجيلك">
          <${Icon.personPlus} /> سجّل معك أحد
        </button>
        <button class="status-row" onClick=${onDecline} title="يفتح تأكيد الاعتذار عن الموعد">
          <span class="dot-check dot-lime"><${Icon.seal} /></span>
          مكانك محفوظ
          <span class="leave">اعتذر</span>
        </button>
      </div>
    `
  }

  if (closedAtCapacity) {
    return html`<div class="action action-quiet" aria-label="التسجيل مغلق، اكتمل العدد"><${Icon.lock} /> التسجيل مغلق</div>`
  }

  return html`
    <button class="action action-prominent" disabled=${busy} onClick=${onRegister}>
      ${full ? html`<${Icon.clock} /> سجل كاحتياط` : html`<${Icon.plus} /> سجل في التمرين`}
    </button>
  `
}

/// payControl: a spinner while the payment is prepared, otherwise «دفع القطة».
function PayControl({ paying, onPay }) {
  if (paying) {
    return html`<div class="action action-quiet" aria-label="جارٍ تجهيز الدفع"><span class="spinner spinner-small"></span></div>`
  }
  return html`
    <button class="action action-money" onClick=${onPay} title="يجهّز الدفع ويفتح وسيلة الدفع المتاحة">
      <${Icon.banknote} /> دفع القطة
    </button>
  `
}

function CancellationPanel({ event }) {
  const reason = event.cancellation_reason_text || reasonLabel(event.cancellation_reason_code)
  return html`
    <div class="card enter" style="--i:1">
      ${reason
        ? html`
            <div class="panel-title">ⓘ سبب التخطي</div>
            <div class="panel-body">${reason}</div>
          `
        : html`<div class="panel-body">موعد هذا الأسبوع متخطّى، وتستمر المواعيد القادمة كالمعتاد.</div>`}
    </div>
  `
}

function OwnerNote() {
  return html`
    <div class="notice notice-info">
      أنت مشرف هذا التمرين. أدوات المشرف (فتح المواعيد وتعديلها، تأكيد وصول القطات، تقسيم الفريقين، تنبيه الأعضاء)
      موجودة في التطبيق.
      <div style="margin-top:10px">
        <a class="action action-glass" style="height:42px;font-size:14px"
           href=${APP_STORE_URL} target="_blank" rel="noopener">افتح التطبيق</a>
      </div>
    </div>
  `
}

/// Google Maps directions: a pin when the organizer dropped one, the venue's
/// name otherwise — EventDirections' web fallback.
export function directionsUrl(event) {
  if (event.latitude != null && event.longitude != null) {
    return `https://www.google.com/maps/dir/?api=1&destination=${event.latitude},${event.longitude}`
  }
  return `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(event.location ?? '')}`
}

function rosterSubtitle(person, roster) {
  if (person.user_id) return null
  if (person.added_manually) return 'سجّله المشرف'
  const adder = roster?.find((row) => row.user_id === person.added_by && !row.guest_name)
  const name = adder?.display_name
  return name ? `سجّله ${name}` : null
}

/// A member sees one payment mark on other rows: the hourglass of a transfer
/// waiting on the organizer.
function statusAccessory(person, isPaid) {
  if (isPaid && person.payment_status === 'pending' && person.payment_declared_at) {
    return html`<span class="dot-check dot-orange" title="بانتظار تأكيد وصول القطة"><${Icon.clock} /></span>`
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
