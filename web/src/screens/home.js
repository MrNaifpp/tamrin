import { html, useState, useEffect, useCallback, useRef, useMemo } from '../../vendor/preact.js'
import { getMyFeed, getWorkspacePastEvents, joinWorkspace } from '../api.js'
import { navigate } from '../router.js'
import { Spinner, Icon, Sheet, Toast, MemberAvatar, eventArt, sportOf, fadeInImage, useArtTint } from '../ui.js'
import { useDismissible, setZoomedEvent, isZoomed } from '../motion.js'
import {
  parseDate, arabicDay, arabicTime, posterWhen, archiveWhen, monthHeading, countedWorkouts,
  counted, NOUNS, isPast
} from '../format.js'
import { APP_STORE_URL } from '../config.js'
import { RatingOnboarding, shouldShowRatingOnboarding } from './rating.js'

/// DesignerHomeView. One stack of every exercise from every group the person
/// is in, nearest first — there is no group drawer any more. The group of the
/// card in front is simply the current group. The title flips the stack
/// between «القادمة» and the archive, «الماضية».
export function HomeScreen({ session, profile }) {
  const userId = session.user.id
  const [feed, setFeed] = useState(null)
  const [error, setError] = useState(null)
  const [showsPast, setShowsPast] = useState(false)
  const [past, setPast] = useState(null) // null = not loaded, { events, error }
  const [index, setIndex] = useState(0)
  const [adding, setAdding] = useState(false)
  const [joining, setJoining] = useState(false)
  const [toast, setToast] = useState(null)
  const [onboarding, setOnboarding] = useState(false)

  const load = useCallback(async () => {
    const answer = await getMyFeed()
    setFeed(answer)
    return answer
  }, [])

  useEffect(() => {
    load()
      .then((answer) => { if (answer?.workspaces?.length && shouldShowRatingOnboarding()) setOnboarding(true) })
      .catch((failure) => setError(failure.message))
    // The app refreshes the shelf whenever it comes back to the foreground;
    // a tab coming back into view is the web's version of that.
    const onVisible = () => { if (document.visibilityState === 'visible') load().catch(() => {}) }
    document.addEventListener('visibilitychange', onVisible)
    return () => document.removeEventListener('visibilitychange', onVisible)
  }, [])

  const workspaces = feed?.workspaces ?? []
  const workspaceById = useMemo(() => Object.fromEntries(workspaces.map((w) => [w.id, w])), [feed])
  const rosters = useMemo(() => {
    const byEvent = {}
    for (const row of feed?.participants ?? []) (byEvent[row.event_id] ??= []).push(row)
    return byEvent
  }, [feed])

  // The shelf: live rows across every group, nearest first. A finished card
  // leaves the moment it ends — unless it is still owed, in which case it
  // stays, and being earliest it is the first card the person sees.
  const upcoming = useMemo(() => {
    const seen = new Set()
    return (feed?.events ?? [])
      .filter((event) => (seen.has(event.id) ? false : seen.add(event.id)))
      .filter((event) => !isPast(event) || event.requires_payment_action)
      .sort((a, b) => (parseDate(a.start_date) ?? 0) - (parseDate(b.start_date) ?? 0))
  }, [feed])

  const loadPast = useCallback(async () => {
    setPast((current) => ({ events: current?.events ?? null, error: null }))
    const results = await Promise.allSettled(workspaces.map((w) => getWorkspacePastEvents(w.id)))
    const events = results.flatMap((result) => (result.status === 'fulfilled' ? result.value ?? [] : []))
    const failed = results.some((result) => result.status === 'rejected')
    const seen = new Set()
    setPast({
      events: events
        .filter((event) => (seen.has(event.id) ? false : seen.add(event.id)))
        .filter((event) => !event.requires_payment_action)
        .sort((a, b) => (parseDate(b.start_date) ?? 0) - (parseDate(a.start_date) ?? 0)),
      error: failed
        ? (events.length ? 'تعذر تحديث بعض التمارين الماضية.' : 'تعذر تحميل التمارين الماضية الآن. حاول مرة أخرى.')
        : null
    })
  }, [feed])

  // The archive loads only when it is first opened.
  useEffect(() => {
    if (showsPast && past === null && feed) loadPast()
  }, [showsPast, feed])

  const artOf = useCallback(
    (event) => eventArt(event.id, sportOf(workspaceById[event.workspace_id])),
    [workspaceById]
  )

  const shelf = showsPast ? (past?.events ?? []) : upcoming
  const front = shelf[Math.min(index, Math.max(shelf.length - 1, 0))]
  const art = front ? artOf(front) : null

  // The backdrop cross-fades over the time the app gives it, so the outgoing
  // picture fades under the incoming one rather than being swapped for it.
  const [artLayers, setArtLayers] = useState([])
  useEffect(() => {
    if (!art) return
    setArtLayers((layers) => (layers[layers.length - 1] === art ? layers : [layers[layers.length - 1], art].filter(Boolean)))
  }, [art])

  const toggle = () => {
    setIndex(0)
    setShowsPast((value) => !value)
  }

  const openEvent = (clickEvent, event) => {
    const card = clickEvent.currentTarget.closest('.poster, .archive-card')
    const image = card?.querySelector('img')
    if (image) image.style.viewTransitionName = 'event-art'
    setZoomedEvent(event.id)
    navigate({ name: 'event', eventId: event.id })
  }

  if (error) {
    return html`
      <div class="app"><div class="home"><div class="event-panel">
        <div class="notice notice-error">${error}</div>
        <button class="action action-glass" onClick=${() => { setError(null); load().catch((f) => setError(f.message)) }}>إعادة المحاولة</button>
      </div></div></div>
    `
  }
  if (!feed) return html`<div class="app"><${Spinner} /></div>`

  if (!workspaces.length) {
    return html`
      <div class="app">
        <${Welcome} profile=${profile} onJoin=${() => setJoining(true)} />
        ${joining && html`<${JoinByCodeSheet} onClose=${() => setJoining(false)}
          onJoined=${async () => { setJoining(false); await load() }} />`}
      </div>
    `
  }

  return html`
    <div class="app">
      <div class="home">
        <div class="home-backdrop">
          ${artLayers.map(
            (src, layer) => html`<img key=${src} src=${src} alt=""
                                      class=${layer === artLayers.length - 1 ? 'is-front' : ''} />`
          )}
        </div>

        <header class="home-header">
          <div class="home-topbar">
            <button class="shelf-title" onClick=${toggle}
                    aria-label=${showsPast ? 'الماضية' : 'القادمة'}
                    title=${showsPast ? 'يعرض التمارين القادمة' : 'يعرض التمارين الماضية'}>
              <span class="change" key=${showsPast ? 'past' : 'upcoming'}>${showsPast ? 'الماضية' : 'القادمة'}</span>
              <span class="shelf-chev"><${Icon.upDown} /></span>
            </button>
            <span class="grow"></span>
            <button class="glass-circle home-control" onClick=${() => setAdding(true)} aria-label="إضافة تمرين">
              <${Icon.plus} />
            </button>
            <button class="avatar-button home-control" onClick=${() => navigate({ name: 'settings' })}
                    aria-label="الملف الشخصي والإعدادات">
              ${profile?.avatar_url
                ? html`<img src=${profile.avatar_url} alt="" />`
                : (profile?.name ? profile.name.trim().slice(0, 1) : html`<${Icon.person} />`)}
            </button>
          </div>
        </header>

        <div class="change shelf-body ${shelf.length ? 'shelf-mask' : ''}" key=${showsPast ? 'past' : 'upcoming'}>
          ${showsPast
            ? html`<${PastArchive}
                past=${past}
                workspaceById=${workspaceById}
                artOf=${artOf}
                onRetry=${loadPast}
                onOpen=${openEvent}
                onFront=${setIndex}
              />`
            : upcoming.length === 0
              ? html`<${EmptySchedule} profile=${profile} />`
              : html`<${Shelf}
                  events=${upcoming}
                  rosters=${rosters}
                  workspaceById=${workspaceById}
                  userId=${userId}
                  artOf=${artOf}
                  index=${index}
                  onFront=${setIndex}
                  onOpen=${openEvent}
                />`}
        </div>
        ${!showsPast && upcoming.length > 0 && html`<div class="shelf-bottom-scrim"></div>`}
      </div>

      ${toast && html`<${Toast} text=${toast} onDone=${() => setToast(null)} />`}

      ${adding && html`<${QuickAddSheet}
        onClose=${() => setAdding(false)}
        onJoin=${() => { setAdding(false); setJoining(true) }}
      />`}

      ${joining && html`<${JoinByCodeSheet}
        onClose=${() => setJoining(false)}
        onJoined=${async () => {
          setJoining(false)
          setToast('انضممت للتمرين')
          await load()
        }}
      />`}

      ${onboarding && html`<${RatingOnboarding} onClose=${() => setOnboarding(false)} />`}
    </div>
  `
}

