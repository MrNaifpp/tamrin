import { html, useState, useRef } from '../../vendor/preact.js'
import { requestOtp, verifyOtp } from '../api.js'
import { asciiDigits } from '../format.js'
import { APP_STORE_URL } from '../config.js'

/// The app's three sign-in screens, in order: LoginOnbord, LoginView, then
/// LoginOTPView. Apple sign-in is the one control that cannot cross over — it
/// needs a web Service ID on the Supabase project that the app has never had —
/// so its place in the layout carries the download link instead.
export function LoginScreen() {
  const [screen, setScreen] = useState('onbord')
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const codeInput = useRef(null)

  const trimmed = email.trim()
  const emailValid = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(trimmed)

  async function sendCode() {
    setBusy(true)
    setError(null)
    try {
      await requestOtp(trimmed)
      setScreen('otp')
    } catch (failure) {
      setError(failure.message)
    } finally {
      setBusy(false)
    }
  }

  async function verify() {
    const token = asciiDigits(code)
    if (token.length < 6) return
    setBusy(true)
    setError(null)
    try {
      await verifyOtp(trimmed, token)
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  if (screen === 'onbord') {
    return html`
      <div class="app">
        <div class="light-page">
          <div class="onbord-hero">
            <span class="ball" style="font-size:54px;left:22%;top:31%">⚽</span>
            <span class="ball" style="font-size:46px;left:48%;top:21%">🎾</span>
            <span class="ball" style="font-size:50px;left:28%;top:47%">🏀</span>
            <span class="ball" style="font-size:52px;left:78%;top:27%">🏃</span>
            <span class="ball" style="font-size:48px;left:74%;top:51%">🚴</span>
            <div class="onbord-copy">
              <div class="kicker">تمريــن</div>
              <h1>تجربــة مثاليـــة</h1>
              <h1>لإدارة التماريـن</h1>
              <h1>تبـدأ <span class="green">مـن هنـــا</span></h1>
            </div>
          </div>
          <div class="onbord-foot">
            <p>أنشئ وسجِّل في التمارين بطريقة رائعة، وادفع أو اجمع القطة بسهولة.</p>
            <button class="auth-button auth-dark" onClick=${() => setScreen('email')}>
              سجل بالبريد الالكتروني
            </button>
            <a class="auth-button auth-light" href=${APP_STORE_URL} target="_blank" rel="noopener">
               تسجيل الدخول عبر Apple في التطبيق
            </a>
          </div>
        </div>
      </div>
    `
  }

  if (screen === 'email') {
    return html`
      <div class="app">
        <div class="light-page">
          <div class="auth-page">
            <div class="auth-avatar">👤</div>
            <h1 class="auth-title">سجـل بالبريـد الالكتروني</h1>
            <p class="auth-sub">سجـل أو أنشئ حسابك بالبريـد الالكتروني</p>
            <input
              class="auth-field"
              type="email"
              dir="ltr"
              inputmode="email"
              autocomplete="email"
              placeholder="example@example"
              value=${email}
              onInput=${(e) => setEmail(e.target.value)}
              onKeyDown=${(e) => { if (e.key === 'Enter' && emailValid) sendCode() }}
            />
            ${error && html`<div class="auth-error">${error}</div>`}
            <button class="auth-quiet" onClick=${() => setScreen('onbord')}>رجوع</button>
            <div class="auth-spacer"></div>
            <button class="auth-button auth-dark" disabled=${!emailValid || busy} onClick=${sendCode}>
              ${busy ? '…' : 'التالي'}
            </button>
          </div>
        </div>
      </div>
    `
  }

  const digits = asciiDigits(code).slice(0, 6)
  return html`
    <div class="app">
      <div class="light-page">
        <div class="auth-page">
          <h1 class="auth-title" style="font-size:24px;margin-top:16px">ادخل رمز التفعيل</h1>
          <p class="auth-sub">أرسلنا لك رمز تفعيل على بريدك</p>
          <div style="text-align:center;font-size:18px;font-weight:500;color:#4d4d4d" dir="ltr">${trimmed}</div>

          <div class="otp-box" onClick=${() => codeInput.current?.focus()}>
            <input
              ref=${codeInput}
              inputmode="numeric"
              autocomplete="one-time-code"
              maxlength="6"
              value=${digits}
              onInput=${(e) => setCode(asciiDigits(e.target.value).slice(0, 6))}
              onKeyDown=${(e) => { if (e.key === 'Enter') verify() }}
            />
            <div class="otp-slots">
              ${[0, 1, 2, 3, 4, 5].map(
                (slot) => html`
                  <div class="otp-slot" key=${slot}>
                    ${digits[slot] ?? html`<span class="dash"></span>`}
                  </div>
                `
              )}
            </div>
          </div>

          ${error && html`<div class="auth-error">${error}</div>`}
          <button class="auth-quiet" disabled=${busy} onClick=${sendCode}>إعادة إرسال الرمز</button>
          <div class="auth-spacer"></div>
          <button class="auth-button auth-dark" disabled=${digits.length < 6 || busy} onClick=${verify}>
            ${busy ? '…' : 'التالي'}
          </button>
        </div>
      </div>
    </div>
  `
}
