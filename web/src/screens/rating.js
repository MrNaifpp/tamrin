import { html, useState, useEffect } from '../../vendor/preact.js'
import { getPlayerRating, submitPlayerRating } from '../api.js'
import { Sheet, Icon, MemberAvatar } from '../ui.js'
import { useDismissible } from '../motion.js'
import { counted, NOUNS, arabicDate, arabicTime, parseDate } from '../format.js'

// Player rating, as PlayerRating.swift / PlayerRatingFlow.swift /
// PlayerDetailsSheet.swift define it. Football groups only; everything here is
// the member's own half — the anonymous crowd score and one's own vote.

export const ATTRIBUTES = [
  { key: 'pace', title: 'السرعة', short: 'سرع' },
  { key: 'passing', title: 'التمرير', short: 'تمر' },
  { key: 'shooting', title: 'التسديد', short: 'تسد' },
  { key: 'stamina', title: 'اللياقة', short: 'ليا' },
  { key: 'defending', title: 'الدفاع', short: 'دفع' },
  { key: 'awareness', title: 'الوعي الكروي', short: 'وعي' }
]

const POSITIONS = ['حارس', 'دفاع', 'وسط', 'هجوم']

/// Overall weights per position, mirrored from player_rating_overall.
const WEIGHTS = {
  'وسط': { pace: 0.10, passing: 0.30, shooting: 0.15, stamina: 0.15, defending: 0.10, awareness: 0.20 },
  'هجوم': { pace: 0.10, passing: 0.15, shooting: 0.30, stamina: 0.15, defending: 0.10, awareness: 0.20 },
  'حارس': { pace: 0.10, passing: 0.10, shooting: 0.05, stamina: 0.15, defending: 0.35, awareness: 0.25 },
  'دفاع': { pace: 0.10, passing: 0.15, shooting: 0.10, stamina: 0.15, defending: 0.30, awareness: 0.20 }
}

export function overallFor(values, position) {
  const weights = WEIGHTS[position] ?? WEIGHTS['دفاع']
  return Math.round(ATTRIBUTES.reduce((sum, { key }) => sum + (values[key] ?? 0) * weights[key], 0))
}

/// RatingBand: what the number means, and the crest's colour.
export function bandLabel(overall) {
  if (overall >= 90) return 'استثنائي'
  if (overall >= 80) return 'ممتاز'
  if (overall >= 70) return 'جيد جدًا'
  if (overall >= 60) return 'جيد'
  if (overall >= 45) return 'مقبول'
  return 'يحتاج تطوير'
}
function bandTint(overall) {
  if (overall >= 85) return 'rgb(194, 235, 99)'
  if (overall >= 70) return 'rgb(158, 219, 184)'
  if (overall >= 50) return 'rgb(250, 194, 156)'
  return 'rgb(217, 158, 140)'
}

/// RatingTint: red through amber to green as the number climbs.
const HUE_STOPS = [[0, 0], [50, 20], [70, 58], [85, 124], [95, 140], [100, 146]]
export function ratingTint(value) {
  let hue = 0
  for (let i = 1; i < HUE_STOPS.length; i++) {
    const [v0, h0] = HUE_STOPS[i - 1]
    const [v1, h1] = HUE_STOPS[i]
    if (value <= v1) { hue = h0 + ((value - v0) / (v1 - v0)) * (h1 - h0); break }
    hue = h1
  }
  return `hsl(${hue.toFixed(0)}, 78%, 56%)`
}

/// Position colours on the pitch and in tags.
export const POSITION_TINTS = {
  'هجوم': 'rgb(107, 199, 89)',
  'وسط': 'rgb(242, 184, 51)',
  'دفاع': 'rgb(222, 82, 69)',
  'حارس': 'rgb(74, 140, 230)'
}

export const PositionTag = ({ position }) => {
  const tint = POSITION_TINTS[position] ?? 'rgba(255,255,255,0.7)'
  return html`<span class="position-tag" style=${`color:${tint};background:color-mix(in srgb, ${tint} 14%, transparent)`}
                    aria-label=${`مركزه: ${position}`}>${position}</span>`
}

function ordinal(n) {
  const names = ['الأول', 'الثاني', 'الثالث', 'الرابع', 'الخامس', 'السادس', 'السابع', 'الثامن', 'التاسع', 'العاشر']
  if (n < 1) return ''
  return n <= names.length ? names[n - 1] : `رقم ${n}`
}

// ── Onboarding ────────────────────────────────────────────────────────────

const SEEN_KEY = 'rating.onboarding.seen'

