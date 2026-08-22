import { html, useState } from '../../vendor/preact.js'
import { saveProfile } from '../api.js'
import { POSITIONS } from '../ui.js'

/// SignupView: a first sign-in has an auth user but no row in public.users,
/// and every roster reads its name from there.
export function ProfileSetupScreen({ userId, initialName = '', onSaved }) {
  const [name, setName] = useState(initialName)
  const [position, setPosition] = useState('وسط')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit() {
    const trimmed = name.trim()
    if (!trimmed) { setError('اكتب اسمك كما يعرفك أعضاء تمرينك.'); return }
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
    <div class="app">
      <div class="light-page">
        <div class="auth-page">
          <div class="auth-avatar">👤</div>
          <h1 class="auth-title">كمــل ملفـك الشخـصي</h1>

          <div>
            <label class="field-label" style="opacity:1;color:#808080;font-size:17px" for="name">اسـم الكريـم</label>
            <input id="name" class="auth-field" placeholder="اسـم الكريـم" value=${name}
                   onInput=${(e) => setName(e.target.value)} />
          </div>

          <div>
            <span class="field-label" style="opacity:1;color:#808080;font-size:17px">المركـز المفضـل</span>
            <div class="chips">
              ${POSITIONS.map(
                (option) => html`
                  <button class="chip" style=${position === option
                      ? 'background:var(--accent-blue);color:#fff'
                      : 'background:#ebebeb;color:#333'}
                          aria-pressed=${position === option}
                          onClick=${() => setPosition(option)}>${option}</button>
                `
              )}
            </div>
          </div>

          ${error && html`<div class="auth-error">${error}</div>`}
          <div class="auth-spacer"></div>
          <button class="auth-button auth-dark" disabled=${busy} onClick=${submit}>
            ${busy ? '…' : 'التالي'}
          </button>
        </div>
      </div>
    </div>
  `
}