/// The upcoming stack: one card per swipe, the cards beneath the front one
/// dimmed to half, and a chevron nudging at the first card when there is more.
function Shelf({ events, rosters, workspaceById, userId, artOf, index, onFront, onOpen }) {
  const onScroll = useCallback((event) => {
    const node = event.currentTarget
    const cards = [...node.querySelectorAll('.poster')]
    // Measured from the first card, since the stack starts under the header.
    const base = cards[0]?.offsetTop ?? 0
    const top = node.scrollTop
    let nearest = 0
    cards.forEach((card, i) => {
      if (card.offsetTop - base <= top + 80) nearest = i
    })
    onFront(nearest)
  }, [onFront])

  return html`
    <div class="poster-scroll" onScroll=${onScroll}>
      ${events.map(
        (event, position) => html`
          <${PosterCard}
            key=${event.id}
            index=${position}
            event=${event}
            art=${artOf(event)}
            roster=${rosters[event.id] ?? []}
            isOwner=${workspaceById[event.workspace_id]?.owner_id === userId}
            dimmed=${position > index}
            onOpen=${(clickEvent) => onOpen(clickEvent, event)}
          />
        `
      )}
    </div>
    ${events.length > 1 && index === 0 && html`<div class="scroll-hint"><${Icon.chevronDown} /></div>`}
  `
}

