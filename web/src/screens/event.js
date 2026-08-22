import { html, useState, useEffect, useCallback } from '../../vendor/preact.js'
import {
  getEventById, getEventParticipants, getEventPaymentDestination,
  registerEventSeat, declareEventPayment, declineEvent, joinWaitlist, leaveWaitlist,
  getMyWorkspaces
} from '../api.js'
import { goBack, navigate } from '../router.js'
import { Spinner, Notice, Avatar, Sheet, BackIcon, positionTint, providerOf } from '../ui.js'
import { parseDate, arabicDay, arabicDate, arabicTime, cleanAmount, counted, NOUNS } from '../format.js'
import { APP_STORE_URL } from '../config.js'

/// What the register call answered, in the member's words. Anything not listed
/// here is a status this build has not met, and is shown verbatim rather than
/// swallowed.
const REGISTER_MESSAGES = {
  already_joined: 'أنت مسجّل في هذا الموعد أصلًا.',
  not_published: 'هذا الموعد ما انفتح للتسجيل بعد.',
  cancelled: 'هذا الموعد ملغى.',
  registration_closed: 'التسجيل مقفل في هذا الموعد.',
  registration_closed_full: 'اكتمل عدد اللاعبين، وهذا الموعد يقفل التسجيل عند الاكتمال بدون قائمة انتظار.',
  event_terms_changed: 'تغيّرت رسوم الموعد. حدّث الصفحة وجرّب من جديد.'
}

const DECLINE_REASONS = [
  { code: null, title: 'بدون سبب' },
  { code: 'traveling', title: 'مسافر' },
  { code: 'tired', title: 'تعبان' },
  { code: 'injured', title: 'مصاب' },
  { code: 'commitment', title: 'لدي ارتباط' },
  { code: 'other', title: 'أخرى', acceptsFreeText: true }
]

