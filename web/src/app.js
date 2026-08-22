import { html, render, useState, useEffect, useCallback } from '../vendor/preact.js'
import { getSession, onAuthChange, getProfile } from './api.js'
import { useRoute } from './router.js'
import { Spinner, Notice } from './ui.js'
import { LoginScreen } from './screens/login.js'
import { ProfileSetupScreen } from './screens/profile-setup.js'
import { HomeScreen } from './screens/home.js'
import { EventScreen } from './screens/event.js'
import { JoinScreen } from './screens/join.js'
import { SettingsScreen } from './screens/settings.js'

/// The member-side web build of تمرين. Everything an organizer does — creating
/// a group, opening a workout, confirming that money arrived — stays in the
/// iOS app; this is the half of the product that a member on any device needs.
function App() {
  const route = useRoute()
  const [session, setSession] = useState(undefined) // undefined = still checking
  const [profile, setProfile] = useState(undefined)
  const [error, setError] = useState(null)

  useEffect(() => {
    getSession().then(setSession).catch(() => setSession(null))
    return onAuthChange(setSession)
  }, [])

  const loadProfile = useCallback(async () => {
    if (!session) {
      setProfile(undefined)
      return
    }
    try {
      setProfile(await getProfile(session.user.id))
    } catch (failure) {
      setError(failure.message)
    }
  }, [session])

  useEffect(() => { loadProfile() }, [loadProfile])

  if (session === undefined) return html`<div class="shell"><${Spinner} /></div>`

  // A member who followed an invite or event link before signing in keeps that
  // link in the address bar, so verifying the code lands them on it — the same
  // pendingJoinCode / pendingEventId walk the app does across its login flow.
  if (!session) return html`<${LoginScreen} />`

  if (profile === undefined) return html`<div class="shell"><${Spinner} /></div>`

  if (profile === null) {
    return html`
      <${ProfileSetupScreen}
        userId=${session.user.id}
        initialName=${session.user.user_metadata?.full_name ?? ''}
        onSaved=${loadProfile}
      />
    `
  }

  const screen = () => {
    switch (route.name) {
      case 'event':
        return html`<${EventScreen} key=${route.eventId} eventId=${route.eventId} session=${session} profile=${profile} />`
      case 'join':
        return html`<${JoinScreen} key=${route.code} code=${route.code} />`
      case 'settings':
        return html`<${SettingsScreen} session=${session} profile=${profile} onProfileChanged=${loadProfile} />`
      default:
        return html`<${HomeScreen} session=${session} profile=${profile} />`
    }
  }

  return html`
    <div>
      ${error && html`<div class="shell"><${Notice} tone="error">${error}<//></div>`}
      ${screen()}
    </div>
  `
}

render(html`<${App} />`, document.getElementById('root'))
