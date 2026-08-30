import { html, useState } from '../../vendor/preact.js'
import { registerEventSeat, declareEventPayment } from '../api.js'
import { Sheet, Icon, MemberAvatar, providerOf } from '../ui.js'
import { cleanAmount, counted, NOUNS } from '../format.js'
import { useDismissible } from '../motion.js'

/// RegistrationFlowSheet. One sheet, several steps: take the seat, then — from
/// «دفع القطة» — pick the destination and say the money moved.
///
/// `mode` decides where it opens: 'register' on the seat step, 'guests' on the
/// same step with the member's own seat already taken, 'pay' straight into the
/// transfer.
const MESSAGES = {
  already_joined: 'أنت مسجّل في هذا الموعد أصلًا.',
  not_published: 'هذا الموعد ما انفتح للتسجيل بعد.',
  cancelled: 'هذا الموعد ملغى.',
  registration_closed: 'التسجيل مقفل في هذا الموعد.',
  registration_closed_full: 'اكتمل العدد، وهذا الموعد يقفل التسجيل عند الاكتمال بدون قائمة انتظار.',
  event_terms_changed: 'تغيّرت رسوم الموعد. حدّث الصفحة وجرّب من جديد.',
  free_event: 'هذا الموعد بدون رسوم.',
  payment_method_required: 'المشرف ما حدّد وسيلة دفع لهذا الموعد بعد.',
  nothing_due: 'ما عليك شيء مستحق في هذا الموعد.'
}

export function RegistrationSheet({ event, profile, destination, mine, myGuests, mode, onClose, onDone }) {
  const isGuestRequest = mode === 'guests'
  const [step, setStep] = useState(mode === 'pay' ? 'payment' : 'seat')
  const [includesSelf, setIncludesSelf] = useState(isGuestRequest)
  const [guests, setGuests] = useState(isGuestRequest ? [''] : [])
  const [showGuests, setShowGuests] = useState(isGuestRequest)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [outcome, setOutcome] = useState(null)
  const [selectedMethod, setSelectedMethod] = useState(null)
  const [copied, setCopied] = useState(null)
  /// A finished flow leaves on the same exit a tap on the scrim would give it,
  /// rather than blinking out while the page behind it reloads.
  const { closing, dismiss } = useDismissible(null)
  const finish = (message) => dismiss(() => onDone(message))

  const price = Number(event.price_per_person ?? 0)
  const isPaid = Number(event.total_price ?? 0) > 0
  const named = guests.map((guest) => guest.trim()).filter(Boolean)
  const groupSize = (isGuestRequest ? 0 : includesSelf ? 1 : 0) + named.length
  const canRegister = groupSize > 0

  async function register() {
    setBusy(true)
    setError(null)
    try {
      const result = await registerEventSeat(event.id, named, isPaid ? price : null)
      const status = result?.status
      if (status === 'submitted') {
        setOutcome({
          title: isPaid ? 'مقعدك محجوز' : 'أنت في القائمة',
          body: isPaid ? 'باقي تحويل المبلغ للمشرف من «دفع القطة».' : 'اسمك مسجل في قائمة التمرين'
        })
        setStep('done')
        return
      }
      if (status === 'waitlisted') {
        setOutcome({ title: 'أنت في قائمة الانتظار', body: 'أول ما يتحرر مقعد ينحجز لك ويوصلك تنبيه.' })
        setStep('done')
        return
      }
      setError(MESSAGES[status] ?? `تعذر التسجيل (${status}).`)
    } catch (failure) {
      setError(failure.message)
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

  async function declare() {
    if (!chosen) return
    setBusy(true)
    setError(null)
    try {
      const result = await declareEventPayment(event.id, chosen.payment_method_id)
      const status = result?.status
      if (status === 'declared') {
        setOutcome({
          title: chosen?.provider === 'cash' ? 'سجّلنا أنك بتسدد كاش' : 'أبلغنا المشرف',
          body: 'بانتظار تأكيده وصول المبلغ.'
        })
        setStep('done')
        return
      }
      setError(MESSAGES[status] ?? `تعذر تسجيل التحويل (${status}).`)
    } catch (failure) {
      setError(failure.message)
    } finally {
      setBusy(false)
    }
  }

  async function copy(value) {
    try {
      await navigator.clipboard.writeText(value)
      setCopied(value)
      setTimeout(() => setCopied(null), 1800)
    } catch {
      setError('ما قدرنا ننسخ. انسخ الرقم يدويًا.')
    }
  }

  const titles = {
    seat: isGuestRequest ? 'سجّل ضيوفك' : 'سجّل في الموعد',
    payment: 'وسائل الدفع',
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
                    <span class="title" style="display:block">تسجيلك محفوظ</span>
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
                    <span class="title" style="display:block">${profile?.name || 'أنا'}</span>
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
                                }}>−</button>
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
            <div class="for">لعدد ${counted(dueSize, NOUNS.player)}</div>
          </div>

          ${!methods.length
            ? html`<div class="notice notice-info">${MESSAGES.payment_method_required}</div>`
            : html`
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
                        <span class="grow"><strong>${meta.name}</strong></span>
                        ${active && html`<span class="pick-circle on">✓</span>`}
                      </button>
                    `
                  })}
                </div>
              `}

          ${chosen?.mobile_number &&
          html`<${CopyRow} label="رقم الجوال" value=${chosen.mobile_number} copied=${copied} onCopy=${copy} />`}
          ${chosen?.iban &&
          html`<${CopyRow} label="IBAN" value=${chosen.iban} copied=${copied} onCopy=${copy} />`}
          ${chosen?.account_number &&
          html`<${CopyRow} label="رقم الحساب" value=${chosen.account_number} copied=${copied} onCopy=${copy} />`}

          ${error && html`<div class="notice notice-error">${error}</div>`}
          ${methods.length > 0 &&
          html`<button class="action action-money" disabled=${busy} onClick=${declare}>
            ${busy ? '…' : chosen?.provider === 'cash' ? 'سأسدد في الملعب' : 'حوّلت المبلغ'}
          </button>`}
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

function CopyRow({ label, value, copied, onCopy }) {
  return html`
    <div class="copy-row">
      <span style="opacity:0.6;font-size:14px">${label}</span>
      <span class="value">${value}</span>
      <button onClick=${() => onCopy(value)}>${copied === value ? 'نُسخ' : 'نسخ'}</button>
    </div>
  `
}
