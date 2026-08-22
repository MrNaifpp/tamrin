import { useState, useEffect } from '../vendor/preact.js'

/// Routes are real paths, because the invite and event links people already
/// share are real paths: /event/<id> and /join/<code> are what the app's
/// apple-app-site-association claims, and on a non-Apple device the same URL
/// has to land here instead. A hash form (#/event/<id>) is accepted too, so
/// the site still works when it is opened from the filesystem or served
/// without a rewrite rule.

/// The directory the app is served from, so it works at the domain root and
/// under a sub-path alike.
const BASE = new URL('.', import.meta.url).pathname.replace(/src\/$/, '')

function stripBase(pathname) {
  return pathname.startsWith(BASE) ? pathname.slice(BASE.length) : pathname.replace(/^\//, '')
}

export function currentRoute() {
  const hash = location.hash.replace(/^#\/?/, '')
  const raw = hash || stripBase(location.pathname)
  const parts = raw.split('/').filter(Boolean).map(decodeURIComponent)

  if (parts[0] === 'event' && parts[1]) {
    // A third segment is the sheet the card's button asked for — «سجّل حضورك»
    // and «دفع القطة» open the detail page already on that step.
    return { name: 'event', eventId: parts[1], entry: parts[2] ?? null }
  }
  if (parts[0] === 'join' && parts[1]) return { name: 'join', code: parts[1] }
  if (parts[0] === 'settings') return { name: 'settings' }
  return { name: 'home' }
}

export function href(route) {
  switch (route.name) {
    case 'event': return `${BASE}event/${encodeURIComponent(route.eventId)}${route.entry ? `/${route.entry}` : ''}`
    case 'join': return `${BASE}join/${encodeURIComponent(route.code)}`
    case 'settings': return `${BASE}settings`
    default: return BASE
  }
}

/// Navigation is pushState when the page was served over http(s) — a plain
/// path is what makes a link shareable — and a hash otherwise.
export function navigate(route, { replace = false } = {}) {
  const usesHash = location.protocol === 'file:' || location.hash.startsWith('#/')
  const target = usesHash ? `#/${href(route).slice(BASE.length)}` : href(route)
  if (replace) history.replaceState(null, '', target)
  else history.pushState(null, '', target)
  window.dispatchEvent(new PopStateEvent('popstate'))
  window.scrollTo(0, 0)
}

export function goBack() {
  if (history.length > 1) history.back()
  else navigate({ name: 'home' }, { replace: true })
}

export function useRoute() {
  const [route, setRoute] = useState(currentRoute)
  useEffect(() => {
    const sync = () => setRoute(currentRoute())
    window.addEventListener('popstate', sync)
    window.addEventListener('hashchange', sync)
    return () => {
      window.removeEventListener('popstate', sync)
      window.removeEventListener('hashchange', sync)
    }
  }, [])
  return route
}