export function EventScreen({ eventId, session, profile }) {
  const userId = session.user.id
  const [event, setEvent] = useState(null)
  const [roster, setRoster] = useState(null)
  const [destination, setDestination] = useState(null)
  const [ownedWorkspaces, setOwnedWorkspaces] = useState([])
  const [error, setError] = useState(null)
  const [toast, setToast] = useState(null)
  const [sheet, setSheet] = useState(null)

  const load = useCallback(async () => {
    const record = await getEventById(eventId)
    setEvent(record)
    const [rosterRows, destinationPayload] = await Promise.all([
      getEventParticipants(eventId).catch(() => null),
      Number(record.total_price ?? 0) > 0
        ? getEventPaymentDestination(eventId).catch(() => null)
        : Promise.resolve(null)
    ])
    setRoster(rosterRows)
    setDestination(destinationPayload)
  }, [eventId])

  useEffect(() => {
    let live = true
    load().catch((failure) => live && setError(failure.message))
    getMyWorkspaces()
      .then((list) => live && setOwnedWorkspaces(list.filter((w) => w.owner_id === userId).map((w) => w.id)))
      .catch(() => {})
    return () => { live = false }
  }, [load])

  const refresh = useCallback(async () => {
    try {
      await load()
    } catch (failure) {
      setError(failure.message)
    }
  }, [load])

  if (error) {
    return html`
      <div class="shell">
        <${EventTopBar} title="الموعد" />
        <${Notice} tone="error">${error}<//>
        <div style="height:12px"></div>
        <button class="btn btn-quiet" onClick=${() => navigate({ name: 'home' })}>رجوع للمواعيد</button>
      </div>
    `
  }

  if (!event) return html`<div class="shell"><${EventTopBar} title="الموعد" /><${Spinner} /></div>`

  const startAt = parseDate(event.start_date)
  const cancelled = Boolean(event.cancelled_at)
  const price = Number(event.price_per_person ?? 0)
  const isPaid = Number(event.total_price ?? 0) > 0
  const seats = roster?.filter((row) => !row.is_waitlisted) ?? []
  const waiting = roster?.filter((row) => row.is_waitlisted) ?? []
  const mySeat = roster?.find((row) => row.user_id === userId && !row.is_waitlisted) ?? null
  const myWait = roster?.find((row) => row.user_id === userId && row.is_waitlisted) ?? null
  const myGuests = roster?.filter((row) => !row.user_id && row.added_by === userId) ?? []
  const isOwner = ownedWorkspaces.includes(event.workspace_id)
  const full = event.max_participants != null && seats.length >= event.max_participants
  const locked = Boolean(event.registration_locked)
  const owesPayment = isPaid && mySeat && mySeat.payment_status === 'pending' && !mySeat.payment_declared_at
  const awaitingConfirmation = isPaid && mySeat?.payment_declared_at && mySeat.payment_status === 'pending'

  return html`
    <div class="shell">
      <${EventTopBar} title=${event.name} />

      <div class="event-poster" style="border-radius:var(--corner);margin-bottom:16px">
        ${event.image_url
          ? html`<img src=${event.image_url} alt="" />`
          : html`<span class="placeholder">⚽️</span>`}
      </div>

      <h1 class="title" style="font-size:26px">${event.name}</h1>
      <p class="subtitle" style="margin-bottom:14px">
        ${arabicDay(startAt)}، ${arabicDate(startAt)} · الساعة ${arabicTime(startAt)}
      </p>

      <div class="wrap" style="margin-bottom:16px">
        ${isPaid
          ? html`<span class="pill">${cleanAmount(price)} ريال للاعب</span>`
          : html`<span class="pill pill-green">بدون رسوم</span>`}
        ${event.max_participants
          ? html`<span class="pill ${full ? 'pill-amber' : ''}">${seats.length} من ${event.max_participants}</span>`
          : html`<span class="pill">${counted(seats.length, NOUNS.player)}</span>`}
        ${event.is_recurring ? html`<span class="pill">يتكرر</span>` : null}
        ${locked ? html`<span class="pill pill-amber">التسجيل مقفل</span>` : null}
      </div>

      ${cancelled &&
      html`<${Notice} tone="error">
        <strong>هذا الموعد ملغى.</strong>
        ${event.cancellation_reason_text ? html` ${event.cancellation_reason_text}` : null}
      <//>`}

      ${event.description && html`<p style="margin:0 0 16px">${event.description}</p>`}

      ${event.location &&
      html`
        <div class="card spread" style="margin-bottom:16px">
          <div class="grow">
            <div class="faint">الموقع</div>
            <div style="font-weight:500">${event.location}</div>
          </div>
          ${event.latitude != null &&
          html`<a class="btn btn-sm btn-quiet"
                  href=${`https://maps.google.com/?q=${event.latitude},${event.longitude}`}
                  target="_blank" rel="noopener">الاتجاهات</a>`}
        </div>
      `}

      ${toast && html`<div style="margin-bottom:14px"><${Notice} tone=${toast.tone}>${toast.text}<//></div>`}

      <${MemberActions}
        event=${event}
        mySeat=${mySeat}
        myWait=${myWait}
        myGuests=${myGuests}
        isPaid=${isPaid}
        price=${price}
        full=${full}
        locked=${locked}
        cancelled=${cancelled}
        isOwner=${isOwner}
        owesPayment=${owesPayment}
        awaitingConfirmation=${awaitingConfirmation}
        destination=${destination}
        onSheet=${setSheet}
        onToast=${setToast}
        onRefresh=${refresh}
        userId=${userId}
      />

      <${Roster} title="المسجلون في الموعد" rows=${seats} userId=${userId} loading=${roster === null} />
      ${waiting.length
        ? html`<${Roster} title="قائمة الانتظار" rows=${waiting} userId=${userId} numbered=${true} />`
        : null}

      ${isOwner &&
      html`
        <div style="margin-top:20px">
          <${Notice} tone="info">
            أنت مشرف هذه المجموعة. أدوات المشرف — تعديل الموعد، تأكيد وصول القطات، تنبيه الأعضاء —
            موجودة في تطبيق «تمرين» على الآيفون.
            <div style="margin-top:10px">
              <a class="btn btn-sm btn-quiet" href=${APP_STORE_URL} target="_blank" rel="noopener">افتح التطبيق</a>
            </div>
          <//>
        </div>
      `}

      ${sheet === 'register' &&
      html`<${RegisterSheet}
        event=${event}
        isPaid=${isPaid}
        price=${price}
        full=${full}
        onClose=${() => setSheet(null)}
        onDone=${async (result) => {
          setSheet(null)
          setToast(result)
          await refresh()
        }}
      />`}

      ${sheet === 'pay' &&
      html`<${PaySheet}
        event=${event}
        destination=${destination}
        mySeat=${mySeat}
        myGuests=${myGuests}
        onClose=${() => setSheet(null)}
        onDone=${async (result) => {
          setSheet(null)
          setToast(result)
          await refresh()
        }}
      />`}

      ${sheet === 'decline' &&
      html`<${DeclineSheet}
        event=${event}
        onClose=${() => setSheet(null)}
        onDone=${async (result) => {
          setSheet(null)
          setToast(result)
          await refresh()
        }}
      />`}
    </div>
  `
}

function EventTopBar({ title }) {
  return html`
    <div class="topbar">
      <button class="iconbtn" onClick=${goBack} aria-label="رجوع"><${BackIcon} /></button>
      <h1>${title}</h1>
    </div>
  `
}

/// Everything the member can press, in the order the app puts it: the seat
/// first, the money second, the way out last.
function MemberActions({
  event, mySeat, myWait, myGuests, isPaid, price, full, locked, cancelled, isOwner,
  owesPayment, awaitingConfirmation, destination, onSheet, onToast, onRefresh, userId
}) {
  const [busy, setBusy] = useState(false)

  async function run(work, success) {
    setBusy(true)
    try {
      await work()
      if (success) onToast({ tone: 'good', text: success })
      await onRefresh()
    } catch (failure) {
      onToast({ tone: 'error', text: failure.message })
    } finally {
      setBusy(false)
    }
  }

  if (cancelled) return null

  if (myWait) {
    return html`
      <div class="card stack" style="margin-bottom:18px">
        <div>
          <strong>أنت في قائمة الانتظار</strong>
          <p class="faint" style="margin:4px 0 0">أول ما يتحرر مقعد ينحجز لك ويوصلك تنبيه.</p>
        </div>
        <button class="btn btn-danger" disabled=${busy}
                onClick=${() => run(() => leaveWaitlist(event.id, userId), 'انسحبت من قائمة الانتظار.')}>
          ${busy ? '…' : 'انسحب من القائمة'}
        </button>
      </div>
    `
  }

  if (mySeat) {
    const guestLine = myGuests.length ? ` ومعك ${counted(myGuests.length, NOUNS.player)}` : ''
    return html`
      <div class="card stack" style="margin-bottom:18px">
        <div>
          <strong>مكانك محفوظ${guestLine}</strong>
          ${owesPayment &&
          html`<p class="faint" style="margin:4px 0 0">
            باقي عليك تحويل ${cleanAmount(Number(mySeat.paid_price_per_person ?? price) * (mySeat.payment_group_size ?? 1))} ريال.
          </p>`}
          ${awaitingConfirmation &&
          html`<p class="faint" style="margin:4px 0 0">بانتظار تأكيد المشرف وصول القطة.</p>`}
          ${mySeat.payment_status === 'confirmed' && isPaid &&
          html`<p class="faint" style="margin:4px 0 0">القطة مدفوعة ومؤكدة.</p>`}
        </div>

        ${owesPayment &&
        html`<button class="btn btn-lime" onClick=${() => onSheet('pay')}>
          ${destination?.payment_methods?.[0]?.provider === 'cash' || destination?.provider === 'cash'
            ? 'سأسدد في الملعب'
            : 'حوّلت المبلغ'}
        </button>`}

        ${isOwner
          ? html`<p class="faint" style="margin:0">الاعتذار عن موعد تديره يتم من التطبيق.</p>`
          : html`<button class="btn btn-danger" disabled=${busy} onClick=${() => onSheet('decline')}>اعتذر</button>`}
      </div>
    `
  }

  if (locked) {
    return html`
      <div style="margin-bottom:18px"><${Notice}>التسجيل مقفل في هذا الموعد.<//></div>
    `
  }

  if (full && event.capacity_policy === 'closed') {
    return html`
      <div style="margin-bottom:18px">
        <${Notice} tone="amber">
          اكتمل عدد اللاعبين، وهذا الموعد يقفل التسجيل عند الاكتمال بدون قائمة انتظار.
        <//>
      </div>
    `
  }

  return html`
    <div class="card stack" style="margin-bottom:18px">
      ${full &&
      html`<div>
        <strong>امتلأت المقاعد</strong>
        <p class="faint" style="margin:4px 0 0">
          انضم لقائمة الانتظار، وإذا اعتذر أحد ينحجز لك مكانه تلقائيًا ويوصلك تنبيه.
        </p>
      </div>`}
      <button class="btn ${full ? '' : 'btn-lime'}" disabled=${busy}
              onClick=${() => (full
                ? run(() => joinWaitlist(event.id, userId), 'انضممت لقائمة الانتظار.')
                : onSheet('register'))}>
        ${full ? 'انضم لقائمة الانتظار' : isPaid ? `سجّل في الموعد · ${cleanAmount(price)} ريال` : 'سجّل في الموعد'}
      </button>
      ${!full && !isOwner &&
      html`<button class="btn btn-ghost" onClick=${() => onSheet('decline')}>ما أقدر أحضر</button>`}
    </div>
  `
}

function RegisterSheet({ event, isPaid, price, full, onClose, onDone }) {
  const [guests, setGuests] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const named = guests.map((guest) => guest.trim()).filter(Boolean)
  const groupSize = 1 + named.length

  async function submit() {
    setBusy(true)
    setError(null)
    try {
      // The price the member is looking at travels with the call: if the
      // organizer changed it in the meantime the server refuses rather than
      // seating them at a price they never agreed to.
      const result = await registerEventSeat(event.id, named, isPaid ? price : null)
      const status = result?.status
      if (status === 'submitted') {
        onDone({
          tone: 'good',
          text: isPaid
            ? `مكانك محفوظ${named.length ? ' ومعك ضيوفك' : ''}. باقي تحويل المبلغ.`
            : 'مكانك محفوظ. نشوفك في الموعد.'
        })
        return
      }
      if (status === 'waitlisted') {
        onDone({ tone: 'good', text: 'امتلأت المقاعد، فانضممت لقائمة الانتظار.' })
        return
      }
      setError(REGISTER_MESSAGES[status] ?? `تعذر التسجيل (${status}).`)
      setBusy(false)
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <${Sheet}
      title=${full ? 'قائمة الانتظار' : 'سجّل في الموعد'}
      subtitle=${isPaid
        ? `${cleanAmount(price)} ريال للاعب الواحد، تُحوَّل للمشرف بعد حجز المكان.`
        : 'هذا الموعد بدون رسوم.'}
      onClose=${onClose}
    >
      <div class="stack">
        <div class="spread">
          <div>
            <div style="font-weight:500">سجّل معك أحد</div>
            <div class="faint">أضف لاعبًا يحضر معك في هذا الموعد</div>
          </div>
          <button class="btn btn-sm btn-quiet" onClick=${() => setGuests([...guests, ''])}>＋ ضيف</button>
        </div>

        ${guests.map(
          (guest, index) => html`
            <div class="row" key=${index}>
              <input
                class="field grow"
                placeholder="اسم الضيف"
                value=${guest}
                onInput=${(e) => {
                  const next = [...guests]
                  next[index] = e.target.value
                  setGuests(next)
                }}
              />
              <button class="iconbtn" aria-label="احذف الضيف"
                      onClick=${() => setGuests(guests.filter((_, i) => i !== index))}>✕</button>
            </div>
          `
        )}

        ${isPaid &&
        html`
          <div class="spread" style="padding-top:6px">
            <span class="muted">الإجمالي</span>
            <span class="amount">${cleanAmount(price * groupSize)} <span style="font-size:16px">ريال</span></span>
          </div>
          <p class="faint" style="margin:0">لعدد ${counted(groupSize, NOUNS.player)}</p>
        `}

        ${error && html`<${Notice} tone="error">${error}<//>`}
        <button class="btn btn-lime" disabled=${busy} onClick=${submit}>
          ${busy ? 'جارٍ التسجيل…' : 'تسجيل'}
        </button>
      </div>
    <//>
  `
}

/// «حوّلت المبلغ»: the member picks the destination they actually paid to, and
/// the server stamps their seat and the guest seats they are responsible for.
function PaySheet({ event, destination, mySeat, myGuests, onClose, onDone }) {
  const methods = destination?.payment_methods ?? []
  const snapshot = destination?.provider
    ? [{
        payment_method_id: destination.payment_method_id,
        provider: destination.provider,
        mobile_number: destination.mobile_number,
        iban: destination.iban,
        account_number: destination.account_number
      }]
    : []
  const options = methods.length ? methods : snapshot

  const [selected, setSelected] = useState(options[0]?.payment_method_id ?? null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [copied, setCopied] = useState(null)

  const chosen = options.find((option) => option.payment_method_id === selected) ?? options[0]
  const groupSize = mySeat?.payment_group_size ?? 1 + myGuests.length
  const perPerson = Number(mySeat?.paid_price_per_person ?? event.price_per_person ?? 0)

  async function copy(value) {
    try {
      await navigator.clipboard.writeText(value)
      setCopied(value)
      setTimeout(() => setCopied(null), 1800)
    } catch {
      setError('ما قدرنا ننسخ. انسخ الرقم يدويًا.')
    }
  }

  async function submit() {
    if (!chosen) return
    setBusy(true)
    setError(null)
    try {
      const result = await declareEventPayment(event.id, chosen.payment_method_id)
      const status = result?.status
      if (status === 'declared') {
        onDone({ tone: 'good', text: 'أبلغنا المشرف، وننتظر تأكيده وصول المبلغ.' })
        return
      }
      if (status === 'nothing_due') {
        onDone({ tone: 'good', text: 'ما عليك شيء مستحق في هذا الموعد.' })
        return
      }
      const messages = {
        free_event: 'هذا الموعد بدون رسوم.',
        payment_method_required: 'المشرف ما حدّد وسيلة دفع لهذا الموعد بعد.',
        event_terms_changed: 'تغيّرت وسيلة الدفع. حدّث الصفحة وجرّب من جديد.'
      }
      setError(messages[status] ?? `تعذر تسجيل التحويل (${status}).`)
      setBusy(false)
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  if (!options.length) {
    return html`
      <${Sheet} title="السداد" onClose=${onClose}>
        <${Notice}>المشرف ما حدّد وسيلة دفع لهذا الموعد بعد.<//>
      <//>
    `
  }

  const info = providerOf(chosen?.provider)

  return html`
    <${Sheet}
      title=${info.kind === 'cash' ? 'السداد في الملعب' : 'حوّل المبلغ'}
      subtitle=${info.kind === 'cash'
        ? 'أخبر المشرف أنك ستسدد كاش، ويأكدها هو بعد استلامها.'
        : 'حوّل المبلغ للوجهة التالية، ثم أخبر المشرف.'}
      onClose=${onClose}
    >
      <div class="stack">
        <div class="spread">
          <span class="muted">المطلوب</span>
          <span class="amount">${cleanAmount(perPerson * groupSize)} <span style="font-size:16px">ريال</span></span>
        </div>
        <p class="faint" style="margin:0">لعدد ${counted(groupSize, NOUNS.player)}</p>

        ${options.length > 1 &&
        html`<div class="stack" style="gap:8px">
          ${options.map((option) => {
            const meta = providerOf(option.provider)
            return html`
              <button class="provider" key=${option.payment_method_id}
                      aria-pressed=${option.payment_method_id === selected}
                      onClick=${() => setSelected(option.payment_method_id)}>
                <span class="provider-mark" style="background:${meta.color}">${meta.mark}</span>
                <span class="grow"><strong>${meta.name}</strong></span>
              </button>
            `
          })}
        </div>`}

        ${options.length === 1 &&
        html`<div class="provider" aria-pressed="true">
          <span class="provider-mark" style="background:${info.color}">${info.mark}</span>
          <span class="grow"><strong>${info.name}</strong></span>
        </div>`}

        ${chosen?.mobile_number &&
        html`<${CopyRow} label="رقم الجوال" value=${chosen.mobile_number} copied=${copied} onCopy=${copy} />`}
        ${chosen?.iban &&
        html`<${CopyRow} label="IBAN" value=${chosen.iban} copied=${copied} onCopy=${copy} />`}
        ${chosen?.account_number &&
        html`<${CopyRow} label="رقم الحساب" value=${chosen.account_number} copied=${copied} onCopy=${copy} />`}

        ${error && html`<${Notice} tone="error">${error}<//>`}
        <button class="btn btn-lime" disabled=${busy} onClick=${submit}>
          ${busy ? '…' : info.kind === 'cash' ? 'سأسدد في الملعب' : 'حوّلت المبلغ'}
        </button>
      </div>
    <//>
  `
}

function CopyRow({ label, value, copied, onCopy }) {
  return html`
    <div class="destination">
      <span class="muted">${label}</span>
      <span class="row-tight">
        <span class="value">${value}</span>
        <button class="btn btn-sm btn-quiet" onClick=${() => onCopy(value)}>
          ${copied === value ? 'نُسخ' : 'نسخ'}
        </button>
      </span>
    </div>
  `
}

function DeclineSheet({ event, onClose, onDone }) {
  const [reason, setReason] = useState(DECLINE_REASONS[0])
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit() {
    setBusy(true)
    setError(null)
    try {
      await declineEvent(event.id, reason.code, reason.acceptsFreeText ? text.trim() || null : null)
      onDone({ tone: 'good', text: 'سجّلنا اعتذارك، وتحرر مكانك لبقية الأعضاء.' })
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <${Sheet}
      title="الاعتذار عن الموعد"
      subtitle="سيتاح مكانك لبقية أعضاء التمرين، ويمكنك إضافة السبب بشكل اختياري."
      onClose=${onClose}
    >
      <div class="stack">
        <div class="wrap">
          ${DECLINE_REASONS.map(
            (option) => html`
              <button class="chip" key=${option.title}
                      aria-pressed=${reason.title === option.title}
                      onClick=${() => setReason(option)}>
                ${option.title}
              </button>
            `
          )}
        </div>

        ${reason.acceptsFreeText &&
        html`<textarea class="field" rows="3" maxlength="500" placeholder="اكتب سببك"
                       value=${text} onInput=${(e) => setText(e.target.value)}></textarea>`}

        ${error && html`<${Notice} tone="error">${error}<//>`}
        <button class="btn btn-danger" disabled=${busy} onClick=${submit}>
          ${busy ? '…' : 'تأكيد الاعتذار'}
        </button>
      </div>
    <//>
  `
}

function Roster({ title, rows, userId, numbered = false, loading = false }) {
  return html`
    <section>
      <div class="section-head">
        <h2>${title}</h2>
        <span>${loading ? '' : counted(rows.length, NOUNS.player)}</span>
      </div>
      <div class="card">
        ${loading
          ? html`<div class="spinner"></div>`
          : rows.length
            ? rows.map(
                (row, index) => html`
                  <div class="member" key=${row.participant_id}>
                    ${numbered
                      ? html`<span class="queue-index">${index + 1}</span>`
                      : html`<${Avatar} name=${row.display_name ?? row.guest_name} url=${row.avatar_url} size=${38} />`}
                    <span class="grow">
                      <span class="name">
                        ${row.display_name ?? row.guest_name ?? 'لاعب'}
                        ${row.user_id === userId ? html`<span class="faint"> · أنت</span>` : null}
                      </span>
                      <${RosterSubtitle} row=${row} userId=${userId} />
                    </span>
                    ${!numbered && row.player_position
                      ? html`<span class="position-dot" style="background:${positionTint(row.player_position)}"
                                   title=${row.player_position}></span>`
                      : null}
                  </div>
                `
              )
            : html`<p class="muted" style="margin:0">كن أول المسجلين.</p>`}
      </div>
    </section>
  `
}

function RosterSubtitle({ row, userId }) {
  if (row.is_waitlisted) return null
  if (!row.user_id) {
    const owner = row.added_by === userId ? 'ضيفك' : 'ضيف'
    return html`<span class="faint" style="display:block">${row.added_manually ? 'سجّله المشرف' : owner}</span>`
  }
  if (row.payment_status === 'pending' && !row.payment_declared_at) {
    return html`<span class="faint" style="display:block">باقي السداد</span>`
  }
  if (row.payment_status === 'pending' && row.payment_declared_at) {
    return html`<span class="faint" style="display:block">بانتظار تأكيد القطة</span>`
  }
  return null
}