/// EventPosterCard, given back to the poster: artwork, who is coming, the
/// name, when and where. Every decision lives on the exercise page now, so
/// the whole card is one button into it.
function PosterCard({ event, art, roster, isOwner, index = 0, dimmed, onOpen }) {
  const startAt = parseDate(event.start_date)
  const cancelled = Boolean(event.cancelled_at)
  const seated = roster.filter((row) => !row.is_waitlisted)
  const capacity = event.max_participants ?? 0
  const tint = useArtTint(art)

  return html`
    <button
      class="poster enter ${dimmed ? 'is-dimmed' : ''}"
      style=${`--i:${index};--tint:${tint}`}
      onClick=${onOpen}
      aria-label=${`${event.name}، ${arabicDay(startAt)}، الساعة ${arabicTime(startAt)}`}
      aria-description=${`${seated.length} من ${capacity || seated.length} مسجلين`}
    >
      <img class="fade-img" ref=${fadeInImage} src=${art} alt="" loading="lazy"
           style=${isZoomed(event.id) ? 'view-transition-name:event-art' : ''} />
      <img class="poster-blur" src=${art} alt="" aria-hidden="true" loading="lazy" />
      <span class="poster-tint"></span>

      ${isOwner && html`<span class="supervisor-tag" aria-label="أنت مشرف هذا التمرين"><${Icon.crown} /> مشرف</span>`}

      <span class="poster-foot">
        ${cancelled && html`<span class="poster-skipped">متخطّى</span>`}
        <${AvatarCluster} eventId=${event.id} seated=${seated} />
        <span class="poster-title">${event.name}</span>
        <span class="poster-when">${posterWhen(startAt)}</span>
        ${event.location?.trim() && html`<span class="poster-location truncate">${event.location}</span>`}
      </span>
    </button>
  `
}

