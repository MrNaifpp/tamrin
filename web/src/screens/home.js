import { html, useState, useEffect, useCallback } from '../../vendor/preact.js'
import { getMyWorkspaces, getWorkspaceEvents, getEventParticipants, joinWorkspace } from '../api.js'
import { navigate } from '../router.js'
import { Spinner, Notice, Empty, Avatar, MenuIcon, PersonIcon, Sheet } from '../ui.js'
import { parseDate, arabicDay, arabicDate, arabicTime, relativeWhen, counted, cleanAmount, NOUNS } from '../format.js'
import { APP_STORE_URL } from '../config.js'

const LAST_WORKSPACE_KEY = 'tamrin.workspace'

/// How many rosters to pull alongside the feed. Each card wants a real
/// «3 من 16» and to know whether the reader already has a seat, and that is one
/// call per event — worth it for the cards a member actually sees, not for a
/// season's worth of them.
const ROSTER_PREFETCH_LIMIT = 12

export function HomeScreen({ session, profile }) {
  const userId = session.user.id
  const [workspaces, setWorkspaces] = useState(null)
  const [workspaceId, setWorkspaceId] = useState(() => localStorage.getItem(LAST_WORKSPACE_KEY))
  const [events, setEvents] = useState(null)
  const [rosters, setRosters] = useState({})
  const [error, setError] = useState(null)
  const [drawerOpen, setDrawerOpen] = useState(false)

  useEffect(() => {
    let live = true
    getMyWorkspaces()
      .then((list) => {
        if (!live) return
        setWorkspaces(list)
        const stillMine = list.some((workspace) => workspace.id === workspaceId)
        if (!stillMine) setWorkspaceId(list[0]?.id ?? null)
      })
      .catch((failure) => live && setError(failure.message))
    return () => { live = false }
  }, [])

  useEffect(() => {
    if (!workspaceId) return
    localStorage.setItem(LAST_WORKSPACE_KEY, workspaceId)

    let live = true
    setEvents(null)
    setRosters({})
    getWorkspaceEvents(workspaceId)
      .then(async (list) => {
        if (!live) return
        setEvents(list)
        const rosterEntries = await Promise.all(
          list.slice(0, ROSTER_PREFETCH_LIMIT).map(async (event) => {
            // A roster that fails to load must not take the feed down with it;
            // the card falls back to the seats it already knows about.
            try {
              return [event.id, await getEventParticipants(event.id)]
            } catch {
              return null
            }
          })
        )
        if (!live) return
        setRosters(Object.fromEntries(rosterEntries.filter(Boolean)))
      })
      .catch((failure) => live && setError(failure.message))
    return () => { live = false }
  }, [workspaceId])

  const current = workspaces?.find((workspace) => workspace.id === workspaceId) ?? null

  const openEvent = useCallback((eventId) => navigate({ name: 'event', eventId }), [])

  if (error) {
    return html`
      <div class="shell">
        <div class="topbar"><h1>تمرين</h1></div>
        <${Notice} tone="error">${error}<//>
      </div>
    `
  }

  if (!workspaces) return html`<div class="shell"><${Spinner} /></div>`

  return html`
    <div class="shell">
      <div class="topbar">
        <button class="iconbtn" onClick=${() => setDrawerOpen(true)} aria-label="المجموعات">
          <${MenuIcon} />
        </button>
        <h1>${current?.name ?? 'تمرين'}</h1>
        <button class="iconbtn" onClick=${() => navigate({ name: 'settings' })} aria-label="حسابي">
          ${profile?.avatar_url
            ? html`<${Avatar} name=${profile?.name} url=${profile.avatar_url} size=${42} />`
            : html`<${PersonIcon} />`}
        </button>
      </div>

      ${!workspaces.length
        ? html`<${NoGroups} onJoined=${(id) => { setWorkspaces(null); setWorkspaceId(id); getMyWorkspaces().then(setWorkspaces) }} />`
        : html`
            <${EventFeed}
              events=${events}
              rosters=${rosters}
              userId=${userId}
              onOpen=${openEvent}
            />
          `}

      ${drawerOpen &&
      html`<${GroupsDrawer}
        workspaces=${workspaces}
        currentId=${workspaceId}
        onSelect=${(id) => { setWorkspaceId(id); setDrawerOpen(false) }}
        onClose=${() => setDrawerOpen(false)}
        onJoined=${(id) => {
          setDrawerOpen(false)
          setWorkspaces(null)
          setWorkspaceId(id)
          getMyWorkspaces().then(setWorkspaces)
        }}
      />`}
    </div>
  `
}

