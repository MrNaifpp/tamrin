import { html, useEffect, useState } from '../vendor/preact.js'
import { useDismissible, EXIT_MS } from './motion.js'

/// Preact's own Fragment, which the standalone bundle does not export: a
/// component that renders exactly its children, so a row can hand back three
/// siblings without a wrapper element.
const Fragment = (props) => props.children

/// The three pieces of artwork the app ships with, picked by the same
/// stable hash HomeStore uses. Only the fallback now: an exercise wears a
/// photo from its sport when that sport has any.
export function artFor(id) {
  const sum = String(id).toUpperCase().split('').reduce((total, char) => total + char.codePointAt(0), 0)
  return `/assets/art/art${(sum % 3) + 1}.jpg`
}

/// The sports a group can be, in the order SportPicker lists them. The server
/// stores the key (`workspaces.sport`) and derives the SF Symbol from it; the
/// web has no SF Symbols, so each carries the nearest glyph.
export const SPORTS = [
  { key: 'soccer', name: 'كرة القدم', symbol: 'figure.soccer', glyph: '⚽️' },
  { key: 'basketball', name: 'كرة السلة', symbol: 'figure.basketball', glyph: '🏀' },
  { key: 'volleyball', name: 'الكرة الطائرة', symbol: 'figure.volleyball', glyph: '🏐' },
  { key: 'padel', name: 'البادل', symbol: 'figure.pickleball', glyph: '🎾' },
  { key: 'tennis', name: 'التنس', symbol: 'figure.tennis', glyph: '🎾' },
  { key: 'cricket', name: 'الكريكيت', symbol: 'figure.cricket', glyph: '🏏' },
  { key: 'running', name: 'الجري', symbol: 'figure.run', glyph: '🏃' },
  { key: 'cycling', name: 'الدراجات', symbol: 'figure.outdoor.cycle', glyph: '🚴' }
]

/// A group's sport key, from the column when the server sent it and from the
/// symbol otherwise — `ws.sport ?? Sport.named(ws.symbol)?.key ?? "soccer"`.
export function sportOf(workspace) {
  if (workspace?.sport) return workspace.sport
  return SPORTS.find((sport) => sport.symbol === workspace?.symbol)?.key ?? 'soccer'
}

/// Football is the only sport with positions, ratings and a pitch.
export const usesFootballFeatures = (sportKey) => sportKey === 'soccer'

/// `Sirr/SportArt/<sport>/`, copied into `assets/sport/` in the order the app
/// reads the folder (its file names, sorted), so index N is the same photo on
/// both. Sports nobody has shot for yet are absent and fall back to artFor.
const SPORT_PHOTOS = { basketball: 2, padel: 2, soccer: 5, volleyball: 4 }

/// SportArtLibrary.stableIndex: walk the uuid's sixteen bytes, not its text.
function uuidIndex(id, count) {
  const hex = String(id).replace(/-/g, '')
  if (hex.length !== 32) return 0
  let mixed = 0
  for (let i = 0; i < 32; i += 2) mixed = (mixed * 31 + parseInt(hex.slice(i, i + 2), 16)) & 0x00ffffff
  return mixed % count
}

/// The photo an exercise wears: one from its sport's folder, and otherwise the
/// artwork the app ships with. Fixed for any one exercise and the same on
/// every device, because both halves come from the server.
export function eventArt(eventId, sportKey) {
  const count = SPORT_PHOTOS[sportKey]
  if (!count) return artFor(eventId)
  const index = uuidIndex(eventId, count) + 1
  return `/assets/sport/${sportKey}/${String(index).padStart(2, '0')}.jpg`
}

/// The four positions the app offers.
export const POSITIONS = ['حارس', 'دفاع', 'وسط', 'هجوم']