/// RosterAvatarCluster: the first nine seated players by join order, sized
/// by tier (50 / 38 / 29), packed into a loose cloud whose shape is fixed per
/// exercise. With nobody seated there is nothing to draw.
function AvatarCluster({ eventId, seated }) {
  const people = [...seated]
    .sort((a, b) => (parseDate(a.joined_at) ?? 0) - (parseDate(b.joined_at) ?? 0))
    .slice(0, 9)
  const layout = useMemo(() => packCluster(eventId, people.length), [eventId, people.length])
  if (!people.length) return null

  return html`
    <span class="avatar-cluster" style=${`width:${layout.width}px;height:${layout.height}px`}
          aria-label=${`المسجلون: ${counted(seated.length, NOUNS.player)}`}>
      ${people.map((person, i) => {
        const spot = layout.spots[i]
        const name = person.display_name ?? person.guest_name ?? 'لاعب'
        return html`
          <span class="cluster-avatar" key=${person.participant_id}
                style=${`width:${spot.size}px;height:${spot.size}px;left:${spot.x - spot.size / 2}px;top:${spot.y - spot.size / 2}px;font-size:${Math.round(spot.size * 0.4)}px;--i:${i}`}>
            ${person.avatar_url ? html`<img src=${person.avatar_url} alt="" loading="lazy" />` : name.trim().slice(0, 1)}
          </span>
        `
      })}
    </span>
  `
}

/// A deterministic loose packing: circles start on a seeded spiral and are
/// relaxed apart, so the same exercise always draws the same cloud.
function packCluster(eventId, count) {
  const sizes = Array.from({ length: count }, (_, i) => (i < 3 ? 50 : i < 6 ? 38 : 29))
  let seed = 0
  for (const char of String(eventId).replace(/-/g, '')) seed = (seed * 31 + parseInt(char, 16)) >>> 0
  seed ||= 0x9e3779b9
  const random = () => {
    seed ^= seed << 13; seed >>>= 0
    seed ^= seed >>> 17
    seed ^= seed << 5; seed >>>= 0
    return seed / 0xffffffff
  }
  const spots = sizes.map((size, i) => {
    const angle = i * 2.4 + random() * 0.8
    const radius = i === 0 ? 0 : 18 + i * 7
    return { size, x: Math.cos(angle) * radius, y: Math.sin(angle) * radius * 0.62 }
  })
  // Pull everyone gently to the middle first, then settle the overlaps with
  // no pull at all, so the last word is always "nobody overlaps".
  for (let pass = 0; pass < 140; pass++) {
    const pull = pass < 60 ? 0.96 : 1
    for (const spot of spots) { spot.x *= pull; spot.y *= pull }
    for (let a = 0; a < spots.length; a++) {
      for (let b = a + 1; b < spots.length; b++) {
        const dx = spots[b].x - spots[a].x
        const dy = spots[b].y - spots[a].y
        const distance = Math.hypot(dx, dy) || 0.01
        const wanted = (spots[a].size + spots[b].size) / 2 + 3
        if (distance < wanted) {
          const push = (wanted - distance) / 2
          spots[a].x -= (dx / distance) * push; spots[a].y -= (dy / distance) * push
          spots[b].x += (dx / distance) * push; spots[b].y += (dy / distance) * push
        }
      }
    }
  }
  const minX = Math.min(...spots.map((s) => s.x - s.size / 2), 0)
  const maxX = Math.max(...spots.map((s) => s.x + s.size / 2), 0)
  const minY = Math.min(...spots.map((s) => s.y - s.size / 2), 0)
  const maxY = Math.max(...spots.map((s) => s.y + s.size / 2), 0)
  return {
    width: Math.ceil(maxX - minX),
    height: Math.ceil(maxY - minY),
    spots: spots.map((s) => ({ ...s, x: s.x - minX, y: s.y - minY }))
  }
}

