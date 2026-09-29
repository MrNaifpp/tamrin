import { html, useState } from '../../vendor/preact.js'
import {
  registerEventSeat, registerEventGuests, registerEventGuestOnly, declareEventPayment,
  getEventById, joinWaitlist
} from '../api.js'
import { navigate } from '../router.js'
import { Sheet, Icon, MemberAvatar, providerOf } from '../ui.js'
import { cleanAmount, counted, NOUNS, isPast } from '../format.js'
import { useDismissible } from '../motion.js'

/// RegistrationFlowSheet. Taking a seat no longer involves money: the seat is
/// taken unpaid and settled afterwards from «دفع القطة». The payment step here
/// is the manual transfer, which is what «دفع القطة» falls back to when the
/// group takes transfers by hand rather than cards.
///
/// `mode`: 'register' (the member, plus guests if they want), 'guests' (a
/// member already seated adds more), 'pay' (straight to the transfer).

/// register_event_seat's statuses, worded as MockHomeFeed words them.
const SEAT_MESSAGES = {
  registration_closed: 'التسجيل مقفل لهذا الموعد.',
  not_published: 'لم يُنشر هذا الموعد بعد.',
  cancelled: 'هذا الموعد متخطى.',
  event_terms_changed: 'غيّر المشرف مبلغ الموعد. أغلق النافذة وافتحها مجددًا لمراجعة المبلغ الجديد.'
}

/// register_event_guests / register_event_guest_only.
const GUEST_MESSAGES = {
  seats_full: 'المقاعد المتبقية لا تكفي لكل الضيوف.',
  not_registered: 'لازم يكون تسجيلك مؤكد قبل إضافة ضيوف.',
  self_already_registered: 'أنت مسجل في الموعد. استخدم «سجّل معك أحد» لإضافة ضيوف.',
  self_registration_pending: 'طلب تسجيلك ما زال بانتظار التأكيد. انتظر حسمه قبل تسجيل ضيف بدونك.',
  empty_guests: 'أضف اسم لاعب واحد على الأقل.',
  duplicate_name: 'أحد هذه الأسماء مسجل معك مسبقًا.',
  pending_guest_request: 'عندك طلب ضيوف بانتظار تأكيد المشرف. انتظر تأكيده قبل إضافة طلب جديد.',
  creator_missing_payment_method: 'منظّم التمرين لم يضف وسيلة دفع لهذا الموعد بعد.',
  registration_closed: 'التسجيل مقفل لهذا الموعد.',
  event_terms_changed: 'غيّر المشرف مبلغ الموعد أو وسيلة الدفع. ارجع خطوة وراجع البيانات الجديدة.',
  not_published: 'لم يُنشر هذا الموعد بعد.',
  cancelled: 'هذا الموعد متخطى.'
}