/// Payment destinations, mirroring PaymentProvider in ManualPaymentModels.swift.
/// PaymentProviderLogo draws each wordmark on a square tile: white, except
/// STC Bank which sits on its own purple, and cash which is a glyph on green.
export const PROVIDERS = {
  cash: { name: 'الدفع كاش في الملعب', mark: '💵', surface: '#1f3b2c', logo: null, onDark: true },
  stc_bank: { name: 'STC Bank', mark: 'stc', surface: '#4f008c', logo: '/assets/payment/STCBank.svg' },
  barq: { name: 'برق', mark: 'برق', surface: '#ffffff', logo: '/assets/payment/Barq.svg' },
  al_rajhi: { name: 'مصرف الراجحي', mark: 'الراجحي', surface: '#ffffff', logo: '/assets/payment/AlRajhi.svg' },
  snb: { name: 'البنك الأهلي السعودي', mark: 'SNB', surface: '#ffffff', logo: '/assets/payment/SNB.svg' },
  alinma: { name: 'مصرف الإنماء', mark: 'الإنماء', surface: '#ffffff', logo: '/assets/payment/Alinma.svg' },
  riyad: { name: 'بنك الرياض', mark: 'الرياض', surface: '#ffffff', logo: '/assets/payment/Riyad.svg' }
}
export const providerOf = (raw) => PROVIDERS[raw] ?? PROVIDERS.cash

/// Workspace symbols are stored as SF Symbol names, which the web has no font
/// for, so the ones the app offers map to their nearest glyph.
const SYMBOL_GLYPHS = {
  'figure.soccer': '⚽️',
  'soccerball': '⚽️',
  'person.3.fill': '👥',
  'shield.checkered': '🛡️',
  'figure.run': '🏃',
  'basketball.fill': '🏀',
  'tennis.racket': '🎾',
  'volleyball.fill': '🏐',
  'bicycle': '🚴',
  'dumbbell.fill': '🏋️',
  ...Object.fromEntries(SPORTS.map((sport) => [sport.symbol, sport.glyph]))
}
export const symbolGlyph = (raw) => SYMBOL_GLYPHS[raw] ?? (raw && raw.length <= 2 ? raw : '⚽️')

/// Marks an <img> so it fades in on decode. Cached images are already
/// complete by the time this runs, and take the class immediately.
export const fadeInImage = (node) => {
  if (!node) return
  if (node.complete) node.classList.add('is-loaded')
  else node.addEventListener('load', () => node.classList.add('is-loaded'), { once: true })
}

export const Spinner = () => html`<div class="center-pad"><div class="spinner"></div></div>`

/// The one place a person is drawn: their photo when there is one, their
/// initial when there is not.
export const MemberAvatar = ({ name, url, size }) => html`
  <div class="member-avatar" style=${size ? `width:${size}px;height:${size}px;font-size:${Math.round(size * 0.44)}px` : ''}>
    ${url ? html`<img src=${url} alt="" loading="lazy" />` : String(name ?? '؟').trim().slice(0, 1)}
  </div>
`

/// TamrinRowCard — the app's list row, used by every list that names things.
export const RowCard = ({ name, subtitle, avatarUrl, leading, accessory, onClick, index }) => {
  const inner = html`
    <${Fragment}>
      ${leading ?? html`<${MemberAvatar} name=${name} url=${avatarUrl} />`}
      <span class="grow">
        <span class="title truncate" style="display:block">${name}</span>
        ${subtitle && html`<span class="sub truncate" style="display:block">${subtitle}</span>`}
      </span>
      ${accessory}
    <//>
  `
  const stagger = index == null ? {} : { class: 'row-card enter', style: `--i:${index}` }
  return onClick
    ? html`<button class="row-card" ...${stagger} onClick=${onClick}>${inner}</button>`
    : html`<div class="row-card" ...${stagger}>${inner}</div>`
}