/// PastEventsArchiveView: every finished exercise, newest first, grouped by
/// month into a two-column grid of compact posters.
function PastArchive({ past, artOf, onRetry, onOpen }) {
  if (!past || past.events === null) {
    return html`
      <div class="archive-state">
        <div class="spinner"></div>
        <span>نحمّل تمارينك الماضية…</span>
      </div>
    `
  }
  if (!past.events.length && past.error) {
    return html`
      <div class="archive-state">
        <span class="archive-glyph"><${Icon.retry} /></span>
        <span class="archive-message">${past.error}</span>
        <button class="action action-blue archive-retry" onClick=${onRetry}>إعادة المحاولة</button>
      </div>
    `
  }
  if (!past.events.length) {
    return html`
      <div class="archive-state">
        <span class="archive-glyph"><${Icon.history} /></span>
        <strong>ما فيه تمارين ماضية</strong>
        <span class="archive-sub">بعد أول تمرين، بتلقى سجلك هنا</span>
      </div>
    `
  }

  const months = []
  for (const event of past.events) {
    const date = parseDate(event.start_date)
    const key = date ? `${date.getFullYear()}-${date.getMonth()}` : 'unknown'
    let bucket = months[months.length - 1]
    if (!bucket || bucket.key !== key) months.push((bucket = { key, date, events: [] }))
    bucket.events.push(event)
  }

  return html`
    <div class="archive">
      ${past.error && html`<div class="notice notice-error">${past.error}</div>`}
      ${months.map(
        (month) => html`
          <section class="archive-month" key=${month.key}>
            <h2>${month.date ? monthHeading(month.date) : ''}</h2>
            <div class="archive-count">${countedWorkouts(month.events.length)}</div>
            <div class="archive-grid">
              ${month.events.map((event, i) => html`
                <${ArchiveCard} key=${event.id} event=${event} art=${artOf(event)} index=${i}
                                onOpen=${(clickEvent) => onOpen(clickEvent, event)} />
              `)}
            </div>
          </section>
        `
      )}
    </div>
  `
}

function ArchiveCard({ event, art, index, onOpen }) {
  const startAt = parseDate(event.start_date)
  const tint = useArtTint(art)
  return html`
    <button class="archive-card enter" style=${`--i:${index};--tint:${tint}`} onClick=${onOpen}
            aria-label=${event.name} title="يفتح تفاصيل التمرين">
      <img class="fade-img" ref=${fadeInImage} src=${art} alt="" loading="lazy"
           style=${isZoomed(event.id) ? 'view-transition-name:event-art' : ''} />
      <span class="poster-tint"></span>
      <span class="archive-foot">
        ${event.cancelled_at && html`<span class="archive-skipped">متخطّى</span>`}
        <span class="archive-title">${event.name}</span>
        <span class="archive-when">${archiveWhen(startAt)}</span>
        ${event.location?.trim() && html`<span class="archive-location truncate">${event.location}</span>`}
      </span>
    </button>
  `
}

/// EmptyScheduleCard: the gradient poster that stands in when nothing is coming.
function EmptySchedule({ profile }) {
  return html`
    <div class="empty-poster enter">
      <${MemberAvatar} name=${profile?.name} url=${profile?.avatar_url} size=${42} />
      <h2>لا توجد مواعيد قادمة</h2>
      <p>أضف موعدًا جديدًا من زر +</p>
    </div>
  `
}

