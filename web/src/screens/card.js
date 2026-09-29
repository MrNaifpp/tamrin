import { html, useState } from '../../vendor/preact.js'
import { verifyCardPayment } from '../api.js'
import { DEMO } from '../fixture.js'
import { Sheet, Icon } from '../ui.js'
import { href } from '../router.js'
import { cleanAmount, asciiDigits, counted, NOUNS } from '../format.js'

// CardPaymentSheet, for the browser.
//
// The app authorizes on the device with MoyasarSdk and settles on the server;
// the web does the same thing the SDK does underneath: it POSTs the card to
// Moyasar with the publishable key create-payment handed back, `manual: true`
// so nothing is captured until verify-payment has checked the amount, the
// currency and the split, and `given_id` as the idempotency key. A card that
// needs 3-D Secure leaves the page for the bank and comes back to the
// exercise's own URL, where `resumeCardPayment` picks the payment up again.

const MOYASAR_API = 'https://api.moyasar.com/v1/payments'
const PENDING_KEY = 'tamrin.card-payment'

/// What verify-payment's answer means to the person paying.
export function verifyMessage(answer) {
  if (answer?.status === 'paid') return null
  if (answer?.status === 'processing') return 'تأخر التحقق من الدفع. سيتأكد مقعدك تلقائيًا عند وصول التأكيد.'
  if (answer?.reason === 'amount' || answer?.reason === 'recipient') return 'تعذر التحقق من الدفع. لم يُخصم أي مبلغ.'
  return 'لم تنجح عملية الدفع.'
}

/// verifyUntilSettled: Moyasar can still say `initiated` for a moment after
/// the bank returns, so ask again a few times before giving the answer.
export async function verifyUntilSettled(paymentId, moyasarId) {
  let answer = null
  for (let attempt = 0; attempt < 4; attempt++) {
    answer = await verifyCardPayment(paymentId, moyasarId)
    if (answer?.status !== 'processing') return answer
    await new Promise((resolve) => setTimeout(resolve, (attempt + 1) * 1000))
  }
  return answer
}

/// The bank sends the browser back to the exercise with `?id=…&status=…`.
/// Returns the verify answer when this page load is that return, else null.
export async function resumeCardPayment(eventId) {
  const params = new URLSearchParams(location.search)
  const moyasarId = params.get('id')
  let pending = null
  try { pending = JSON.parse(sessionStorage.getItem(PENDING_KEY) ?? 'null') } catch {}
  if (!moyasarId || !pending || pending.eventId !== eventId) return null

  sessionStorage.removeItem(PENDING_KEY)
  // Leave a clean address behind: a reload must not verify twice.
  history.replaceState(null, '', location.pathname + location.hash)

  if (params.get('status') === 'failed') {
    return { status: 'failed', reason: 'status', message: params.get('message') }
  }
  return verifyUntilSettled(pending.paymentId, moyasarId)
}

