import { html, useState } from '../../vendor/preact.js'
import { saveProfile, signOut } from '../api.js'
import { goBack } from '../router.js'
import { Notice, Avatar, BackIcon, POSITIONS } from '../ui.js'
import { APP_STORE_URL } from '../config.js'

/// Name and position, the two fields the roster reads. Photos, STC Pay number
/// and account deletion stay in the app: each is a separate upload, storage
/// policy or irreversible RPC, and none of them belongs in a first web build.
export function SettingsScreen({ session, profile, onProfileChanged }) {
  const userId = session.user.id
  const [name, setName] = useState(profile?.name ?? '')
  const [position, setPosition] = useState(profile?.postion || POSITIONS[1].value)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState(null)

  async function save(event) {
    event.preventDefault()
    const trimmed = name.trim()
    if (trimmed.length < 2) {
      setMessage({ tone: 'error', text: 'اكتب اسمك كما يعرفك أعضاء مجموعتك.' })
      return
    }
    setBusy(true)
    setMessage(null)
    try {
      await saveProfile(userId, { name: trimmed, position, avatarUrl: profile?.avatar_url ?? null })
      await onProfileChanged()
      setMessage({ tone: 'good', text: 'حُفظت بياناتك.' })
    } catch (failure) {
      setMessage({ tone: 'error', text: failure.message })
    } finally {
      setBusy(false)
    }
  }

  return html`
    <div class="shell">
      <div class="topbar">
        <button class="iconbtn" onClick=${goBack} aria-label="رجوع"><${BackIcon} /></button>
        <h1>حسابي</h1>
      </div>

      <div class="card row" style="margin-bottom:16px">
        <${Avatar} name=${profile?.name} url=${profile?.avatar_url} size=${56} />
        <div class="grow">
          <div style="font-weight:700">${profile?.name ?? 'بدون اسم'}</div>
          <div class="faint" dir="ltr" style="text-align:right">${session.user.email}</div>
        </div>
      </div>

      <form class="card stack" onSubmit=${save}>
        <div>
          <label class="label" for="name">الاسم</label>
          <input id="name" class="field" value=${name} onInput=${(e) => setName(e.target.value)} />
        </div>

        <div>
          <span class="label">مركزك المفضل</span>
          <div class="wrap">
            ${POSITIONS.map(
              (option) => html`
                <button type="button" class="chip" aria-pressed=${position === option.value}
                        onClick=${() => setPosition(option.value)}>
                  <span class="position-dot" style="background:${option.tint};display:inline-block;margin-inline-end:6px"></span>
                  ${option.value}
                </button>
              `
            )}
          </div>
        </div>

        ${message && html`<${Notice} tone=${message.tone}>${message.text}<//>`}
        <button class="btn" type="submit" disabled=${busy}>${busy ? 'جارٍ الحفظ…' : 'احفظ'}</button>
      </form>

      <div style="height:16px"></div>
      <${Notice} tone="info">
        الصورة الشخصية، رقم STC Pay، وحذف الحساب — كلها في تطبيق «تمرين» على الآيفون.
        <div style="margin-top:10px">
          <a class="btn btn-sm btn-quiet" href=${APP_STORE_URL} target="_blank" rel="noopener">حمّل التطبيق</a>
        </div>
      <//>

      <div style="height:16px"></div>
      <button class="btn btn-danger" onClick=${async () => { await signOut(); window.location.reload() }}>
        تسجيل الخروج
      </button>
    </div>
  `
}
