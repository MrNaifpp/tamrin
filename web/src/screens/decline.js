import { html, useState, useRef } from '../../vendor/preact.js'
import { declineEvent } from '../api.js'
import { Sheet } from '../ui.js'

/// MemberDeclineSheet, both of its steps: the decision, then the reason.
/// Giving up a seat frees it for someone else, so the commitment is deliberate
/// — on the phone it takes a slide rather than a tap, and it does here too.
const REASONS = [
  { code: null, title: 'بدون سبب' },
  { code: 'traveling', title: 'مسافر' },
  { code: 'tired', title: 'تعبان' },
  { code: 'injured', title: 'مصاب' },
  { code: 'commitment', title: 'لدي ارتباط' },
  { code: 'other', title: 'أخرى', free: true }
]

export function DeclineSheet({ eventId, onClose, onDone }) {
  const [step, setStep] = useState('confirm')
  const [reason, setReason] = useState(REASONS[0])
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit() {
    setBusy(true)
    setError(null)
    try {
      await declineEvent(eventId, reason.code, reason.free ? text.trim() || null : null)
      onDone()
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  if (step === 'confirm') {
    return html`
      <${Sheet} title="الاعتذار عن الموعد" onClose=${onClose}>
        <div class="vstack" style="gap:18px;padding-bottom:6px">
          <div class="hstack" style="align-items:flex-start;gap:10px">
            <span style="color:var(--orange);font-size:18px">⚠︎</span>
            <p style="margin:0;font-size:17px;opacity:0.75">
              هل أنت متأكد من الاعتذار؟ سيتاح مكانك لبقية أعضاء التمرين، ويمكنك إضافة السبب بشكل اختياري.
            </p>
          </div>
          <${SlideToConfirm} title="اسحب لتأكيد الاعتذار" onConfirm=${() => setStep('reason')} />
        </div>
      <//>
    `
  }

  return html`
    <${Sheet}
      title="سبب الاعتذار"
      subtitle="اختياري، ويساعد المشرف يرتب الموعد"
      onClose=${onClose}
    >
      <div class="vstack">
        <div class="chips">
          ${REASONS.map(
            (option) => html`
              <button class="chip" key=${option.title}
                      aria-pressed=${reason.title === option.title}
                      onClick=${() => setReason(option)}>
                ${option.title}
              </button>
            `
          )}
        </div>
        ${reason.free &&
        html`<textarea class="guest-field" style="height:88px;border-radius:20px;padding:12px 16px;resize:none"
                       maxlength="500" placeholder="اكتب سببك"
                       value=${text} onInput=${(e) => setText(e.target.value)}></textarea>`}
        ${error && html`<div class="notice notice-error">${error}</div>`}
        <button class="action" style="background:var(--danger);color:#fff" disabled=${busy} onClick=${submit}>
          ${busy ? '…' : 'تأكيد الاعتذار'}
        </button>
      </div>
    <//>
  `
}

/// The app's slide-to-confirm: a tinted capsule with a knob that has to travel
/// most of the way before it counts.
function SlideToConfirm({ title, onConfirm }) {
  const [offset, setOffset] = useState(0)
  const [travel, setTravel] = useState(1)
  const trackRef = useRef(null)
  const KNOB = 54
  const THRESHOLD = 0.82
  const progress = offset / travel

  function start(event) {
    const track = trackRef.current
    if (!track) return
    // The knob rests on the reading edge — the right one — and travels left,
    // so the gesture is measured as distance away from where it started.
    const span = Math.max(track.clientWidth - KNOB - 8, 1)
    setTravel(span)
    const originX = event.clientX
    const clamp = (x) => Math.min(Math.max(originX - x, 0), span)

    const move = (moveEvent) => setOffset(clamp(moveEvent.clientX))
    const end = (endEvent) => {
      const finished = clamp(endEvent.clientX) / span > THRESHOLD
      setOffset(0)
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', end)
      if (finished) onConfirm()
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', end)
  }

  return html`
    <div class="slide-track" ref=${trackRef}>
      <span class="slide-label" style=${`opacity:${0.92 - progress * 0.65}`}>${title}</span>
      <span
        class="slide-knob"
        style=${`transform:translateX(${-offset}px)`}
        onPointerDown=${start}
        role="button"
        aria-label=${title}
      >${progress > 0.78 ? '✓' : '‹‹'}</span>
    </div>
  `
}