export const Icon = {
  menu: () => html`<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor"
      stroke-width="2.1" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>`,
  back: () => html`<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor"
      stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>`,
  chevronStart: () => html`<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor"
      stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg>`,
  person: () => html`<svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor"><circle cx="12" cy="8" r="4"/><path d="M4 20c0-4 3.6-6 8-6s8 2 8 6z"/></svg>`,
  personPlus: () => html`<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="9.5" cy="8" r="3.4"/><path d="M3.4 20c.7-3.4 3.2-5.2 6.1-5.2 1 0 2 .2 2.8.6M17.5 13.5v6M14.5 16.5h6"/></svg>`,
  banknote: () => html`<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor"
      stroke-width="1.9"><rect x="2.6" y="6" width="18.8" height="12" rx="3"/><circle cx="12" cy="12" r="2.6"/></svg>`,
  directions: () => html`<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linejoin="round"><path d="M12 2.6 21.4 12 12 21.4 2.6 12z"/><path d="M9.4 13.6v-2.2a1.6 1.6 0 0 1 1.6-1.6h3.6" stroke-linecap="round"/><path d="M12.8 8.2 14.9 9.8 12.8 11.4" stroke-linecap="round"/></svg>`,
  seal: () => html`<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor"
      stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5 10 17l9-10"/></svg>`,
  clock: () => html`<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor"
      stroke-width="2.4" stroke-linecap="round"><circle cx="12" cy="12" r="8.6"/><path d="M12 7.4V12l3 2"/></svg>`,
  close: () => html`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor"
      stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>`,
  calendar: () => html`<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linecap="round"><rect x="3.4" y="5" width="17.2" height="15.4" rx="3"/><path d="M8 3v3.4M16 3v3.4M3.4 10h17.2"/></svg>`,
  people: () => html`<svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor"><circle cx="9" cy="8.4" r="3.3"/><circle cx="16.6" cy="9.2" r="2.6"/><path d="M2.6 19.4c.5-3.3 3.1-5 6.4-5s5.9 1.7 6.4 5z"/><path d="M16.6 13.2c2.4 0 4.2 1.2 4.8 3.6h-4z"/></svg>`,
  pencil: () => html`<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4l10-10-4-4L4 16z"/></svg>`,
  plus: () => html`<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor"
      stroke-width="2.3" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>`,
  minus: () => html`<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor"
      stroke-width="3" stroke-linecap="round"><path d="M6 12h12"/></svg>`,
  upDown: () => html`<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor"
      stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M7 9l5-5 5 5M7 15l5 5 5-5"/></svg>`,
  chevronDown: () => html`<svg viewBox="0 0 24 24" width="25" height="25" fill="none" stroke="currentColor"
      stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 10l7 4 7-4"/></svg>`,
  crown: () => html`<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor"><path d="M3 7.5l4.6 3.6L12 5l4.4 6.1L21 7.5l-1.8 10.2H4.8zM5 19.2h14v1.8H5z"/></svg>`,
  link: () => html`<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor"
      stroke-width="2.1" stroke-linecap="round"><path d="M10 14a4.2 4.2 0 0 0 6 0l3-3a4.2 4.2 0 0 0-6-6l-1 1"/><path d="M14 10a4.2 4.2 0 0 0-6 0l-3 3a4.2 4.2 0 0 0 6 6l1-1"/></svg>`,
  retry: () => html`<svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 7.5v5M12 16v.2"/><path d="M4.5 12a7.5 7.5 0 0 1 12.8-5.3L19.5 9M19.5 4.5V9H15"/><path d="M19.5 12a7.5 7.5 0 0 1-12.8 5.3L4.5 15M4.5 19.5V15H9"/></svg>`,
  history: () => html`<svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3.8 12a8.2 8.2 0 1 0 2.4-5.8L3.8 8.6M3.8 4v4.6h4.6"/><path d="M12 8v4.4l3 1.8"/></svg>`,
  details: () => html`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round"><rect x="5" y="3" width="14" height="18" rx="3"/><path d="M9 8h6M9 12h6M9 16h4"/></svg>`,
  card: () => html`<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor"
      stroke-width="1.9" stroke-linecap="round"><rect x="2.6" y="5" width="18.8" height="14" rx="3"/><path d="M2.6 9.6h18.8M6.4 15h4"/></svg>`,
  court: () => html`<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor"
      stroke-width="1.9"><rect x="3" y="5" width="18" height="14" rx="2.4"/><path d="M12 5v14"/><circle cx="12" cy="12" r="2.6"/></svg>`,
  star: () => html`<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M12 3.2l2.7 5.6 6.1.8-4.5 4.2 1.1 6.1L12 17l-5.4 2.9 1.1-6.1-4.5-4.2 6.1-.8z"/></svg>`,
  sliders: () => html`<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>`,
  lock: () => html`<svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor"><path d="M7 10V8a5 5 0 0 1 10 0v2h.6A1.8 1.8 0 0 1 19.4 11.8v7.4A1.8 1.8 0 0 1 17.6 21H6.4a1.8 1.8 0 0 1-1.8-1.8v-7.4A1.8 1.8 0 0 1 6.4 10zm2.2 0h5.6V8a2.8 2.8 0 0 0-5.6 0z"/></svg>`,
  eyeSlash: () => html`<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round"><path d="M3 3l18 18M10.6 5.2A9.6 9.6 0 0 1 12 5c5 0 9 4.6 9.8 7-.3.9-1.1 2.2-2.3 3.5M6.4 6.6C4.3 8 2.8 10.1 2.2 12c.8 2.4 4.8 7 9.8 7 1.6 0 3-.4 4.3-1.1"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>`
}