export function CardPaymentSheet({ event, quote, onClose, onPaid }) {
  const [name, setName] = useState('')
  const [number, setNumber] = useState('')
  const [expiry, setExpiry] = useState('')
  const [cvc, setCvc] = useState('')
  const [state, setState] = useState('form') // form | processing | paid | failed
  const [error, setError] = useState(null)

  const digits = asciiDigits(number)
  const [month, year] = asciiDigits(expiry).match(/^(\d{2})(\d{2})$/)?.slice(1) ?? []
  const valid = name.trim().split(/\s+/).length >= 2
    && luhn(digits) && digits.length >= 15
    && month && Number(month) >= 1 && Number(month) <= 12 && year
    && asciiDigits(cvc).length >= 3

  async function pay(submitEvent) {
    submitEvent.preventDefault()
    if (!valid || state === 'processing') return
    setState('processing')
    setError(null)
    try {
      const moyasar = DEMO ? demoAuthorize(quote) : await authorize({
        quote,
        eventId: event.id,
        card: { name: name.trim(), number: digits, month, year: `20${year}`, cvc: asciiDigits(cvc) }
      })

      // A card that needs the bank's own check leaves the page here and comes
      // back through resumeCardPayment.
      const transactionUrl = moyasar?.source?.transaction_url
      if (moyasar?.status === 'initiated' && transactionUrl) {
        sessionStorage.setItem(PENDING_KEY, JSON.stringify({ paymentId: quote.payment_id, eventId: event.id }))
        location.assign(transactionUrl)
        return
      }
      if (moyasar?.status === 'failed') {
        setState('failed')
        setError(moyasar?.source?.message ? 'لم تنجح عملية الدفع. تحقق من البطاقة وحاول مرة أخرى.' : 'لم تنجح عملية الدفع.')
        return
      }

      const answer = await verifyUntilSettled(quote.payment_id, moyasar.id)
      const message = verifyMessage(answer)
      if (message) {
        setState('failed')
        setError(message)
        return
      }
      setState('paid')
      setTimeout(() => onPaid(), 900)
    } catch (failure) {
      setState('failed')
      setError(failure.message || 'لم تنجح عملية الدفع. تحقق من البطاقة وحاول مرة أخرى.')
    }
  }

  const amount = (quote.amount ?? 0) / 100
  const busy = state === 'processing'

  return html`
    <${Sheet} title="" onClose=${busy ? () => {} : onClose}>
      <div class="vstack card-pay" style="gap:14px">
        <div class="card-amount">
          <strong>الدفع بالبطاقة</strong>
          <span class="card-event">${event.name}</span>
          <span class="card-total">${cleanAmount(amount)} ريال</span>
          ${quote.seat_count > 1 && html`<span class="card-seats">لعدد ${counted(quote.seat_count, NOUNS.player)}</span>`}
        </div>

        ${state === 'paid'
          ? html`<div class="card-state card-paid change" key="paid"><span class="dot-check dot-green"><${Icon.seal} /></span>دُفعت القطة وتأكد مقعدك</div>`
          : html`
              <form class="vstack" style="gap:10px" onSubmit=${pay}>
                <input class="guest-field" autocomplete="cc-name" placeholder="الاسم على البطاقة" dir="ltr"
                       value=${name} onInput=${(e) => setName(e.target.value)} disabled=${busy} />
                <input class="guest-field" autocomplete="cc-number" inputmode="numeric" placeholder="رقم البطاقة" dir="ltr"
                       value=${number} onInput=${(e) => setNumber(groupDigits(e.target.value))} disabled=${busy} />
                <div class="hstack" style="gap:10px">
                  <input class="guest-field grow" autocomplete="cc-exp" inputmode="numeric" placeholder="MM / YY" dir="ltr"
                         value=${expiry} onInput=${(e) => setExpiry(formatExpiry(e.target.value))} disabled=${busy} />
                  <input class="guest-field grow" autocomplete="cc-csc" inputmode="numeric" placeholder="CVC" dir="ltr"
                         maxlength="4" value=${cvc} onInput=${(e) => setCvc(asciiDigits(e.target.value))} disabled=${busy} />
                </div>
                <div class="card-networks">مدى · Visa · Mastercard</div>
                ${error && html`<div class="notice notice-error">${error}</div>`}
                <button class="action action-money" type="submit" disabled=${!valid || busy}>
                  ${busy ? 'نتحقق من الدفع…' : state === 'failed' ? 'حاول مرة أخرى' : `ادفع ${cleanAmount(amount)} ريال`}
                </button>
              </form>
            `}
      </div>
    <//>
  `
}

/// The same request the SDK builds: authorize only, keyed by given_id, with
/// the split when the group has a recipient and without the field when not.
async function authorize({ quote, eventId, card }) {
  const callback = new URL(href({ name: 'event', eventId }), location.origin).toString()
  const body = {
    given_id: quote.given_id,
    amount: quote.amount,
    currency: quote.currency ?? 'SAR',
    description: quote.description,
    callback_url: callback,
    metadata: quote.metadata ?? {},
    ...(quote.splits?.length ? { splits: quote.splits } : {}),
    source: {
      type: 'creditcard',
      name: card.name,
      number: card.number,
      month: card.month,
      year: card.year,
      cvc: card.cvc,
      '3ds': true,
      manual: true
    }
  }
  let response
  try {
    response = await fetch(MOYASAR_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Basic ${btoa(`${quote.publishable_key}:`)}`
      },
      body: JSON.stringify(body)
    })
  } catch {
    throw new Error('تعذر الاتصال بالخادم. حاول مرة أخرى.')
  }
  const payload = await response.json().catch(() => null)
  if (!response.ok) throw new Error('لم تنجح عملية الدفع. تحقق من البطاقة وحاول مرة أخرى.')
  return payload
}

/// The walkthrough never touches Moyasar: an authorized payment comes back at
/// once and the fixture's verify-payment settles it.
function demoAuthorize(quote) {
  return { id: `demo-${quote.payment_id}`, status: 'authorized', source: { type: 'creditcard' } }
}

function luhn(digits) {
  let sum = 0
  for (let i = 0; i < digits.length; i++) {
    let d = Number(digits[digits.length - 1 - i])
    if (i % 2 === 1) { d *= 2; if (d > 9) d -= 9 }
    sum += d
  }
  return digits.length > 0 && sum % 10 === 0
}

const groupDigits = (raw) => asciiDigits(raw).slice(0, 19).replace(/(\d{4})(?=\d)/g, '$1 ')

function formatExpiry(raw) {
  const digits = asciiDigits(raw).slice(0, 4)
  return digits.length > 2 ? `${digits.slice(0, 2)} / ${digits.slice(2)}` : digits
}