function EventFeed({ events, rosters, userId, onOpen }) {
  if (!events) {
    return html`
      <div class="stack">
        ${[0, 1].map(() => html`<div class="skeleton" style="height:230px"></div>`)}
      </div>
    `
  }

  if (!events.length) {
    return html`
      <${Empty}
        title="ما فيه مواعيد قادمة"
        body="أول ما يفتح المشرف موعدًا جديدًا بيظهر لك هنا."
      />
    `
  }

  return html`
    <div class="stack">
      ${events.map(
        (event) => html`
          <${EventCard}
            key=${event.id}
            event=${event}
            roster=${rosters[event.id]}
            userId=${userId}
            onOpen=${() => onOpen(event.id)}
          />
        `
      )}
      <${WebLimitNote} />
    </div>
  `
}

function EventCard({ event, roster, userId, onOpen }) {
  const startAt = parseDate(event.start_date)
  const cancelled = Boolean(event.cancelled_at)
  const seats = roster?.filter((row) => !row.is_waitlisted) ?? null
  const mine = roster?.find((row) => row.user_id === userId) ?? null
  const price = Number(event.price_per_person ?? 0)

  return html`
    <button class="event-card" onClick=${onOpen}>
      <div class="event-poster">
        ${event.image_url
          ? html`<img src=${event.image_url} alt="" loading="lazy" />`
          : html`<span class="placeholder">⚽️</span>`}
        <span class="poster-badge">
          ${cancelled ? 'ملغى' : relativeWhen(startAt)}
        </span>
      </div>
      <div class="event-body">
        <h3>${event.name}</h3>
        <p class="faint" style="margin:0 0 12px">
          ${arabicDay(startAt)}، ${arabicDate(startAt)} · ${arabicTime(startAt)}
          ${event.location ? html` · ${event.location}` : null}
        </p>
        <div class="wrap">
          ${cancelled
            ? html`<span class="pill pill-danger">ملغى</span>`
            : html`<${SeatPill} seats=${seats} capacity=${event.max_participants} />`}
          ${price > 0
            ? html`<span class="pill">${cleanAmount(price)} ريال</span>`
            : html`<span class="pill pill-green">بدون رسوم</span>`}
          ${event.is_recurring ? html`<span class="pill">يتكرر</span>` : null}
          <${MyStatusPill} mine=${mine} response=${event.my_response_status} />
        </div>
      </div>
    </button>
  `
}

function SeatPill({ seats, capacity }) {
  if (!capacity) {
    return html`<span class="pill">${seats ? counted(seats.length, NOUNS.player) : 'التسجيل مفتوح'}</span>`
  }
  if (!seats) return html`<span class="pill">${capacity} ${NOUNS.seat.plural}</span>`
  const full = seats.length >= capacity
  return html`
    <span class="pill ${full ? 'pill-amber' : ''}">
      ${seats.length} من ${capacity} ${full ? '· اكتمل' : ''}
    </span>
  `
}

function MyStatusPill({ mine, response }) {
  if (mine?.is_waitlisted) return html`<span class="pill pill-amber">في قائمة الانتظار</span>`
  if (mine) {
    return mine.payment_status === 'pending' && !mine.payment_declared_at
      ? html`<span class="pill pill-amber">مكانك محفوظ · باقي السداد</span>`
      : html`<span class="pill pill-lime">مكانك محفوظ</span>`
  }
  if (response === 'declined') return html`<span class="pill pill-danger">اعتذرت</span>`
  return null
}

/// The one thing the web build says out loud about itself, and it says it once
/// — at the end of the feed, where a member who is looking for the missing
/// button will actually be.
export function WebLimitNote() {
  return html`
    <div class="notice notice-info" style="margin-top:8px">
      إنشاء المجموعات وفتح المواعيد وإدارتها تتم من تطبيق «تمرين» على الآيفون.
      نسخة الويب للأعضاء: تتابع مواعيدك، تسجّل مكانك، وتسدّد قطتك.
      <div style="margin-top:10px">
        <a class="btn btn-sm btn-quiet" href=${APP_STORE_URL} target="_blank" rel="noopener">حمّل التطبيق</a>
      </div>
    </div>
  `
}

