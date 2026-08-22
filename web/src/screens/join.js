import { html, useState, useEffect } from '../../vendor/preact.js'
import { getInvitePreview, joinWorkspace } from '../api.js'
import { href, goBack } from '../router.js'
import { Spinner, Notice, BackIcon } from '../ui.js'
import { counted, NOUNS } from '../format.js'

/// The other end of a shared invite link. On an iPhone the same URL opens the
/// app; everywhere else it lands here.
/// A full load rather than a client-side push: Home caches the group list it
/// mounted with, and the member has just changed that list.
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
      // Home reads the last opened group from storage, so point it at the one
      // just joined before handing over.
      localStorage.setItem('tamrin.workspace', preview.id)
      openHome()
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <div class="shell">
      <div class="topbar">
        <button class="iconbtn" onClick=${goBack} aria-label="رجوع"><${BackIcon} /></button>
        <h1>دعوة</h1>
      </div>

      ${error && html`<${Notice} tone="error">${error}<//>`}
      ${!preview && !error && html`<${Spinner} />`}

      ${preview &&
      html`
        <div class="card stack" style="text-align:center">
          <div style="font-size:44px">👥</div>
          <div>
            <h2 style="margin:0 0 4px">${preview.name}</h2>
            <p class="muted" style="margin:0">
              ${preview.owner_name ? `${preview.owner_name} · ` : ''}${counted(preview.member_count, NOUNS.member)}
            </p>
          </div>
          ${preview.is_member
            ? html`
                <${Notice} tone="good">أنت عضو في هذه المجموعة أصلًا.<//>
                <button class="btn" onClick=${() => {
                  localStorage.setItem('tamrin.workspace', preview.id)
                  openHome()
                }}>افتح المجموعة</button>
              `
            : html`<button class="btn btn-lime" disabled=${busy} onClick=${join}>
                ${busy ? 'جارٍ الانضمام…' : 'انضم للمجموعة'}
              </button>`}
        </div>
      `}
    </div>
  `
}