export function shouldShowRatingOnboarding() {
  try { return localStorage.getItem(SEEN_KEY) !== '1' } catch { return false }
}
function markSeen() {
  try { localStorage.setItem(SEEN_KEY, '1') } catch {}
}

const ONBOARDING = [
  { title: 'ميزة جديدة، تقييم اللاعبين ✨', body: 'الآن يمديك تقييم اللاعبين اللي معك في التمرين.', media: 'video' },
  { title: 'تقييمك مستور 👀', body: 'ما يظهر لك من اللي قيّموك، ولا يظهر لهم من قيّمهم.', media: '🙈' },
  { title: 'المقياس تمرينكم', body: 'لا تقارن باللاعبين العالميين، قارن بتمرينكم.', media: '⚽️' }
]

/// RatingOnboardingSheet: three cards, once, the first time Home loads with a
/// group behind it (or just before the first rating).
export function RatingOnboarding({ onClose }) {
  const [step, setStep] = useState(0)
  const [videoFailed, setVideoFailed] = useState(false)
  const { closing, dismiss } = useDismissible(onClose)
  const card = ONBOARDING[step]
  const last = step === ONBOARDING.length - 1
  const finish = () => { markSeen(); dismiss() }

  return html`
    <div class="onboarding ${closing ? 'is-closing' : ''}" role="dialog" aria-modal="true" aria-label=${card.title}>
      ${!last && html`<button class="onboarding-skip" onClick=${finish}>تخطٍ</button>`}
      <div class="onboarding-art change" key=${step}>
        ${card.media === 'video' && !videoFailed
          ? html`<video src="/assets/media/rating-onboarding.mp4" autoplay muted loop playsinline
                        onError=${() => setVideoFailed(true)}></video>`
          : html`<span class="onboarding-glyph">${card.media === 'video' ? '⭐️' : card.media}</span>`}
      </div>
      <div class="onboarding-copy change" key=${`copy-${step}`}>
        <h1>${card.title}</h1>
        <p>${card.body}</p>
      </div>
      <div class="onboarding-dots">
        ${ONBOARDING.map((_, i) => html`<span class=${i === step ? 'on' : ''}></span>`)}
      </div>
      <button class="action onboarding-next" onClick=${() => (last ? finish() : setStep(step + 1))}>
        ${last ? 'تم' : 'التالي'}
      </button>
    </div>
  `
}

// ── The player sheet ──────────────────────────────────────────────────────

