import { html, useState } from '../../vendor/preact.js'
import { saveProfile } from '../api.js'
import { Notice, POSITIONS } from '../ui.js'

/// A first sign-in has an auth user but no row in public.users, and every
/// roster reads its name from there. Same two fields the app asks for.
export function ProfileSetupScreen({ userId, initialName = '', onSaved }) {
  const [name, setName] = useState(initialName)
  const [position, setPosition] = useState(POSITIONS[1].value)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit(event) {
    event.preventDefault()
    const trimmed = name.trim()
    if (trimmed.length < 2) {
      setError('اكتب اسمك كما يعرفك أعضاء مجموعتك.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await saveProfile(userId, { name: trimmed, position })
      await onSaved()
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <div class="shell">
      <div style="padding:44px 0 20px">
        <h1 class="title">عرّفنا بنفسك</h1>
        <p class="subtitle">اسمك هذا هو اللي يشوفه أعضاء مجموعتك في قائمة المسجلين.</p>
      </div>

      <form class="card stack" onSubmit=${submit}>
        <div>
          <label class="label" for="name">الاسم</label>
          <input
            id="name"
            class="field"
            type="text"
            autocomplete="name"
            placeholder="مثال: فارس"
            value=${name}
            onInput=${(e) => setName(e.target.value)}
          />
        </div>

        <div>
          <span class="label">مركزك المفضل</span>
          <div class="wrap">
            ${POSITIONS.map(
              (option) => html`
                <button
                  type="button"
                  class="chip"
                  aria-pressed=${position === option.value}
                  onClick=${() => setPosition(option.value)}
                >
                  <span class="position-dot" style="background:${option.tint};display:inline-block;margin-inline-end:6px"></span>
                  ${option.value}
                </button>
              `
            )}
          </div>
        </div>

        ${error && html`<${Notice} tone="error">${error}<//>`}
        <button class="btn" type="submit" disabled=${busy}>${busy ? 'جارٍ الحفظ…' : 'يلا نبدأ'}</button>
      </form>
    </div>
  `
}
