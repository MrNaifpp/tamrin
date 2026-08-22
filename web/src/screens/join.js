import { html, useState, useEffect } from '../../vendor/preact.js'
import { getInvitePreview, joinWorkspace } from '../api.js'
import { href, goBack } from '../router.js'
import { Spinner, Icon } from '../ui.js'
import { counted, NOUNS } from '../format.js'

/// JoinWorkspaceView — the other end of a shared invite link. On an iPhone the
/// same URL opens the app; everywhere else it lands here.
const openHome = () => { location.href = href({ name: 'home' }) }

export function JoinScreen({ code }) {
  const [preview, setPreview] = useState(null)
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let live = true
    getInvitePreview(code)
      .then((payload) => live && setPreview(payload))
      .catch((failure) => live && setError(failure.message))
    return () => { live = false }
  }, [code])

  async function join() {
    setBusy(true)
    setError(null)
    try {
      await joinWorkspace(code)
      localStorage.setItem('tamrin.workspace', preview.id)
      openHome()
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <div class="app">
      <div class="event" style="background:var(--page)">
        <button class="glass-circle event-back" onClick=${goBack} aria-label="رجوع"><${Icon.back} /></button>
        <div class="event-panel" style="padding-top:96px;min-height:100dvh">
          ${error && html`<div class="notice notice-error">${error}</div>`}
          ${!preview && !error && html`<${Spinner} />`}

          ${preview &&
          html`
            <div class="hero">
              <div style="font-size:52px">👥</div>
              <h1>${preview.name}</h1>
              <div class="when">
                ${preview.owner_name ? `${preview.owner_name} · ` : ''}${counted(preview.member_count, NOUNS.member)}
              </div>
            </div>
            <div style="height:8px"></div>
            ${preview.is_member
              ? html`
                  <div class="state-row"><span class="dot-check dot-lime">✓</span>أنت عضو في هذا التمرين أصلًا</div>
                  <button class="action action-prominent" onClick=${() => {
                    localStorage.setItem('tamrin.workspace', preview.id)
                    openHome()
                  }}>افتح التمرين</button>
                `
              : html`
                  <button class="action action-prominent" disabled=${busy} onClick=${join}>
                    ${busy ? 'جارٍ الانضمام…' : 'انضم للتمرين'}
                  </button>
                `}
          `}
        </div>
      </div>
    </div>
  `
}
