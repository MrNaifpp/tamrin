// Arabic wording, Western digits — the same rule the app formats against
// (Locale.tamrin in DesignSystem.swift). Every number on screen is 0123456789.
const LOCALE = 'ar-SA-u-nu-latn-ca-gregory'

const dayFormatter = new Intl.DateTimeFormat(LOCALE, { weekday: 'long' })
const dateFormatter = new Intl.DateTimeFormat(LOCALE, { day: 'numeric', month: 'long' })
const timeFormatter = new Intl.DateTimeFormat(LOCALE, { hour: 'numeric', minute: '2-digit' })

export function parseDate(raw) {
  if (!raw) return null
  const date = new Date(raw)
  return Number.isNaN(date.getTime()) ? null : date
}

export const arabicDay = (date) => (date ? dayFormatter.format(date) : '')
export const arabicDate = (date) => (date ? dateFormatter.format(date) : '')
export const arabicTime = (date) => (date ? timeFormatter.format(date) : '')

/// «يوم الأربعاء، 12 أغسطس · 9:00 م»
export function fullWhen(date) {
  if (!date) return ''
  return `${arabicDay(date)}، ${arabicDate(date)} · ${arabicTime(date)}`
}

/// A noun in the three forms Arabic needs to agree with a number, mirroring
/// ArabicNoun in Sirr/Extensions/ArabicCount.swift.
export const NOUNS = {
  player: { singular: 'لاعب', dual: 'لاعبين', plural: 'لاعبين' },
  member: { singular: 'عضو', dual: 'عضوان', plural: 'أعضاء' },
  seat: { singular: 'مقعد', dual: 'مقعدين', plural: 'مقاعد' },
  session: { singular: 'موعد', dual: 'موعدين', plural: 'مواعيد' }
}

/// 1 → «لاعب واحد», 2 → «لاعبين», 3–10 → «3 لاعبين», 11+ → «11 لاعب».
export function counted(value, noun) {
  const n = Number(value) || 0
  if (n === 1) return `${noun.singular} واحد`
  if (n === 2) return noun.dual
  const lastTwo = Math.abs(n) % 100
  return lastTwo >= 3 && lastTwo <= 10 ? `${n} ${noun.plural}` : `${n} ${noun.singular}`
}

/// An amount with at most two decimals and no trailing zeros: 25, 12.5.
export function cleanAmount(value) {
  const n = Number(value) || 0
  return new Intl.NumberFormat(LOCALE, { maximumFractionDigits: 2 }).format(n)
}

/// An Arabic or Persian keypad emits ٠١٢…٩ / ۰۱۲…۹, which no server reads as
/// digits. Fold at the edge — the moment the text is captured.
export function asciiDigits(text) {
  let out = ''
  for (const char of String(text ?? '')) {
    const code = char.codePointAt(0)
    if (code >= 48 && code <= 57) out += char
    else if (code >= 0x0660 && code <= 0x0669) out += String(code - 0x0660)
    else if (code >= 0x06f0 && code <= 0x06f9) out += String(code - 0x06f0)
  }
  return out
}

/// «هل وصلتك قطة «مشعل»؟» reads as a question between two people; the full
/// name does not.
export function firstName(name) {
  const trimmed = String(name ?? '').trim()
  return trimmed.split(/\s+/)[0] || trimmed
}

/// Two letters for an avatar with no photo behind it.
export function initials(name) {
  const parts = String(name ?? '').trim().split(/\s+/).filter(Boolean)
  if (!parts.length) return '؟'
  if (parts.length === 1) return parts[0].slice(0, 2)
  return `${parts[0][0]}${parts[1][0]}`
}

/// How long until the whistle, for the card badge. Past events read «انتهى».
export function relativeWhen(date) {
  if (!date) return ''
  const diffMs = date.getTime() - Date.now()
  if (diffMs <= 0) return 'جارٍ الآن'
  const hours = Math.round(diffMs / 3_600_000)
  if (hours < 1) return `بعد ${counted(Math.max(1, Math.round(diffMs / 60_000)), { singular: 'دقيقة', dual: 'دقيقتين', plural: 'دقائق' })}`
  if (hours < 24) return `بعد ${counted(hours, { singular: 'ساعة', dual: 'ساعتين', plural: 'ساعات' })}`
  const days = Math.round(hours / 24)
  return `بعد ${counted(days, { singular: 'يوم', dual: 'يومين', plural: 'أيام' })}`
}
