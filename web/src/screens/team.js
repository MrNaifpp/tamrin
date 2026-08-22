import { html, useState, useEffect, useCallback } from '../../vendor/preact.js'
import { getWorkspace, getWorkspaceEvents, leaveWorkspace } from '../api.js'
import { goBack, href } from '../router.js'
import { Spinner, Icon, Sheet, symbolGlyph } from '../ui.js'
import { parseDate, arabicDay, arabicTime, cleanAmount, counted, NOUNS } from '../format.js'

/// TeamDetailView — where the group's name leads. The page answers three
/// questions in this order, with nothing between them: what the standing date
/// is, who is in the exercise, and how to leave it.
///
/// There is still no per-workspace template to read, so the «قالب التمرين»
/// card is synthesized from the earliest upcoming event, exactly as
/// HomeStore.synthesizePlan does on the phone.
export function TeamScreen({ workspaceId, session }) {
  const userId = session.user.id
  const [detail, setDetail] = useState(null)
  const [plan, setPlan] = useState(null)
  const [error, setError] = useState(null)
  const [leaving, setLeaving] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)

  const load = useCallback(async () => {
    const [workspaceDetail, events] = await Promise.all([
      getWorkspace(workspaceId),
      getWorkspaceEvents(workspaceId).catch(() => [])
    ])
    setDetail(workspaceDetail)
    setPlan(events.find((event) => !event.cancelled_at) ?? events[0] ?? null)
  }, [workspaceId])

  useEffect(() => {
    load().catch((failure) => setError(failure.message))
  }, [load])

  if (error) {
    return html`
      <div class="app"><div class="team">
        <${TeamBar} title="التمرين" />
        <div class="team-body"><div class="notice notice-error">${error}</div></div>
      </div></div>
    `
  }
  if (!detail) return html`<div class="app"><${Spinner} /></div>`

  const workspace = detail.workspace
  const members = [...(detail.members ?? [])].sort((a, b) => {
    if (a.is_owner !== b.is_owner) return a.is_owner ? -1 : 1
    return String(a.display_name ?? '').localeCompare(String(b.display_name ?? ''), 'ar')
  })
  const memberCount = members.length || workspace.member_count || 0
  const isOwner = workspace.owner_id === userId
  const tint = workspace.color || '#c2eb63'

  const startAt = plan ? parseDate(plan.start_date) : null
  const endAt = plan
    ? parseDate(plan.end_date) ?? new Date((startAt?.getTime() ?? 0) + 2 * 3_600_000)
    : null
  const venue = Number(plan?.total_price ?? 0)
  const share = Number(plan?.price_per_person ?? 0)

  return html`
    <div class="app">
      <div class="team">
        <div class="team-glow" style=${`background:${tint}`}></div>
        <${TeamBar} title=${workspace.name} onMenu=${() => setMenuOpen(true)} />

        <div class="team-body">
          <header class="team-hero enter" style="--i:0">
            <div class="team-badge" style=${`background:${tint};box-shadow:0 10px 24px ${tint}4d`}>
              ${symbolGlyph(workspace.symbol)}
            </div>
            <h1>${workspace.name}</h1>
            <div class="team-count">${counted(memberCount, NOUNS.member)}</div>
          </header>

          ${plan
            ? html`
                <section class="card team-section enter" style="--i:1">
                  <div class="team-section-head">
                    <h2>قالب التمرين</h2>
                    <span class="caption truncate">${plan.name}</span>
                  </div>

                  <div class="stat-grid">
                    <${Stat} icon=${html`<${Icon.calendar} />`} value=${arabicDay(startAt)} title="يوم التمرين" />
                    <${Stat} icon=${html`<${Icon.clock} />`}
                             value=${`${arabicTime(startAt)} – ${arabicTime(endAt)}`} title="وقت التمرين" />
                    <${Stat} icon=${html`<${Icon.banknote} />`}
                             value=${venue === 0 ? 'بدون تكلفة' : `${cleanAmount(venue)} ﷼`} title="قيمة الملعب" />
                    <${Stat} icon=${html`<${Icon.person} />`}
                             value=${share === 0 ? 'مجاني' : `${cleanAmount(share)} ﷼`}
                             title="قطة كل لاعب" emphasised=${true} />
                  </div>

                  <a class="tile"
                     href=${plan.latitude != null
                       ? `https://maps.google.com/?q=${plan.latitude},${plan.longitude}`
                       : `https://maps.google.com/?q=${encodeURIComponent(plan.location ?? '')}`}
                     target="_blank" rel="noopener">
                    <${Icon.directions} />
                    <span class="truncate">${plan.location || 'الاتجاهات'}</span>
                  </a>

                  <div class="info-row">
                    <span class="info-mark"><${Icon.people} /></span>
                    <span class="label">سعة الموعد</span>
                    <span class="value">
                      ${plan.max_participants ? counted(plan.max_participants, NOUNS.player) : 'بدون حد'}
                    </span>
                  </div>
                </section>
              `
            : html`
                <section class="card team-section enter" style="--i:1">
                  <div class="team-section-head"><h2>قالب التمرين</h2></div>
                  <p class="team-empty">ما فيه موعد قادم في هذا التمرين.</p>
                </section>
              `}

          <section class="card team-section enter" style="--i:2">
            <div class="team-section-head">
              <h2>الأعضاء</h2>
              ${memberCount > 0 && html`<span class="caption">${counted(memberCount, NOUNS.member)}</span>`}
            </div>

            ${members.length
              ? html`
                  <div class="row-stack">
                    ${members.map(
                      (member, position) => html`
                        <div class="row-card enter" key=${member.user_id}
                             style=${`--i:${3 + position}`}>
                          <div class="member-avatar"
                               style=${member.is_owner ? 'background:var(--lime);color:var(--ink)' : ''}>
                            ${member.avatar_url
                              ? html`<img src=${member.avatar_url} alt="" />`
                              : String(member.display_name ?? '؟').trim().slice(0, 1)}
                          </div>
                          <span class="grow">
                            <span class="title truncate" style="display:block">
                              ${member.display_name ?? 'عضو'}
                              ${member.user_id === userId ? html`<span class="sub"> · أنت</span>` : null}
                            </span>
                            <span class="sub">${member.is_owner ? 'مشرف التمرين' : 'عضو'}</span>
                          </span>
                          ${member.is_owner ? html`<span class="crown">♔</span>` : null}
                        </div>
                      `
                    )}
                  </div>
                `
              : html`<p class="team-empty">ما انضم أحد بعد.</p>`}
          </section>
        </div>
      </div>

      ${menuOpen &&
      html`
        <${Sheet} title="خيارات التمرين" onClose=${() => setMenuOpen(false)}>
          <div class="vstack">
            ${isOwner
              ? html`<div class="notice notice-info">
                  تعديل التمرين ومواعيده وحذفه — من التطبيق.
                </div>`
              : html`
                  <p style="margin:0 0 4px;font-size:14px;opacity:0.7">
                    بتغادر التمرين وتختفي مواعيده من عندك. تقدر ترجع أي وقت برمز الدعوة.
                  </p>
                  <button class="action" style="background:var(--danger);color:#fff" disabled=${leaving}
                          onClick=${async () => {
                            setLeaving(true)
                            try {
                              await leaveWorkspace(workspaceId)
                              localStorage.removeItem('tamrin.workspace')
                              location.href = href({ name: 'home' })
                            } catch (failure) {
                              setError(failure.message)
                              setLeaving(false)
                              setMenuOpen(false)
                            }
                          }}>
                    ${leaving ? '…' : 'مغادرة التمرين'}
                  </button>
                `}
          </div>
        <//>
      `}
    </div>
  `
}

function TeamBar({ title, onMenu }) {
  return html`
    <div class="team-bar">
      <button class="glass-circle" onClick=${goBack} aria-label="رجوع"><${Icon.back} /></button>
      <h2 class="truncate">${title}</h2>
      ${onMenu
        ? html`<button class="glass-circle" onClick=${onMenu} aria-label="خيارات التمرين">···</button>`
        : html`<span style="width:44px"></span>`}
    </div>
  `
}

/// The four facts the group actually asks about. The per-player share carries
/// a heavier surface and a larger figure — it is the number they ask about most.
function Stat({ icon, value, title, emphasised = false }) {
  return html`
    <div class="stat ${emphasised ? 'stat-emphasised' : ''}">
      <span class="stat-icon">${icon}</span>
      <span class="stat-value truncate">${value}</span>
      <span class="stat-title truncate">${title}</span>
    </div>
  `
}
