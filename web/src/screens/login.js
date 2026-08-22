import { html, useState } from '../../vendor/preact.js'
import { requestOtp, verifyOtp } from '../api.js'
import { asciiDigits } from '../format.js'
import { Notice } from '../ui.js'
import { APP_STORE_URL } from '../config.js'

/// Sign-in is the same six-digit code the app uses: one email, one code, no
/// password. Apple sign-in is deliberately absent here — it needs a web
/// Service ID configured on the Supabase project, which the app has never
/// needed, so the web build offers the one path that works everywhere.
export function LoginScreen() {
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [stage, setStage] = useState('email')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function sendCode(event) {
    event?.preventDefault()
    const address = email.trim()
    if (!address.includes('@')) {
      setError('اكتب بريدًا إلكترونيًا صحيحًا.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await requestOtp(address)
      setStage('code')
    } catch (failure) {
      setError(failure.message)
    } finally {
      setBusy(false)
    }
  }

  async function confirm(event) {
    event?.preventDefault()
    // An Arabic keypad emits ٠١٢…٩, which the server does not read as digits.
    const token = asciiDigits(code)
    if (token.length < 6) {
      setError('الرمز مكوّن من ستة أرقام.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      await verifyOtp(email.trim(), token)
      // The session lands through onAuthStateChange; the root swaps the screen.
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <div class="shell">
      <div style="padding:56px 0 26px;text-align:center">
        <div style="font-size:52px">⚽️</div>
        <h1 style="margin:10px 0 4px;font-size:30px">تمرين</h1>
        <p class="muted" style="margin:0">
          مواعيد مجموعتك وتسجيلك فيها — من أي جهاز.
        </p>
      </div>

      <div class="card stack">
        ${stage === 'email'
          ? html`
              <form onSubmit=${sendCode} class="stack">
                <div>
                  <label class="label" for="email">البريد الإلكتروني</label>
                  <input
                    id="email"
                    class="field"
                    type="email"
                    inputmode="email"
                    autocomplete="email"
                    dir="ltr"
                    placeholder="you@example.com"
                    value=${email}
                    onInput=${(e) => setEmail(e.target.value)}
                  />
                </div>
                <p class="faint" style="margin:0">
                  نرسل لك رمزًا من ستة أرقام. نفس البريد الذي تستخدمه في التطبيق يوصلك لنفس مجموعاتك.
                </p>
                ${error && html`<${Notice} tone="error">${error}<//>`}
                <button class="btn" type="submit" disabled=${busy}>
                  ${busy ? 'جارٍ الإرسال…' : 'أرسل الرمز'}
                </button>
              </form>
            `
          : html`
              <form onSubmit=${confirm} class="stack">
                <div>
                  <label class="label" for="code">الرمز المرسل إلى ${email.trim()}</label>
                  <input
                    id="code"
                    class="field code-field"
                    type="text"
                    inputmode="numeric"
                    autocomplete="one-time-code"
                    maxlength="6"
                    dir="ltr"
                    placeholder="------"
                    value=${code}
                    onInput=${(e) => setCode(e.target.value)}
                  />
                </div>
                ${error && html`<${Notice} tone="error">${error}<//>`}
                <button class="btn" type="submit" disabled=${busy}>
                  ${busy ? 'جارٍ التحقق…' : 'تأكيد'}
                </button>
                <button
                  class="btn btn-ghost"
                  type="button"
                  disabled=${busy}
                  onClick=${() => { setStage('email'); setCode(''); setError(null) }}
                >
                  غيّر البريد أو أعد الإرسال
                </button>
              </form>
            `}
      </div>

      <div class="page-foot">
        إنشاء المجموعات وإدارة المواعيد في تطبيق الآيفون ·
        <a href=${APP_STORE_URL} target="_blank" rel="noopener">حمّل «تمرين»</a>
      </div>
    </div>
  `
}
