import { html, useEffect } from '../vendor/preact.js'
import { initials } from './format.js'

/// The four positions the app offers, with the colour that identifies each at
/// a glance — forward green, midfield amber, defence red, keeper blue.
export const POSITIONS = [
  { value: 'حارس', tint: 'var(--pos-goalkeeper)' },
  { value: 'دفاع', tint: 'var(--pos-defender)' },
  { value: 'وسط', tint: 'var(--pos-midfielder)' },
  { value: 'هجوم', tint: 'var(--pos-forward)' }
]

export const positionTint = (raw) =>
  POSITIONS.find((p) => p.value === String(raw ?? '').trim())?.tint ?? 'var(--text-faint)'

/// Payment destinations, mirroring PaymentProvider in ManualPaymentModels.swift.
export const PROVIDERS = {
  cash: { name: 'الدفع كاش في الملعب', mark: 'كاش', color: '#1f3b2c', kind: 'cash' },
  stc_bank: { name: 'STC Bank', mark: 'stc', color: '#4f008c', kind: 'wallet' },
  barq: { name: 'برق', mark: 'برق', color: '#7338e6', kind: 'wallet' },
  al_rajhi: { name: 'مصرف الراجحي', mark: 'الراجحي', color: '#150fe0', kind: 'bank' },
  snb: { name: 'البنك الأهلي السعودي', mark: 'SNB', color: '#006b3b', kind: 'bank' },
  alinma: { name: 'مصرف الإنماء', mark: 'الإنماء', color: '#6b4d3d', kind: 'bank' },
  riyad: { name: 'بنك الرياض', mark: 'الرياض', color: '#26006e', kind: 'bank' }
}

export const providerOf = (raw) =>
  PROVIDERS[raw] ?? { name: 'وسيلة دفع', mark: '؟', color: '#3d3d3d', kind: 'bank' }

export const Spinner = () => html`<div class="center-pad"><div class="spinner"></div></div>`

export const Notice = ({ tone = '', children }) =>
  html`<div class="notice ${tone ? `notice-${tone}` : ''}">${children}</div>`

export const Empty = ({ glyph = '⚽️', title, body }) => html`
  <div class="empty">
    <div class="glyph">${glyph}</div>
    <p style="margin:0 0 4px;font-weight:700;color:var(--text)">${title}</p>
    ${body && html`<p style="margin:0;font-size:14px">${body}</p>`}
  </div>
`

export const Avatar = ({ name, url, size = 40 }) => html`
  <div class="avatar" style="width:${size}px;height:${size}px;font-size:${Math.round(size * 0.36)}px">
    ${url ? html`<img src=${url} alt="" loading="lazy" />` : initials(name)}
  </div>
`

export const BackIcon = () => html`
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
       stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M9 6l6 6-6 6" />
  </svg>
`

export const MenuIcon = () => html`
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"
       stroke-linecap="round" aria-hidden="true">
    <path d="M4 7h16M4 12h16M4 17h10" />
  </svg>
`

export const PersonIcon = () => html`
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
       stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <circle cx="12" cy="8" r="3.6" />
    <path d="M4.8 20c1-3.6 3.9-5.4 7.2-5.4s6.2 1.8 7.2 5.4" />
  </svg>
`

/// A bottom sheet. Escape and a tap on the scrim both close it, and the page
/// behind stops scrolling while it is up.
export function Sheet({ title, subtitle, onClose, children }) {
  useEffect(() => {
    const onKey = (event) => { if (event.key === 'Escape') onClose() }
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    window.addEventListener('keydown', onKey)
    return () => {
      document.body.style.overflow = previous
      window.removeEventListener('keydown', onKey)
    }
  }, [onClose])

  return html`
    <div>
      <div class="scrim" onClick=${onClose}></div>
      <div class="sheet" role="dialog" aria-modal="true" aria-label=${title ?? ''}>
        <div class="sheet-grabber"></div>
        ${title && html`<h2>${title}</h2>`}
        ${subtitle && html`<p class="sheet-sub">${subtitle}</p>`}
        ${children}
      </div>
    </div>
  `
}