function NoGroups({ onJoined }) {
  const [showJoin, setShowJoin] = useState(false)
  return html`
    <div>
      <${Empty}
        glyph="👋"
        title="ما أنت في أي مجموعة"
        body="اطلب من مشرف مجموعتك رابط الدعوة، والصقه هنا للانضمام."
      />
      <button class="btn" onClick=${() => setShowJoin(true)}>انضم برابط دعوة</button>
      <div style="height:12px"></div>
      <${WebLimitNote} />
      ${showJoin && html`<${JoinByCodeSheet} onClose=${() => setShowJoin(false)} onJoined=${onJoined} />`}
    </div>
  `
}

function GroupsDrawer({ workspaces, currentId, onSelect, onClose, onJoined }) {
  const [showJoin, setShowJoin] = useState(false)

  useEffect(() => {
    const onKey = (event) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return html`
    <div>
      <div class="scrim" onClick=${onClose}></div>
      <aside class="drawer" role="dialog" aria-modal="true" aria-label="المجموعات">
        <div class="spread">
          <strong>التمارين</strong>
          <button class="iconbtn" style="background:rgba(255,255,255,0.1);color:#fff"
                  onClick=${onClose} aria-label="إغلاق">✕</button>
        </div>

        <div class="stack" style="gap:10px">
          ${workspaces.map(
            (workspace) => html`
              <button
                class="drawer-row"
                key=${workspace.id}
                aria-current=${workspace.id === currentId}
                onClick=${() => onSelect(workspace.id)}
              >
                <span class="group-mark" style="width:46px;height:46px;background:${workspace.color ?? 'rgba(255,255,255,0.12)'}">
                  ${workspace.symbol ?? '⚽️'}
                </span>
                <span class="grow">
                  <span style="display:block;font-weight:500">${workspace.name}</span>
                  ${workspace.member_count != null &&
                  html`<span class="count">${counted(workspace.member_count, NOUNS.member)}</span>`}
                </span>
                ${workspace.id === currentId ? html`<span aria-hidden="true">✓</span>` : null}
              </button>
            `
          )}
        </div>

        <button class="btn btn-quiet" style="background:rgba(255,255,255,0.12);color:#fff"
                onClick=${() => setShowJoin(true)}>
          انضم برابط دعوة
        </button>

        <!-- The app's blue + lives here. On the web it is present but inert:
             a member looking for it needs to be told where it went, not to
             find nothing at all. -->
        <button class="btn btn-locked" disabled aria-disabled="true"
                title="ميزة إنشاء مجموعة موجودة في التطبيق فقط">
          ＋ إنشاء مجموعة
        </button>
        <p class="drawer-note" style="margin:0">
          ميزة إنشاء مجموعة موجودة في التطبيق فقط.
          <a href=${APP_STORE_URL} target="_blank" rel="noopener" style="color:#c2eb63">حمّل «تمرين» للآيفون</a>
        </p>

        ${showJoin && html`<${JoinByCodeSheet} onClose=${() => setShowJoin(false)} onJoined=${onJoined} />`}
      </aside>
    </div>
  `
}

/// Accepts either the bare code or the whole invite link people paste out of
/// WhatsApp — .../join/<code> is what the app shares.
export function JoinByCodeSheet({ onClose, onJoined }) {
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function submit(event) {
    event.preventDefault()
    const code = value.trim().replace(/\/+$/, '').split('/').pop()
    if (!code) {
      setError('الصق رابط الدعوة أو رمزها.')
      return
    }
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
    <${Sheet} title="انضم إلى مجموعة" subtitle="الصق رابط الدعوة الذي وصلك من المشرف." onClose=${onClose}>
      <form class="stack" onSubmit=${submit}>
        <input
          class="field"
          dir="ltr"
          placeholder="https://…/join/ABC123"
          value=${value}
          onInput=${(e) => setValue(e.target.value)}
        />
        ${error && html`<${Notice} tone="error">${error}<//>`}
        <button class="btn" type="submit" disabled=${busy}>${busy ? 'جارٍ الانضمام…' : 'انضم'}</button>
      </form>
    <//>
  `
}
