import { html, useState } from '../../vendor/preact.js'
import { saveProfile, signOut } from '../api.js'
import { goBack } from '../router.js'
import { POSITIONS, MemberAvatar } from '../ui.js'
import { APP_STORE_URL } from '../config.js'

/// ProfileSettingsView — the account sheet, deliberately narrow in scope: a
/// name and a pitch position. The photo, the STC Pay number and account
/// deletion stay in the app; each is an upload, a storage policy or an
/// irreversible RPC.
export function SettingsScreen({ session, profile, onProfileChanged }) {
  const userId = session.user.id
  const [name, setName] = useState(profile?.name ?? '')
  const [position, setPosition] = useState(POSITIONS.includes(profile?.postion) ? profile.postion : '')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState(null)

  const trimmed = name.trim()

  async function save() {
    if (!trimmed) return
    setBusy(true)
    setMessage(null)
    try {
      await saveProfile(userId, {
        name: trimmed,
        position: position || profile?.postion || '',
        avatarUrl: profile?.avatar_url ?? null
      })
      await onProfileChanged()
      goBack()
    } catch (failure) {
      setMessage(failure.message)
      setBusy(false)
    }
  }

  return html`
    <div class="app">
      <div class="settings-page">
        <div class="sheet-bar">
          <button class="plain" onClick=${goBack}>إلغاء</button>
          <h2>حسابي</h2>
          <button style="font-weight:700" disabled=${!trimmed || busy} onClick=${save}>حفظ</button>
        </div>

        <div class="settings-body">
          <div class="settings-avatar">
            <${MemberAvatar} name=${profile?.name} url=${profile?.avatar_url} size=${88} />
            <a class="settings-camera" href=${APP_STORE_URL} target="_blank" rel="noopener"
               title="تغيير الصورة من التطبيق">📷</a>
          </div>

          <div>
            <span class="field-label">اسمك</span>
            <input class="text-field" value=${name} onInput=${(e) => setName(e.target.value)} />
          </div>

          <div>
            <span class="field-label">مركزك في الملعب</span>
            <div class="chips">
              ${POSITIONS.map(
                (option) => html`
                  <button class="chip" aria-pressed=${position === option}
                          onClick=${() => setPosition(option)}>${option}</button>
                `
              )}
            </div>
          </div>

          ${message && html`<div class="notice notice-error">${message}</div>`}

          <div class="notice notice-info">
            الصورة الشخصية، رقم STC Pay، وحذف الحساب — كلها في تطبيق «تمرين» على الآيفون.
          </div>

          <button class="action" style="background:rgba(255,69,58,0.12);color:var(--danger)"
                  onClick=${async () => { await signOut(); location.href = '/' }}>
            تسجيل الخروج
          </button>
        </div>
      </div>
    </div>
  `
}
