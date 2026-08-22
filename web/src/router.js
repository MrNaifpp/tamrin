import { useState, useEffect } from '../vendor/preact.js'
import { withTransition } from './motion.js'

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
  if (parts[0] === 'team' && parts[1]) return { name: 'team', workspaceId: parts[1] }
  if (parts[0] === 'settings') return { name: 'settings' }
  return { name: 'home' }
}

export function href(route) {
  switch (route.name) {
    case 'event': return `${BASE}event/${encodeURIComponent(route.eventId)}${route.entry ? `/${route.entry}` : ''}`
    case 'join': return `${BASE}join/${encodeURIComponent(route.code)}`
    case 'team': return `${BASE}team/${encodeURIComponent(route.workspaceId)}`
    case 'settings': return `${BASE}settings`
    default: return BASE
  }
}

/// Which way the next route change should travel. Set by navigate/goBack and
/// consumed by the popstate listener, which is the single place a transition
/// is started — a browser back or forward button leaves it null and reads as
/// a pop.
let navDirection = null

/// Navigation is pushState when the page was served over http(s) — a plain
/// path is what makes a link shareable — and a hash otherwise.
export function navigate(route, { replace = false, direction = 'forward' } = {}) {
  const usesHash = location.protocol === 'file:' || location.hash.startsWith('#/')
  const target = usesHash ? `#/${href(route).slice(BASE.length)}` : href(route)
  navDirection = direction
  if (replace) history.replaceState(null, '', target)
  else history.pushState(null, '', target)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

export function goBack() {
  navDirection = 'back'
  if (history.length > 1) {
    history.back()
    return
  }
  navigate({ name: 'home' }, { replace: true, direction: 'back' })
}

export function useRoute() {
  const [route, setRoute] = useState(currentRoute)
  useEffect(() => {
    // popstate fires for our own navigate() and for the browser's own back
    // and forward buttons; both are animated from here.
    const sync = () => {
      const direction = navDirection ?? 'back'
      navDirection = null
      // The scroll reset belongs inside the transition: the old screen is
      // captured where the reader left it, and the new one starts at its top.
      withTransition(direction, () => {
        setRoute(currentRoute())
        window.scrollTo(0, 0)
      })
    }
    window.addEventListener('popstate', sync)
    window.addEventListener('hashchange', sync)
    return () => {
      window.removeEventListener('popstate', sync)
      window.removeEventListener('hashchange', sync)
    }
  }, [])
  return route
}
