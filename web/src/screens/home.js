import { html, useState, useEffect, useCallback, useRef } from '../../vendor/preact.js'
import { getMyWorkspaces, getWorkspaceEvents, getEventParticipants, joinWorkspace } from '../api.js'
import { navigate } from '../router.js'
import { Spinner, Icon, Sheet, Toast, MemberAvatar, artFor, symbolGlyph } from '../ui.js'
import { parseDate, arabicDay, arabicTime, cleanAmount, counted, NOUNS } from '../format.js'
import { APP_STORE_URL } from '../config.js'
import { DeclineSheet } from './decline.js'

const LAST_WORKSPACE_KEY = 'tamrin.workspace'
/// The app shows six cards on Home and loads a roster for each, which is what
/// makes «10/18» and the member's own state true on the card itself.
const FEED_LIMIT = 6

export function HomeScreen({ session, profile, onProfileChanged }) {
  const userId = session.user.id
  const [workspaces, setWorkspaces] = useState(null)
  const [workspaceId, setWorkspaceId] = useState(() => localStorage.getItem(LAST_WORKSPACE_KEY))
  const [events, setEvents] = useState(null)
  const [rosters, setRosters] = useState({})
  const [error, setError] = useState(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const [toast, setToast] = useState(null)
  const [declining, setDeclining] = useState(null)
  const [index, setIndex] = useState(0)
  const scrollRef = useRef(null)

  const loadWorkspaces = useCallback(async (preferred) => {
    const list = await getMyWorkspaces()
    setWorkspaces(list)
    const target = list.some((workspace) => workspace.id === preferred)
      ? preferred
      : list.some((workspace) => workspace.id === workspaceId) ? workspaceId : list[0]?.id ?? null
    setWorkspaceId(target)
  }, [workspaceId])

  useEffect(() => {
    loadWorkspaces().catch((failure) => setError(failure.message))
  }, [])

  const loadEvents = useCallback(async (id) => {
    const list = await getWorkspaceEvents(id)
    setEvents(list)
    const entries = await Promise.all(
      list.slice(0, FEED_LIMIT).map(async (event) => {
        try { return [event.id, await getEventParticipants(event.id)] } catch { return null }
      })
    )
    setRosters(Object.fromEntries(entries.filter(Boolean)))
  }, [])

  useEffect(() => {
    if (!workspaceId) return
    localStorage.setItem(LAST_WORKSPACE_KEY, workspaceId)
    setEvents(null)
    setRosters({})
    setIndex(0)
    loadEvents(workspaceId).catch((failure) => setError(failure.message))
  }, [workspaceId])

  // Which card is in front decides the backdrop, exactly as scrollPosition does
  // on the phone.
  const onScroll = useCallback((event) => {
    const node = event.currentTarget
    const cards = [...node.querySelectorAll('.poster')]
    const top = node.scrollTop
    let nearest = 0
    cards.forEach((card, i) => {
      if (card.offsetTop - node.offsetTop <= top + 80) nearest = i
    })
    setIndex(nearest)
  }, [])

  const current = workspaces?.find((workspace) => workspace.id === workspaceId) ?? null
  const feed = events ?? []
  const art = feed.length ? artFor(feed[Math.min(index, feed.length - 1)].id) : null

  if (error) {
    return html`
      <div class="app"><div class="home"><div class="event-panel">
        <div class="notice notice-error">${error}</div>
      </div></div></div>
    `
  }
  if (!workspaces) return html`<div class="app"><${Spinner} /></div>`

  return html`
    <div class="app ${menuOpen ? 'menu-open' : ''}">
      <div class="home">
        <div class="home-backdrop">${art && html`<img src=${art} alt="" />`}</div>

        <header class="home-header">
          <div class="home-topbar">
            <button class="glass-circle" onClick=${() => setMenuOpen(true)} aria-label="التمارين">
              <${Icon.menu} />
            </button>
            <button class="glass-pill" aria-label="تفاصيل التمرين"
                    onClick=${() => workspaceId && navigate({ name: 'team', workspaceId })}>
              <span class="name truncate">${current?.name ?? 'التمرين'}</span>
              <span class="chev"><${Icon.chevronStart} /></span>
            </button>
            <span class="grow"></span>
            <button class="avatar-button" onClick=${() => navigate({ name: 'settings' })} aria-label="الملف الشخصي">
              ${profile?.avatar_url
                ? html`<img src=${profile.avatar_url} alt="" />`
                : (profile?.name ? profile.name.trim().slice(0, 1) : html`<${Icon.person} />`)}
            </button>
          </div>
          ${feed.length > 0 &&
          html`<div class="home-section">${index === 0 ? 'الموعد الجاي' : 'المواعيد القادمة'}</div>`}
        </header>

        ${!workspaces.length
          ? html`<${NoGroups} onJoined=${(id) => { setMenuOpen(false); loadWorkspaces(id) }} />`
          : events === null
            ? html`<${Spinner} />`
            : feed.length === 0
              ? html`<${EmptySchedule} />`
              : html`
                  <div class="poster-scroll" ref=${scrollRef} onScroll=${onScroll}>
                    ${feed.slice(0, FEED_LIMIT).map(
                      (event) => html`
                        <${PosterCard}
                          key=${event.id}
                          event=${event}
                          roster=${rosters[event.id]}
                          userId=${userId}
                          onOpen=${(entry) => navigate({ name: 'event', eventId: event.id, ...(entry ? { entry } : {}) })}
                          onDecline=${() => setDeclining(event)}
                        />
                      `
                    )}
                  </div>
                `}
        ${feed.length > 1 && index === 0 && html`<div class="scroll-hint">⌄</div>`}
      </div>

      ${toast && html`<${Toast} text=${toast} />`}

      ${menuOpen &&
      html`<${TeamDrawer}
        workspaces=${workspaces}
        currentId=${workspaceId}
        profile=${profile}
        onSelect=${(id) => { setWorkspaceId(id); setMenuOpen(false) }}
        onClose=${() => setMenuOpen(false)}
        onProfile=${() => { setMenuOpen(false); navigate({ name: 'settings' }) }}
      />`}

      ${declining &&
      html`<${DeclineSheet}
        eventId=${declining.id}
        onClose=${() => setDeclining(null)}
        onDone=${async () => {
          setDeclining(null)
          setToast('سُجّل اعتذارك عن الموعد')
          setTimeout(() => setToast(null), 2600)
          await loadEvents(workspaceId)
        }}
      />`}
    </div>
  `
}

/// EventPosterCard: the artwork, the essentials, and the two decisions.
function PosterCard({ event, roster, userId, onOpen, onDecline }) {
  const startAt = parseDate(event.start_date)
  const seats = roster?.filter((row) => !row.is_waitlisted) ?? null
  const mine = roster?.find((row) => row.user_id === userId) ?? null
  const price = Number(event.price_per_person ?? 0)
  const capacity = event.max_participants
  const cancelled = Boolean(event.cancelled_at)
  const full = capacity != null && seats != null && seats.length >= capacity

  const meta = [
    event.location,
    capacity != null ? `${seats?.length ?? 0}/${capacity}` : (seats ? counted(seats.length, NOUNS.player) : null),
    price > 0 ? `${cleanAmount(price)} ﷼` : 'مجاني'
  ].filter(Boolean).join(' · ')

  const primary = cancelled
    ? null
    : mine?.is_waitlisted
      ? { title: 'قائمة الانتظار', mark: '⏳', kind: 'status', disabled: true }
      : mine
        ? (event.total_price > 0 && mine.payment_status === 'pending' && !mine.payment_declared_at
            ? { title: 'دفع القطة', mark: '﷼', kind: 'primary', entry: 'pay' }
            : mine.payment_declared_at && mine.payment_status === 'pending' && event.total_price > 0
              ? { title: 'بانتظار التأكيد', mark: '⏳', kind: 'status', disabled: true }
              : { title: 'مسجّل', mark: '✓', kind: 'status', disabled: true })
        : event.my_response_status === 'declined'
          ? { title: 'سجّل حضورك', mark: '✓', kind: 'primary', entry: 'register' }
          : full && event.capacity_policy === 'closed'
            ? { title: 'اكتمل العدد', mark: '⃠', kind: 'status', disabled: true }
            : { title: 'سجّل حضورك', mark: '✓', kind: 'primary', entry: 'register' }

  const declined = event.my_response_status === 'declined' && !mine

  return html`
    <div class="poster">
      <img src=${artFor(event.id)} alt="" loading="lazy" />
      <button
        style="position:absolute;inset:0;width:100%;height:100%"
        onClick=${() => onOpen(null)}
        aria-label=${`${event.name}، ${arabicDay(startAt)}، الساعة ${arabicTime(startAt)}`}
      ></button>

      <div class="poster-foot ${cancelled ? '' : 'has-actions'}" style="pointer-events:none">
        ${cancelled && html`<span class="poster-skipped">متخطّى</span>`}
        <h2 class="poster-title">${event.name}</h2>
        <div class="poster-when">${arabicDay(startAt)}، الساعة ${arabicTime(startAt)}</div>
        <div class="poster-meta truncate">${meta}</div>
      </div>

      ${cancelled
        ? html`
            <div class="poster-actions">
              <button class="poster-action is-disabled" disabled>
                <span class="mark status">⏭</span>
                <span>الموعد متخطّى</span>
              </button>
            </div>
          `
        : html`
            <div class="poster-actions">
              <button
                class="poster-action ${primary.disabled ? 'is-disabled' : ''}"
                disabled=${primary.disabled}
                onClick=${() => onOpen(primary.entry)}
              >
                <span class="mark ${primary.kind}">${primary.mark}</span>
                <span>${primary.title}</span>
              </button>
              <button
                class="poster-action ${declined ? 'is-disabled' : ''}"
                disabled=${declined}
                onClick=${onDecline}
              >
                <span class="mark ${declined ? 'status' : 'destructive'}">${declined ? '✓' : '✕'}</span>
                <span>${declined ? 'معتذر' : 'اعتذار'}</span>
              </button>
            </div>
          `}
    </div>
  `
}

function EmptySchedule() {
  return html`
    <div class="empty-card">
      <div class="glyph">📅</div>
      <h2>ما فيه مواعيد قادمة</h2>
      <p>المواعيد الجديدة بتظهر هنا أول ما تُنشر.</p>
    </div>
  `
}

function NoGroups({ onJoined }) {
  const [joining, setJoining] = useState(false)
  return html`
    <div style="padding:0 20px">
      <div class="empty-card" style="min-height:46dvh">
        <div class="glyph">👋</div>
        <h2>ما أنت في أي تمرين</h2>
        <p>اطلب رابط الدعوة من المشرف، والصقه هنا للانضمام.</p>
      </div>
      <div style="height:16px"></div>
      <button class="action action-prominent" onClick=${() => setJoining(true)}>انضم برابط دعوة</button>
      <div style="height:12px"></div>
      <${WebOnlyNote} />
      ${joining && html`<${JoinByCodeSheet} onClose=${() => setJoining(false)} onJoined=${onJoined} />`}
    </div>
  `
}

/// The one thing the web build says about itself, where a member who is
/// hunting for the missing button will actually be.
export function WebOnlyNote() {
  return html`
    <div class="notice notice-info">
      إنشاء التمارين وفتح المواعيد وإدارتها تتم من تطبيق «تمرين» على الآيفون.
      نسخة الويب للأعضاء: تتابع مواعيدك، تسجّل مكانك، وتسدّد قطتك.
      <div style="margin-top:10px">
        <a class="action action-glass" style="height:42px;font-size:14px" href=${APP_STORE_URL}
           target="_blank" rel="noopener">حمّل التطبيق</a>
      </div>
    </div>
  `
}

function TeamDrawer({ workspaces, currentId, profile, onSelect, onClose, onProfile }) {
  useEffect(() => {
    const onKey = (event) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const position = (profile?.postion ?? '').trim()

  return html`
    <div>
      <div class="drawer-scrim" onClick=${onClose}></div>
      <aside class="drawer" role="dialog" aria-modal="true" aria-label="التمارين">
        <!-- The app's gear and + live here. Neither has anything to do on the
             web: the gear opens the account, which the row at the foot of this
             drawer already is, and the + creates a group, which is the app's
             alone. An inert control is worse than no control, so the header is
             the title. -->
        <div class="drawer-header">
          <h2>التمارين</h2>
        </div>

        <div class="drawer-list">
          ${workspaces.map(
            (workspace) => html`
              <button
                class="team-row"
                key=${workspace.id}
                aria-current=${workspace.id === currentId}
                onClick=${() => onSelect(workspace.id)}
              >
                <span class="team-mark" style=${`background:${workspace.color ?? '#3a3a3a'}`}>
                  ${workspace.symbol ? symbolGlyph(workspace.symbol) : '⚽️'}
                </span>
                <span class="grow">
                  <span class="name truncate" style="display:block">${workspace.name}</span>
                  ${workspace.member_count != null &&
                  html`<span class="count">${counted(workspace.member_count, NOUNS.member)}</span>`}
                </span>
              </button>
            `
          )}
        </div>

        <button class="account-row" onClick=${onProfile}>
          <${MemberAvatar} name=${profile?.name} url=${profile?.avatar_url} size=${38} />
          <span class="grow">
            <span class="name truncate" style="display:block">${profile?.name || 'حسابي'}</span>
            <span class="sub truncate" style="display:block">
              ${position ? `${position} · عدّل معلوماتك` : 'عدّل اسمك ومركزك'}
            </span>
          </span>
          <span class="pencil"><${Icon.pencil} /></span>
        </button>

      </aside>
    </div>
  `
}

export function JoinByCodeSheet({ onClose, onJoined }) {
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit(event) {
    event.preventDefault()
    const code = value.trim().replace(/\/+$/, '').split('/').pop()
    if (!code) { setError('الصق رابط الدعوة أو رمزها.'); return }
    setBusy(true)
    setError(null)
    try {
      const result = await joinWorkspace(code)
      onJoined(result.workspace_id)
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <${Sheet} title="انضم إلى تمرين" subtitle="الصق رابط الدعوة الذي وصلك من المشرف" onClose=${onClose}>
      <form class="vstack" onSubmit=${submit}>
        <input class="guest-field" dir="ltr" placeholder="https://…/join/ABC123"
               value=${value} onInput=${(e) => setValue(e.target.value)} />
        ${error && html`<div class="notice notice-error">${error}</div>`}
        <button class="action action-blue" type="submit" disabled=${busy}>
          ${busy ? 'جارٍ الانضمام…' : 'انضم'}
        </button>
      </form>
    <//>
  `
}
