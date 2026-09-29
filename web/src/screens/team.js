import { html, useState, useEffect, useCallback } from '../../vendor/preact.js'
import { getWorkspace, getWorkspaceEvents, getEventById } from '../api.js'
import { goBack } from '../router.js'
import { Spinner, Icon, MemberAvatar, sportOf, usesFootballFeatures } from '../ui.js'
import { parseDate, arabicDay, arabicTime, cleanAmount, counted, NOUNS } from '../format.js'
import { directionsUrl } from './event.js'
import { PlayerSheet } from './rating.js'

/// ExerciseDetailsOverlayPage — «تفاصيل التمرين», opened from the exercise
/// page. Three questions in this order: the standing plan, who is in the
/// group, and how paying works. The organizer's menu (edit, skip, delete)
/// is the app's; a member has no menu there either.
///
/// There is no template to read, so the plan is synthesized from the
/// exercise the page was opened from, exactly as HomeStore.synthesizePlan
/// does on the phone.
export function TeamScreen({ workspaceId, eventId, session }) {
  const userId = session.user.id
  const [detail, setDetail] = useState(null)
  const [plan, setPlan] = useState(undefined)
  const [error, setError] = useState(null)
  const [player, setPlayer] = useState(null)

  const load = useCallback(async () => {
    const [workspaceDetail, record] = await Promise.all([
      getWorkspace(workspaceId),
      eventId
        ? getEventById(eventId).catch(() => null)
        : getWorkspaceEvents(workspaceId).then((list) => list.find((e) => !e.cancelled_at) ?? list[0] ?? null).catch(() => null)
    ])
    setDetail(workspaceDetail)
    setPlan(record)
  }, [workspaceId, eventId])

  useEffect(() => {
    load().catch((failure) => setError(failure.message))
  }, [load])

  const bar = html`
    <div class="team-bar">
      <button class="glass-circle" onClick=${goBack} aria-label="إغلاق تفاصيل التمرين"><${Icon.close} /></button>
      <h2 class="truncate">تفاصيل التمرين</h2>
      <span style="width:44px"></span>
    </div>
  `

  if (error) {
    return html`
      <div class="app"><div class="team">
        ${bar}
        <div class="team-body"><div class="notice notice-error">${error}</div></div>
      </div></div>
    `
  }
  if (!detail) return html`<div class="app"><div class="team">${bar}<${Spinner} /></div></div>`

  const workspace = detail.workspace
  const football = usesFootballFeatures(sportOf(workspace))
  const members = [...(detail.members ?? [])].sort((a, b) => {
    if (a.is_owner !== b.is_owner) return a.is_owner ? -1 : 1
    return nameKey(a.display_name).localeCompare(nameKey(b.display_name), 'ar')
  })
  const memberCount = members.length || workspace.member_count || 0

  const startAt = plan ? parseDate(plan.start_date) : null
  const endAt = plan
    ? parseDate(plan.end_date) ?? new Date((startAt?.getTime() ?? 0) + 2 * 3_600_000)
    : null
  const share = Number(plan?.price_per_person ?? plan?.total_price ?? 0)
  const venue = plan?.location?.trim() ?? ''
  const hasDirections = Boolean(venue) || plan?.latitude != null

  return html`
    <div class="app">
      <div class="team">
        ${bar}

        <div class="team-body">
          ${plan && html`
            <section class="team-section enter" style="--i:0">
              <div class="team-section-head"><h2>قالب التمرين</h2></div>
              <div class="stat-grid">
                <${Stat} icon=${html`<${Icon.calendar} />`} value=${arabicDay(startAt)} title="يوم التمرين" />
                <${Stat} icon=${html`<${Icon.clock} />`}
                         value=${`${arabicTime(startAt)} – ${arabicTime(endAt)}`} title="وقت التمرين" />
                <${Stat} icon=${html`<${Icon.person} />`}
                         value=${share === 0 ? 'مجاني' : `${cleanAmount(share)} ر.س`} title="قطة كل لاعب" />
                <${Stat} icon=${html`<${Icon.people} />`}
                         value=${counted(plan.max_participants ?? 0, NOUNS.player)} title="سعة التمرين" />
              </div>
              ${hasDirections
                ? html`
                    <a class="info-row" href=${directionsUrl(plan)} target="_blank" rel="noopener"
                       aria-label=${venue ? `الاتجاهات إلى ${venue}` : 'الاتجاهات'}>
                      <span class="info-mark"><${Icon.court} /></span>
                      <span class="label">الملعب</span>
                      <span class="value truncate">${venue || 'غير محدد'}</span>
                      <span class="chev"><${Icon.chevronStart} /></span>
                    </a>
                  `
                : html`
                    <div class="info-row">
                      <span class="info-mark"><${Icon.court} /></span>
                      <span class="label">الملعب</span>
                      <span class="value">غير محدد</span>
                    </div>
                  `}
            </section>
          `}

          <section class="team-section enter" style="--i:1">
            <div class="team-section-head">
              <h2>الأعضاء</h2>
              ${members.length > 0 && html`<span class="caption">${counted(members.length, NOUNS.member)}</span>`}
            </div>

            ${members.length
              ? html`
                  <div class="row-stack">
                    ${members.map(
                      (member, position) => html`
                        <button class="row-card enter" key=${member.user_id} style=${`--i:${2 + position}`}
                                title="يفتح تفاصيل اللاعب وتقييمه"
                                onClick=${() => setPlayer({
                                  userId: member.user_id,
                                  name: member.display_name ?? 'عضو',
                                  avatarUrl: member.avatar_url,
                                  position: member.postion
                                })}>
                          <${MemberAvatar} name=${member.display_name} url=${member.avatar_url} />
                          <span class="grow">
                            <span class="title truncate" style="display:block">${member.display_name ?? 'عضو'}</span>
                            <span class="sub">${member.is_owner ? 'مشرف التمرين' : 'عضو'}</span>
                          </span>
                          ${member.is_owner ? html`<span class="crown"><${Icon.crown} /></span>` : null}
                        </button>
                      `
                    )}
                  </div>
                `
              : html`<p class="team-empty">${memberCount > 0
                  ? 'تعذر تحميل قائمة الأعضاء الآن. حدّث الصفحة وحاول مرة أخرى.'
                  : 'ما انضم أحد إلى التمرين بعد.'}</p>`}
          </section>

          ${share > 0 && html`
            <section class="team-section enter" style="--i:2">
              <div class="team-section-head"><h2>الدفع</h2></div>
              <div class="hstack pay-note">
                <span class="pay-note-mark"><${Icon.card} /></span>
                <span>تظهر لك تفاصيل الدفع ضمن خطوات التسجيل في هذا الموعد.</span>
              </div>
            </section>
          `}
        </div>
      </div>

      ${player && html`<${PlayerSheet}
        player=${player}
        workspaceId=${workspaceId}
        football=${football}
        meId=${userId}
        onClose=${() => setPlayer(null)}
      />`}
    </div>
  `
}

/// Names sort the way the app sorts them: Arabic script first, then Latin,
/// with any leading emoji or digits ignored.
function nameKey(name) {
  const trimmed = String(name ?? '').replace(/^[^\p{L}]+/u, '')
  return (/^\p{Script=Arabic}/u.test(trimmed) ? '0' : '1') + trimmed
}

function Stat({ icon, value, title }) {
  return html`
    <div class="stat">
      <span class="stat-icon">${icon}</span>
      <span class="stat-title truncate">${title}</span>
      <span class="stat-value truncate">${value}</span>
    </div>
  `
}