export function RegistrationSheet({ event, profile, destination, mine, myGuests, mode, onClose, onDone }) {
  const isGuestRequest = mode === 'guests'
  const [step, setStep] = useState(mode === 'pay' ? 'payment' : 'seat')
  const [includesSelf, setIncludesSelf] = useState(!isGuestRequest)
  const [guests, setGuests] = useState(isGuestRequest ? [''] : [])
  const [showGuests, setShowGuests] = useState(isGuestRequest)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [outcome, setOutcome] = useState(null)
  const [owed, setOwed] = useState(null) // { id, title }
  const [selectedMethod, setSelectedMethod] = useState(null)
  const [copied, setCopied] = useState(null)
  /// A finished flow leaves on the same exit a tap on the scrim would give it,
  /// rather than blinking out while the page behind it reloads.
  const { closing, dismiss } = useDismissible(null)
  const finish = (message) => dismiss(() => onDone(message))

  const price = Number(event.price_per_person ?? 0)
  const isPaid = Number(event.total_price ?? 0) > 0 || price > 0
  const named = guests.map((guest) => guest.trim()).filter(Boolean)
  const groupSize = (isGuestRequest ? 0 : includesSelf ? 1 : 0) + named.length
  const canRegister = groupSize > 0
  const past = isPast(event)

  /// The server refuses any registration while an ended exercise in the same
  /// group is still unpaid, and names that exercise in the error's hint.
  async function handleFailure(failure) {
    if (failure.paymentOwedEventId) {
      const id = failure.paymentOwedEventId
      let title = null
      try { title = (await getEventById(id))?.name ?? null } catch {}
      setOwed({ id, title })
      setStep('owed')
      return
    }
    setError(failure.message)
  }

  async function register() {
    setBusy(true)
    setError(null)
    try {
      const expected = isPaid ? price : null
      if (isGuestRequest || !includesSelf) {
        const result = isGuestRequest
          ? await registerEventGuests(event.id, named, expected)
          : await registerEventGuestOnly(event.id, named, expected)
        if (result?.status === 'submitted') {
          setOutcome({ title: 'سُجّل ضيوفك', body: 'أضيف الضيوف إلى قائمة التمرين' })
          setStep('done')
          return
        }
        setError(GUEST_MESSAGES[result?.status] ?? 'تعذر إكمال التسجيل.')
        return
      }

      const result = await registerEventSeat(event.id, named, expected)
      const status = result?.status
      if (status === 'submitted' || status === 'already_joined') {
        setOutcome({ title: 'أنت في القائمة', body: 'اسمك مسجل في قائمة التمرين' })
        setStep('done')
        return
      }
      if (status === 'waitlisted') {
        setOutcome({ title: 'أنت في قائمة الانتظار', body: 'أول ما يتحرر مقعد ينحجز لك ويوصلك تنبيه.' })
        setStep('done')
        return
      }
      if (status === 'seats_full') { setStep('waitlist'); return }
      if (status === 'registration_closed_full') { setStep('closed'); return }
      setError(SEAT_MESSAGES[status] ?? 'تعذر إكمال التسجيل.')
    } catch (failure) {
      await handleFailure(failure)
    } finally {
      setBusy(false)
    }
  }

  async function queue() {
    setBusy(true)
    setError(null)
    try {
      await joinWaitlist(event.id, profile?.user_id)
      setOutcome({ title: 'أنت في قائمة الانتظار', body: 'أول ما يتحرر مقعد ينحجز لك ويوصلك تنبيه.' })
      setStep('done')
    } catch (failure) {
      if (failure.paymentOwedEventId) await handleFailure(failure)
      else setError('تعذر الانضمام لقائمة الانتظار.')
    } finally {
      setBusy(false)
    }
  }

  const methods = destination?.payment_methods?.length
    ? destination.payment_methods
    : destination?.provider
      ? [{
          payment_method_id: destination.payment_method_id,
          provider: destination.provider,
          mobile_number: destination.mobile_number,
          iban: destination.iban,
          account_number: destination.account_number
        }]
      : []
  const chosen = methods.find((method) => method.payment_method_id === selectedMethod) ?? methods[0] ?? null
  const dueSize = mine?.payment_group_size ?? 1 + myGuests.length
  const duePer = Number(mine?.paid_price_per_person ?? price)
  const alreadyDeclared = Boolean(mine?.payment_declared_at)

  async function declare() {
    if (!chosen) return
    setBusy(true)
    setError(null)
    try {
      const result = await declareEventPayment(event.id, chosen.payment_method_id)
      const status = result?.status
      if (status === 'declared' || status === 'nothing_due' || status === 'free_event') {
        const cash = chosen.provider === 'cash'
        setOutcome({
          title: 'سُجّل تحويلك',
          body: cash
            ? (past ? 'سُجّل سدادك للمشرف، وينتظر تأكيده' : 'تسدد للمشرف في الملعب، وينتظر تأكيده')
            : 'طلبك الآن بانتظار تأكيد وصول القطة من المشرف'
        })
        setStep('done')
        return
      }
      setError(status === 'payment_method_required' || status === 'event_terms_changed'
        ? 'تغيّرت وسائل الدفع لهذا الموعد. أغلق النافذة وافتحها مجددًا.'
        : 'تعذر تسجيل التحويل.')
    } catch (failure) {
      setError(failure.message)
    } finally {
      setBusy(false)
    }
  }

  async function copy(value, label) {
    try {
      await navigator.clipboard.writeText(value)
      setCopied(value)
      setTimeout(() => setCopied(null), 1800)
    } catch {
      setError(`ما قدرنا ننسخ ${label}. انسخه يدويًا.`)
    }
  }

  const titles = {
    seat: isGuestRequest ? 'سجّل ضيوفك' : 'سجّل في الموعد',
    payment: mode === 'pay' ? 'وسيلة الدفع' : 'وسائل الدفع',
    waitlist: 'قائمة الانتظار',
    closed: 'اكتمل العدد',
    owed: 'عليك قطة سابقة',
    done: 'تم'
  }

  return html`
    <${Sheet} title=${titles[step]} onClose=${onClose} closing=${closing}>
      ${step === 'seat' &&
      html`
        <div class="vstack change" key="seat" style="gap:12px">
          ${isGuestRequest
            ? html`
                <div class="sheet-card">
                  <${MemberAvatar} name=${profile?.name} url=${profile?.avatar_url} />
                  <span class="grow">
                    <span class="title" style="display:block">تسجيلك محفوظ مسبقًا</span>
                    <span class="sub">الطلب الجديد للضيوف فقط</span>
                  </span>
                  <span class="dot-check dot-lime"><${Icon.seal} /></span>
                </div>
              `
            : html`
                <button class="sheet-card" onClick=${() => setIncludesSelf(!includesSelf)}
                        aria-pressed=${includesSelf}>
                  <${MemberAvatar} name=${profile?.name} url=${profile?.avatar_url} />
                  <span class="grow">
                    <span class="title" style="display:block">${includesSelf ? profile?.name || 'أنا' : 'لن تُسجَّل أنت'}</span>
                    <span class="sub">${includesSelf ? 'اللاعب الأساسي' : 'اضغط لتحجز مقعدك'}</span>
                  </span>
                  <span class="pick-circle ${includesSelf ? 'on' : ''}">${includesSelf ? '✓' : ''}</span>
                </button>
              `}

          ${showGuests
            ? html`
                <div class="vstack" style="gap:9px">
                  ${guests.map(
                    (guest, index) => html`
                      <div class="hstack" style="gap:8px" key=${index}>
                        <input class="guest-field grow" placeholder="اسم اللاعب الإضافي" value=${guest}
                               onInput=${(e) => {
                                 const next = [...guests]
                                 next[index] = e.target.value
                                 setGuests(next)
                               }} />
                        <button class="guest-remove" aria-label="حذف اللاعب"
                                onClick=${() => {
                                  const next = guests.filter((_, i) => i !== index)
                                  setGuests(next)
                                  if (!next.length && !isGuestRequest) setShowGuests(false)
                                }}><${Icon.minus} /></button>
                      </div>
                    `
                  )}
                  <button class="guest-add" onClick=${() => setGuests([...guests, ''])}>+ إضافة لاعب آخر</button>
                </div>
              `
            : html`
                <button class="sheet-quiet-row" onClick=${() => { setShowGuests(true); setGuests(['']) }}>
                  <${Icon.personPlus} />
                  ${includesSelf ? 'بسجل معي أحد' : 'سجّل ضيف بدونك'}
                </button>
              `}

          ${isPaid && groupSize > 0 &&
          html`
            <div class="amount-block">
              <div class="value">${cleanAmount(price * groupSize)} <span style="font-size:18px">﷼</span></div>
              <div class="for">لعدد ${counted(groupSize, NOUNS.player)}</div>
            </div>
          `}

          ${error && html`<div class="notice notice-error">${error}</div>`}
          <button class="action action-blue" disabled=${!canRegister || busy} onClick=${register}>
            ${busy ? '…' : 'تسجيل'}
          </button>
        </div>
      `}

      ${step === 'payment' &&
      html`
        <div class="vstack change" key="payment" style="gap:12px">
          <div class="amount-block">
            <div class="value">${cleanAmount(duePer * dueSize)} <span style="font-size:18px">﷼</span></div>
            <div class="for">${alreadyDeclared ? 'المبلغ المسجل' : 'المبلغ المطلوب'}${dueSize > 1 ? ` · لعدد ${counted(dueSize, NOUNS.player)}` : ''}</div>
          </div>

          ${!methods.length
            ? html`<div class="notice notice-info">${destination ? 'لم يضف المشرف وسيلة دفع لهذا الموعد بعد.' : 'تعذر تحميل وسيلة الدفع'}</div>`
            : html`
                <div class="section-hint" style="margin:0">
                  ${alreadyDeclared ? 'راجع الوسيلة التي حوّلت إليها' : 'اختر وسيلة الدفع لعرض بياناتها'}
                </div>
                <div class="vstack" style="gap:8px">
                  ${methods.map((method) => {
                    const meta = providerOf(method.provider)
                    const active = method.payment_method_id === (chosen?.payment_method_id ?? null)
                    return html`
                      <button class="pay-method" key=${method.payment_method_id} aria-pressed=${active}
                              onClick=${() => setSelectedMethod(method.payment_method_id)}>
                        <span class="pay-logo" style=${`background:${meta.surface}`}>
                          ${meta.logo ? html`<img src=${meta.logo} alt="" />` : meta.mark}
                        </span>
                        <span class="grow">
                          <strong style="display:block">${meta.name}</strong>
                          <span class="sub">${methodSummary(method)}</span>
                        </span>
                        ${active && html`<span class="pick-circle on">✓</span>`}
                      </button>
                    `
                  })}
                </div>
              `}

          ${chosen?.provider === 'cash' &&
          html`<div class="notice notice-info">ادفع المبلغ للمشرف عند وصولك للملعب</div>`}
          ${chosen?.mobile_number &&
          html`<${CopyRow} label="رقم الجوال" value=${chosen.mobile_number} copied=${copied} onCopy=${copy} />`}
          ${chosen?.iban &&
          html`<${CopyRow} label="IBAN" value=${chosen.iban} copied=${copied} onCopy=${copy} />`}
          ${chosen?.account_number &&
          html`<${CopyRow} label="رقم الحساب" value=${chosen.account_number} copied=${copied} onCopy=${copy} />`}

          ${error && html`<div class="notice notice-error">${error}</div>`}
          ${methods.length > 0 &&
          html`<button class="action action-money" disabled=${busy} onClick=${declare}>
            ${busy ? '…' : chosen?.provider === 'cash' ? (past ? 'سددت للمشرف' : 'سأسدد في الملعب') : 'حوّلت المبلغ'}
          </button>`}
        </div>
      `}

      ${step === 'waitlist' &&
      html`
        <div class="change" key="waitlist">
          <div class="done-mark" style="background:var(--orange);color:#3a2500"><${Icon.clock} /></div>
          <div class="done-title">امتلأت المقاعد</div>
          <div class="done-sub">انضم لقائمة الانتظار، وإذا اعتذر أحد ينحجز لك مكانه تلقائيًا ويوصلك تنبيه.</div>
          ${error && html`<div class="notice notice-error" style="margin-bottom:12px">${error}</div>`}
          <button class="action action-prominent" disabled=${busy} onClick=${queue}>انضم لقائمة الانتظار</button>
        </div>
      `}

      ${step === 'closed' &&
      html`
        <div class="change" key="closed">
          <div class="done-mark" style="background:rgba(255,255,255,0.12);color:#fff"><${Icon.lock} /></div>
          <div class="done-title">قفل التسجيل</div>
          <div class="done-sub">اكتمل عدد اللاعبين، وهذا الموعد يقفل التسجيل عند الاكتمال بدون قائمة انتظار.</div>
          <button class="action action-prominent" onClick=${() => finish(null)}>حسنًا</button>
        </div>
      `}

      ${step === 'owed' &&
      html`
        <div class="change owed-step" key="owed">
          <div class="owed-mark"><${Icon.card} /></div>
          <div class="done-title">عليك قطة سابقة</div>
          <div class="owed-body">ما دفعت قطتك في ${owed?.title ?? 'تمرين سابق'}. ادفعها عشان تقدر تسجّل.</div>
          <div class="owed-note">إذا حوّلت للمنظم مباشرة، اطلب منه يأكد إنه وصلته.</div>
          <button class="action action-lime"
                  onClick=${() => dismiss(() => navigate({ name: 'event', eventId: owed.id, entry: 'pay' }, { replace: true }))}>
            ادفع الآن
          </button>
          <button class="action action-later" onClick=${() => dismiss(onClose)}>لاحقاً</button>
        </div>
      `}

      ${step === 'done' &&
      html`
        <div class="change" key="done">
          <div class="done-mark">✓</div>
          <div class="done-title">${outcome?.title}</div>
          <div class="done-sub">${outcome?.body}</div>
          <button class="action action-prominent" onClick=${() => finish(null)}>تم</button>
        </div>
      `}
    <//>
  `
}

/// The row's second line: where the money goes, masked, as the app shows it.
function methodSummary(method) {
  if (method.provider === 'cash') return 'الدفع عند الحضور'
  if (method.mobile_number) return `رقم الجوال •••• ${String(method.mobile_number).slice(-4)}`
  if (method.iban) return `IBAN •••• ${String(method.iban).slice(-4)}`
  if (method.account_number) return `رقم الحساب •••• ${String(method.account_number).slice(-4)}`
  return 'تحويل بنكي'
}

function CopyRow({ label, value, copied, onCopy }) {
  return html`
    <div class="copy-row">
      <span style="opacity:0.6;font-size:14px">${label}</span>
      <span class="value">${value}</span>
      <button onClick=${() => onCopy(value, label)}>${copied === value ? 'نُسخ' : 'نسخ'}</button>
    </div>
  `
}