/// The app's floating confirmation capsule. It owns its own life: it shows,
/// waits, then leaves the way it came in and tells the caller it is gone.
export function Toast({ text, onDone, duration = 2400 }) {
  const [closing, setClosing] = useState(false)

  useEffect(() => {
    setClosing(false)
    const leave = setTimeout(() => setClosing(true), duration)
    const gone = setTimeout(() => onDone?.(), duration + EXIT_MS)
    return () => { clearTimeout(leave); clearTimeout(gone) }
  }, [text])

  return html`<div class="toast"><span class=${closing ? 'is-closing' : ''}>${text}</span></div>`
}



/// A bottom sheet. `tone` picks the surface: the event's sheets are presented
/// from a screen pinned to dark, the profile sheet follows the system.
/// A bottom sheet. It plays its own exit before the caller unmounts it, and a
/// flow that finishes on its own terms — «تم», a confirmed decline — passes
/// `closing` in so the same exit runs for that too.
export function Sheet({ title, subtitle, tone = 'dark', leading, trailing, onClose, closing: closingProp, children }) {
  const { closing: closingSelf, dismiss } = useDismissible(onClose)
  const closing = closingProp || closingSelf

  useEffect(() => {
    const onKey = (event) => { if (event.key === 'Escape') dismiss() }
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    window.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = previous
      window.removeEventListener('keydown', onKey)
    }
  }, [dismiss])

  return html`
    <${Fragment}>
      <div class="sheet-scrim ${closing ? 'is-closing' : ''}" onClick=${() => dismiss()}></div>
      <div class="sheet sheet-${tone} ${closing ? 'is-closing' : ''}"
           role="dialog" aria-modal="true" aria-label=${title ?? ''}>
        <div class="sheet-grabber"></div>
        <div class="sheet-bar">
          ${leading ?? html`<span style="min-width:44px"></span>`}
          <h2>
            ${title}
            ${subtitle && html`<span class="sub">${subtitle}</span>`}
          </h2>
          ${trailing ?? html`<button class="plain" onClick=${() => dismiss()} aria-label="إغلاق"><${Icon.close} /></button>`}
        </div>
        ${children}
      </div>
    <//>
  `
}


/// ArtworkPalette.averageColor: the photo's mean colour with its brightness
/// capped at 0.44, which the poster's bottom gradient is tinted with so the
/// text sits on the picture's own colour rather than on grey. Same-origin
/// images, so a 1×1 canvas can read them.
const tintCache = new Map()
export function useArtTint(src) {
  const [tint, setTint] = useState(() => tintCache.get(src) ?? '20, 20, 22')
  useEffect(() => {
    if (!src) return
    if (tintCache.has(src)) { setTint(tintCache.get(src)); return }
    let live = true
    const image = new Image()
    image.decoding = 'async'
    image.onload = () => {
      try {
        const canvas = document.createElement('canvas')
        canvas.width = canvas.height = 1
        const context = canvas.getContext('2d', { willReadFrequently: true })
        context.drawImage(image, 0, 0, 1, 1)
        let [r, g, b] = context.getImageData(0, 0, 1, 1).data
        const brightness = Math.max(r, g, b) / 255
        if (brightness > 0.44) {
          const scale = 0.44 / brightness
          r *= scale; g *= scale; b *= scale
        }
        const value = `${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)}`
        tintCache.set(src, value)
        if (live) setTint(value)
      } catch {}
    }
    image.src = src
    return () => { live = false }
  }, [src])
  return tint
}