/// PlayerDetailsSheet, member side: who they are, the anonymous rating panel
/// when the group plays football, where they sit in the registration, and —
/// for a guest you added — the way to take them off the list.
///
/// `player` is { userId, name, avatarUrl, position, seatNumber, registeredBy,
/// joinedAt }.
export function PlayerSheet({ player, workspaceId, football, meId, onRemove, onClose }) {
  const canRate = football && Boolean(player.userId) && player.userId !== meId
  const canView = football && Boolean(player.userId)
  const [rating, setRating] = useState(null)
  const [loading, setLoading] = useState(canView)
  const [loadFailed, setLoadFailed] = useState(false)
  const [rateOpen, setRateOpen] = useState(false)
  const [onboarding, setOnboarding] = useState(false)
  const { closing, dismiss } = useDismissible(null)

  useEffect(() => {
    if (!canView || !workspaceId) return
    let live = true
    getPlayerRating(workspaceId, player.userId)
      .then((answer) => { if (live) setRating(answer) })
      .catch(() => { if (live) setLoadFailed(true) })
      .finally(() => { if (live) setLoading(false) })
    return () => { live = false }
  }, [player.userId, workspaceId])

  const position = POSITIONS.includes(rating?.position) ? rating.position : (POSITIONS.includes(player.position) ? player.position : null)
  const openRating = () => {
    if (shouldShowRatingOnboarding()) setOnboarding(true)
    else setRateOpen(true)
  }

  if (rateOpen) {
    return html`<${RatingFlow}
      player=${player}
      position=${position}
      existing=${rating?.mine}
      onClose=${() => setRateOpen(false)}
      onSubmit=${async (values) => {
        const answer = await submitPlayerRating(workspaceId, player.userId, values)
        if (answer?.status === 'saved') {
          setRating(answer.rating)
          setRateOpen(false)
          return null
        }
        return {
          is_self: 'ما تقدر تقيّم نفسك.',
          not_a_member: 'هذا اللاعب ما عاد عضوًا في المجموعة.',
          position_required: 'لازم يحدد اللاعب مركزه قبل التقييم.',
          out_of_range: 'قيم التقييم لازم تكون بين 0 و 100.'
        }[answer?.status] ?? 'تعذر إكمال العملية. حاول مرة أخرى.'
      }}
    />`
  }

  // Rating is a trade: whoever may rate sees the crowd's number only after
  // giving theirs. Someone who cannot rate is asked for nothing, so nothing is
  // withheld.
  const reveals = !canRate || rating?.has_rated
  const average = rating?.average
  const count = rating?.ratings_count ?? 0

  return html`
    <${Sheet} title="" onClose=${onClose} closing=${closing}>
      <div class="player-sheet vstack" style="gap:22px">
        <div class="player-identity">
          <${MemberAvatar} name=${player.name} url=${player.avatarUrl} size=${88} />
          <h2>${player.name}</h2>
          ${position && html`<${PositionTag} position=${position} />`}
        </div>

        ${canView && (reveals && average
          ? html`
              <div class="rating-panel">
                <div class="rating-head">
                  <${Crest} overall=${average.overall} size=${74} />
                  <div class="grow">
                    <div class="rating-band">${bandLabel(average.overall)}</div>
                    <div class="rating-sub">${count ? `من ${counted(count, NOUNS.rating)}` : 'بدون تقييمات'}</div>
                    ${rating?.mine && html`<div class="rating-sub">تقييمك: ${rating.mine.overall}</div>`}
                  </div>
                </div>
                <${AttributeGrid} values=${average} />
                ${canRate && position && html`
                  <button class="action action-glass" onClick=${openRating}>
                    ${rating?.has_rated ? html`<${Icon.sliders} /> عدّل تقييمك` : html`<${Icon.star} /> قيّم اللاعب`}
                  </button>`}
              </div>
            `
          : html`<${LockedPanel}
              loading=${loading && !rating}
              failed=${loadFailed}
              canRate=${canRate}
              positionRequired=${canRate && !position}
              count=${count}
              unrated=${!average}
              hasRated=${Boolean(rating?.has_rated)}
              onRate=${canRate && position ? openRating : null}
            />`)}

        <div class="vstack" style="gap:10px">
          ${player.seatNumber && html`<${FactRow} caption="ترتيبه في التسجيل" value=${ordinal(player.seatNumber)} />`}
          ${player.registeredBy && html`<${FactRow} caption="سجّله" value=${player.registeredBy} />`}
          ${player.joinedAt && html`<${FactRow} caption="سجّل يوم"
              value=${`${arabicDate(parseDate(player.joinedAt))} · ${arabicTime(parseDate(player.joinedAt))}`} />`}
        </div>

        ${onRemove && html`
          <button class="action action-remove" onClick=${() => dismiss(onRemove)}>إزالة اللاعب من التمرين</button>`}
      </div>
      ${onboarding && html`<${RatingOnboarding} onClose=${() => { setOnboarding(false); setRateOpen(true) }} />`}
    <//>
  `
}

function FactRow({ caption, value }) {
  return html`
    <div class="fact-row">
      <span class="caption">${caption}</span>
      <span class="value">${value}</span>
    </div>
  `
}

function LockedPanel({ loading, failed, canRate, positionRequired, count, unrated, hasRated, onRate }) {
  let title, caption
  if (loading) { title = 'التقييم'; caption = 'نجيب تقييمه…' }
  else if (failed) { title = 'تعذّر جلب التقييم'; caption = 'تحقق من اتصالك وحاول مرة ثانية.' }
  else if (positionRequired) { title = 'المركز مطلوب'; caption = 'لازم يحدد اللاعب مركزه قبل ما يبدأ التقييم.' }
  else if (canRate && !count) { title = 'باقي ما قُيم'; caption = 'كن أول من يقيّمه في ست معايير.' }
  else if (canRate) { title = 'قيّمه تشوف تقييمه'; caption = `عنده ${counted(count, NOUNS.rating)}. قيّمه وينفتح لك.` }
  else if (unrated) { title = 'باقي ما قُيم'; caption = 'ما وصلك أي تقييم إلى الآن. تظهر النتيجة هنا بدون أسماء المقيمين.' }
  else { title = 'التقييم'; caption = 'تقييمك مجهول ومحمي بدون أسماء المقيمين.' }

  return html`
    <div class="rating-panel">
      <div class="rating-head">
        <span class="crest crest-locked" style="width:74px;height:74px"><${Icon.lock} /></span>
        <div class="grow">
          <div class="rating-band">${title}</div>
          <div class="rating-sub">${caption}</div>
        </div>
      </div>
      ${onRate && html`
        <button class="action action-glass" onClick=${onRate}>
          ${hasRated ? html`<${Icon.sliders} /> عدّل تقييمك` : html`<${Icon.star} /> قيّم اللاعب`}
        </button>`}
    </div>
  `
}

