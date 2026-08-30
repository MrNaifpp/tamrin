import { useState, useCallback, useEffect } from '../vendor/preact.js'

/// Everything in the app arrives and leaves on a curve. The helpers here are
/// what let the web do the same: a screen change is a view transition rather
/// than a repaint, and a sheet is kept on screen long enough to slide out
/// instead of vanishing between two renders.

export const reduceMotion = () =>
  window.matchMedia('(prefers-reduced-motion: reduce)').matches

/// How long a sheet, drawer or toast is given to leave. Matches the exit
/// keyframes in styles.css.
export const EXIT_MS = 240

/// Runs a route change inside a View Transition, so the old screen and the new
/// one are cross-faded and any matching `view-transition-name` — the poster
/// card and the event's artwork share one — morphs between them, which is what
/// `.navigationTransition(.zoom(sourceID:))` does on the phone.
///
/// `direction` tells the stylesheet which way a push should travel: 'forward'
/// slides the incoming screen in from the leading edge, 'back' reverses it.
export function withTransition(direction, change) {
  if (reduceMotion() || !document.startViewTransition) {
    change()
    return
  }
  document.documentElement.dataset.nav = direction
  const transition = document.startViewTransition(change)
  // A transition that is skipped — a hidden tab, or a second navigation
  // starting on top of this one — rejects all three of its promises. That is a
  // normal outcome, not an error, so each is caught rather than left to
  // surface as an unhandled rejection.
  const done = () => { delete document.documentElement.dataset.nav }
  transition.ready?.catch(() => {})
  transition.updateCallbackDone?.catch(() => {})
  transition.finished.then(done, done)
}

/// Keeps a dismissible surface mounted while it plays its exit, then hands
/// control back. `closing` drives the class the exit keyframes hang off.
export function useDismissible(onClosed, duration = EXIT_MS) {
  const [closing, setClosing] = useState(false)

  const dismiss = useCallback((then) => {
    if (reduceMotion()) {
      onClosed?.()
      then?.()
      return
    }
    setClosing(true)
    setTimeout(() => {
      onClosed?.()
      then?.()
    }, duration)
  }, [onClosed, duration])

  return { closing, dismiss }
}

/// A value that should animate when it changes rather than swap in place —
/// the app's `.contentTransition(.numericText())`. Returns a key that changes
/// with the value, so the element can be re-created and re-animated.
export function useChangeKey(value) {
  const [key, setKey] = useState(0)
  const [previous, setPrevious] = useState(value)
  useEffect(() => {
    if (value !== previous) {
      setPrevious(value)
      setKey((k) => k + 1)
    }
  }, [value])
  return key
}

/// Which event's artwork the last zoom was anchored to. Home hands its card
/// the shared name on the way out; on the way back the same card takes it
/// again, so the page collapses into the card it grew from.
let zoomedEvent = null
export const setZoomedEvent = (id) => { zoomedEvent = id }
export const isZoomed = (id) => zoomedEvent != null && zoomedEvent === id
