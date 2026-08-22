import { html, useEffect } from '../vendor/preact.js'

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

export const Spinner = () => html`<div class="center-pad"><div class="spinner"></div></div>`

/// The one place a person is drawn: their photo when there is one, their
/// initial when there is not.
export const MemberAvatar = ({ name, url, size }) => html`
  <div class="member-avatar" style=${size ? `width:${size}px;height:${size}px;font-size:${Math.round(size * 0.44)}px` : ''}>
    ${url ? html`<img src=${url} alt="" loading="lazy" />` : String(name ?? '؟').trim().slice(0, 1)}
  </div>
`

/// TamrinRowCard — the app's list row, used by every list that names things.
export const RowCard = ({ name, subtitle, avatarUrl, leading, accessory, onClick }) => {
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
  return onClick
    ? html`<button class="row-card" onClick=${onClick}>${inner}</button>`
    : html`<div class="row-card">${inner}</div>`
}

export const Icon = {
  menu: () => html`<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor"
      stroke-width="2.1" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>`,
  back: () => html`<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor"
      stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 5l7 7-7 7"/></svg>`,
  chevronStart: () => html`<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor"
      stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg>`,
  gear: () => html`<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor"
      stroke-width="1.7" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 13.5a7.6 7.6 0 0 0 0-3l1.7-1.3-1.9-3.3-2 .8a7.6 7.6 0 0 0-2.6-1.5L14.3 3h-3.8l-.3 2.2c-1 .3-1.8.8-2.6 1.5l-2-.8-1.9 3.3 1.7 1.3a7.6 7.6 0 0 0 0 3l-1.7 1.3 1.9 3.3 2-.8c.8.7 1.6 1.2 2.6 1.5l.3 2.2h3.8l.3-2.2c1-.3 1.8-.8 2.6-1.5l2 .8 1.9-3.3z"/></svg>`,
  plus: () => html`<svg viewBox="0 0 24 24" width="19" height="19" fill="none" stroke="currentColor"
      stroke-width="2.3" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>`,
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
  pencil: () => html`<svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4l10-10-4-4L4 16z"/></svg>`
}

/// The app's floating confirmation capsule.
export const Toast = ({ text }) => html`<div class="toast"><span>${text}</span></div>`

/// A bottom sheet. `tone` picks the surface: the event's sheets are presented
/// from a screen pinned to dark, the profile sheet follows the system.
export function Sheet({ title, subtitle, tone = 'dark', leading, trailing, onClose, children }) {
  useEffect(() => {
    const onKey = (event) => { if (event.key === 'Escape') onClose?.() }
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
      <div class="sheet-scrim" onClick=${onClose}></div>
      <div class="sheet sheet-${tone}" role="dialog" aria-modal="true" aria-label=${title ?? ''}>
        <div class="sheet-grabber"></div>
        <div class="sheet-bar">
          ${leading ?? html`<span style="min-width:44px"></span>`}
          <h2>
            ${title}
            ${subtitle && html`<span class="sub">${subtitle}</span>`}
          </h2>
          ${trailing ?? html`<button class="plain" onClick=${onClose} aria-label="إغلاق"><${Icon.close} /></button>`}
        </div>
        ${children}
      </div>
    </div>
  `
}
