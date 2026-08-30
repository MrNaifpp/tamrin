import { html, useEffect, useState } from '../vendor/preact.js'
import { useDismissible, EXIT_MS } from './motion.js'

/// Preact's own Fragment, which the standalone bundle does not export: a
/// component that renders exactly its children, so a row can hand back three
/// siblings without a wrapper element.
const Fragment = (props) => props.children

/// The three pieces of artwork the app cycles through, picked by the same
/// stable hash HomeStore uses — so an event wears the same picture on the web
/// as it does on the phone.
export function artFor(id) {
  const sum = String(id).toUpperCase().split('').reduce((total, char) => total + char.codePointAt(0), 0)
  return `/assets/art/art${(sum % 3) + 1}.jpg`
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
  'dumbbell.fill': '🏋️'
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
      stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4l10-10-4-4L4 16z"/></svg>`
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