export function Crest({ overall, size = 74 }) {
  const tint = bandTint(overall)
  return html`
    <span class="crest" style=${`width:${size}px;height:${size}px;border-radius:${size * 0.3}px;background:linear-gradient(160deg, ${tint}, color-mix(in srgb, ${tint} 70%, #000))`}>
      <span style=${`font-size:${Math.round(size * 0.42)}px`}>${overall}</span>
      <small style=${`font-size:${Math.round(size * 0.145)}px`}>الإجمالي</small>
    </span>
  `
}

function AttributeGrid({ values, onPick }) {
  return html`
    <div class="attribute-grid">
      ${ATTRIBUTES.map((attribute, i) => {
        const value = Math.round(values?.[attribute.key] ?? 0)
        const Tag = onPick ? 'button' : 'div'
        return html`
          <${Tag} class="attribute" key=${attribute.key} onClick=${onPick ? () => onPick(i) : undefined}
                  aria-label=${`${attribute.title}: ${value}`}>
            <span class="attribute-value" style=${`color:${ratingTint(value)}`}>${value}</span>
            <span class="attribute-short">${attribute.short}</span>
            <span class="attribute-bar"><span style=${`width:${value}%;background:${ratingTint(value)}`}></span></span>
          <//>
        `
      })}
    </div>
  `
}

/// PlayerRatingFlow: six attributes, one per step, each starting at 50, then
/// the summary. Revising an existing rating opens straight on the summary.
function RatingFlow({ player, position, existing, onClose, onSubmit }) {
  const [values, setValues] = useState(() =>
    Object.fromEntries(ATTRIBUTES.map(({ key }) => [key, existing?.[key] ?? 50]))
  )
  const [step, setStep] = useState(existing ? ATTRIBUTES.length : 0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const summary = step === ATTRIBUTES.length
  const attribute = ATTRIBUTES[step]
  const overall = overallFor(values, position)

  async function submit() {
    setBusy(true)
    setError(null)
    try {
      const message = await onSubmit(values)
      if (message) setError(message)
    } catch (failure) {
      setError(failure.message)
    } finally {
      setBusy(false)
    }
  }

  return html`
    <${Sheet} title="" onClose=${onClose}
              leading=${html`<button onClick=${onClose}>إلغاء</button>`}
              trailing=${step > 0
                ? html`<button onClick=${() => setStep(step - 1)} aria-label="رجوع"><${Icon.back} /></button>`
                : html`<span style="min-width:44px"></span>`}>
      <div class="rating-flow vstack" style="gap:16px">
        <div class="rating-flow-head">
          <strong>${player.name}</strong>
          ${position && html`<${PositionTag} position=${position} />`}
          <span class="grow"></span>
          <span class="step-count">${summary ? 'النتيجة' : `${step + 1} من ${ATTRIBUTES.length}`}</span>
        </div>
        <div class="step-track">
          ${ATTRIBUTES.map((_, i) => html`<span class=${i <= step ? 'on' : ''}></span>`)}
        </div>

        ${summary
          ? html`
              <div class="change vstack" key="summary" style="gap:14px;align-items:center">
                <${Crest} overall=${overall} size=${60} />
                <div class="rating-band">${bandLabel(overall)}</div>
                ${position && html`<div class="rating-sub">محسوب بأوزان مركز ${position}</div>`}
                <${AttributeGrid} values=${values} onPick=${setStep} />
                <div class="rating-note"><${Icon.eyeSlash} /> التقييمات مجهولة، واللاعب يشوف متوسط تقييمه فقط.</div>
              </div>
            `
          : html`
              <div class="change rating-step" key=${attribute.key}>
                <div class="rating-step-title">${attribute.title}</div>
                <div class="rating-number" style=${`color:${ratingTint(values[attribute.key])}`}>${values[attribute.key]}</div>
                <input class="rating-ruler" type="range" min="0" max="100" step="1" dir="ltr"
                       value=${values[attribute.key]}
                       aria-label=${attribute.title}
                       onInput=${(e) => setValues({ ...values, [attribute.key]: Number(e.target.value) })} />
              </div>
            `}

        ${error && html`<div class="notice notice-error">${error}</div>`}
        <button class="action action-rating" disabled=${busy}
                onClick=${() => (summary ? submit() : setStep(step + 1))}>
          ${summary ? (busy ? 'يُحفظ…' : 'قدّم التقييم') : step === ATTRIBUTES.length - 1 ? 'شوف النتيجة' : 'التالي'}
        </button>
      </div>
    <//>
  `
}