/// WelcomeView — the first screen of someone in no group yet.
function Welcome({ profile, onJoin }) {
  const name = (profile?.name ?? '').trim().split(/\s+/)[0]
  return html`
    <div class="welcome enter-fade">
      <h1>حيّاك${name ? ` ${name}` : ''}</h1>
      <p class="welcome-sub">اختر كيف تبدأ، والباقي علينا.</p>
      <div class="welcome-card is-disabled" aria-disabled="true">
        <span class="welcome-icon">✨</span>
        <span class="grow">
          <strong>أنشئ تمرينك</strong>
          <span>رتّب روتين اللعب وادعُ الربع</span>
          <span class="welcome-note">متاح في تطبيق تمرين على الآيفون فقط</span>
        </span>
        <a class="app-pill" href=${APP_STORE_URL} target="_blank" rel="noopener">حمّل التطبيق</a>
      </div>
      <button class="welcome-card" onClick=${onJoin}>
        <span class="welcome-icon"><${Icon.link} /></span>
        <span class="grow">
          <strong>انضم لتمرين</strong>
          <span>ادخل برمز الدعوة ووفر مكانك</span>
        </span>
      </button>
      <p class="welcome-foot">تمارينك خاصة، ما يدخلها إلا بدعوة</p>
    </div>
  `
}

/// HomeQuickAddSheet — the header's +. Joining works here; creating a group
/// is the organizer's half of the product and lives in the iOS app.
function QuickAddSheet({ onClose, onJoin }) {
  return html`
    <${Sheet} title="إضافة" onClose=${onClose}
              leading=${html`<button onClick=${onClose}>إلغاء</button>`}
              trailing=${html`<span style="min-width:44px"></span>`}>
      <div class="vstack" style="gap:10px">
        <button class="quick-row" onClick=${onJoin}>
          <span class="quick-tile quick-tile-solid"><${Icon.link} /></span>
          <span class="grow">
            <strong>انضم إلى تمرين</strong>
            <span>أدخل رمز الدعوة الذي وصلك من المشرف</span>
          </span>
        </button>
        <div class="quick-row is-disabled" aria-disabled="true">
          <span class="quick-tile"><${Icon.people} /></span>
          <span class="grow">
            <strong>تمرين جديد</strong>
            <span>ابدأ تمرينًا مستقلًا وادعُ أعضاءه</span>
            <span class="quick-note">متاح في تطبيق تمرين على الآيفون فقط</span>
          </span>
          <a class="app-pill" href=${APP_STORE_URL} target="_blank" rel="noopener">حمّل التطبيق</a>
        </div>
      </div>
    <//>
  `
}

export function JoinByCodeSheet({ onClose, onJoined }) {
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const { closing, dismiss } = useDismissible(null)

  async function submit(event) {
    event.preventDefault()
    const code = value.trim().replace(/\/+$/, '').split('/').pop()
    if (!code) { setError('الصق رابط الدعوة أو رمزها.'); return }
    setBusy(true)
    setError(null)
    try {
      const result = await joinWorkspace(code)
      dismiss(() => onJoined(result.workspace_id))
    } catch (failure) {
      setError(failure.message)
      setBusy(false)
    }
  }

  return html`
    <${Sheet} title="انضم إلى تمرين" subtitle="أدخل رمز الدعوة الذي وصلك من المشرف"
              onClose=${onClose} closing=${closing}>
      <form class="vstack" onSubmit=${submit}>
        <input class="guest-field" dir="ltr" placeholder="https://tamrien.app/join/ABC123"
               value=${value} onInput=${(e) => setValue(e.target.value)} />
        ${error && html`<div class="notice notice-error">${error}</div>`}
        <button class="action action-blue" type="submit" disabled=${busy}>
          ${busy ? 'جارٍ الانضمام…' : 'انضم'}
        </button>
      </form>
    <//>
  `
}
