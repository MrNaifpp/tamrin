import { html, useState, useEffect } from '../../vendor/preact.js'
import { Icon, RowCard } from '../ui.js'
import { useDismissible } from '../motion.js'
import { counted, NOUNS } from '../format.js'
import { POSITION_TINTS, PositionTag } from './rating.js'

// The published split, as a player sees it (Lineup.swift, LineupPitchView.swift,
// LineupTeamPage.swift). Read-only: building, trading and publishing are the
// organizer's, in the app.

export const SIDES = [
  { key: 'first', name: 'الفريق الأول', tint: 'rgb(232, 92, 61)' },
  { key: 'second', name: 'الفريق الثاني', tint: 'rgb(245, 199, 64)' }
]

/// The server stores positions in English; the profile stores them in Arabic.
const POSITION_KEYS = { goalkeeper: 'حارس', defender: 'دفاع', midfielder: 'وسط', forward: 'هجوم' }
const ARABIC_POSITIONS = ['حارس', 'دفاع', 'وسط', 'هجوم']

/// Bands top to bottom, as the pitch draws them.
const BANDS = ['هجوم', 'وسط', 'دفاع', 'حارس']
/// The list below the pitch reads from the goal out.
const LIST_ORDER = ['حارس', 'دفاع', 'وسط', 'هجوم']

/// LineupSportStyle: football gets the pitch and positions, volleyball its
/// court, and everything else a neutral pitch with no positions.
const styleOf = (sport) => (sport === 'soccer' ? 'football' : sport === 'volleyball' ? 'volleyball' : 'generic')

/// Resolve the record's participant ids against today's roster, so names and
/// avatars are fresh and anyone who has since left simply drops out.
export function resolveLineup(record, roster) {
  if (!record) return null
  const byId = Object.fromEntries((roster ?? []).filter((row) => !row.is_waitlisted).map((row) => [row.participant_id, row]))
  const person = (id) => {
    const row = byId[id]
    if (!row) return null
    const override = POSITION_KEYS[record.positions?.[id]] ?? (ARABIC_POSITIONS.includes(record.positions?.[id]) ? record.positions[id] : null)
    const profile = ARABIC_POSITIONS.includes(row.player_position) ? row.player_position : null
    return {
      id,
      userId: row.user_id,
      name: row.display_name ?? row.guest_name ?? 'لاعب',
      avatarUrl: row.avatar_url,
      position: override ?? profile ?? 'وسط'
    }
  }
  return {
    first: (record.first ?? []).map(person).filter(Boolean),
    second: (record.second ?? []).map(person).filter(Boolean)
  }
}

/// The section on the exercise page: two cards, the viewer's own side open.
export function LineupSection({ lineup, sport, meId, art }) {
  const mySide = lineup.second.some((p) => p.userId === meId) ? 'second' : 'first'
  const [open, setOpen] = useState(null)

  return html`
    <div class="section-label enter" style="--i:4">التشكيلة</div>
    <div class="vstack lineup-stack" style="gap:10px">
      ${SIDES.map((side) => html`
        <${TeamCard} key=${side.key} side=${side} players=${lineup[side.key]} sport=${sport}
                     expanded=${side.key === mySide} onOpen=${() => setOpen(side.key)} />
      `)}
    </div>
    ${open && html`<${LineupPage} lineup=${lineup} sport=${sport} art=${art} initial=${open} onClose=${() => setOpen(null)} />`}
  `
}

function TeamCard({ side, players, sport, expanded, onOpen, onSwitch, large }) {
  const Tag = onOpen ? 'button' : 'div'
  return html`
    <${Tag} class="team-card ${large ? 'is-large' : ''}" onClick=${onOpen} aria-label=${onOpen ? `${side.name}، يفتح التشكيلة` : undefined}>
      <span class="team-card-head" onClick=${onSwitch} role=${onSwitch ? 'button' : undefined}
            aria-label=${onSwitch ? `يبدّل إلى ${SIDES.find((s) => s.key !== side.key).name}` : undefined}>
        <span class="team-dot" style=${`background:${side.tint}`}></span>
        <span class="team-name">${side.name}</span>
        <span class="side-count">${counted(players.length, NOUNS.player)}</span>
        <span class="team-chev"><${Icon.chevronStart} /></span>
      </span>
      ${expanded && html`<${Pitch} players=${players} sport=${sport} tint=${side.tint} />`}
    <//>
  `
}

function Pitch({ players, sport, tint }) {
  const style = styleOf(sport)
  if (!players.length) return html`<div class="pitch-empty">لا أحد في هذا الفريق بعد.</div>`

  const rows = style === 'football'
    ? BANDS.map((band) => players.filter((p) => p.position === band)).filter((row) => row.length)
    : balancedRows(players)

  return html`
    <div class="pitch pitch-${style}">
      <span class="pitch-lines"></span>
      <div class="pitch-rows">
        ${rows.map((row, i) => html`
          <div class="pitch-row" key=${i}>
            ${row.map((player) => {
              const words = player.name.trim().split(/\s+/)
              const dot = style === 'football' ? POSITION_TINTS[player.position] : style === 'volleyball' ? tint : 'rgb(158, 158, 158)'
              return html`
                <span class="pitch-player" key=${player.id}>
                  <span class="pitch-dot" style=${`background:${dot}`}></span>
                  ${words.length > 1 && html`<span class="pitch-first">${words[0]}</span>`}
                  <span class="pitch-last">${words[words.length - 1]}</span>
                </span>
              `
            })}
          </div>
        `)}
      </div>
    </div>
  `
}

/// Rows of at most three, balanced: seven players read 3 + 2 + 2.
function balancedRows(players) {
  const rowCount = Math.ceil(players.length / 3)
  const rows = []
  let start = 0
  for (let i = 0; i < rowCount; i++) {
    const size = Math.ceil((players.length - start) / (rowCount - i))
    rows.push(players.slice(start, start + size))
    start += size
  }
  return rows
}

/// LineupTeamPage: the side, full screen, with the list of who is on it.
function LineupPage({ lineup, sport, art, initial, onClose }) {
  const [side, setSide] = useState(initial)
  const { closing, dismiss } = useDismissible(onClose)
  const current = SIDES.find((s) => s.key === side)
  const other = SIDES.find((s) => s.key !== side)
  const football = sport === 'soccer'
  const players = football
    ? [...lineup[side]].sort((a, b) => LIST_ORDER.indexOf(a.position) - LIST_ORDER.indexOf(b.position))
    : lineup[side]

  useEffect(() => {
    const onKey = (event) => { if (event.key === 'Escape') dismiss() }
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    window.addEventListener('keydown', onKey)
    return () => { document.body.style.overflow = previous; window.removeEventListener('keydown', onKey) }
  }, [dismiss])

  return html`
    <div class="lineup-page ${closing ? 'is-closing' : ''}" role="dialog" aria-modal="true" aria-label="التشكيلة">
      <img class="lineup-page-art" src=${art} alt="" aria-hidden="true" />
      <div class="lineup-page-bar">
        <span style="width:44px"></span>
        <h2>التشكيلة</h2>
        <button class="glass-circle" onClick=${() => dismiss()} aria-label="إغلاق"><${Icon.close} /></button>
      </div>
      <div class="lineup-page-body">
        <div class="change" key=${side}>
          <${TeamCard} side=${current} players=${lineup[side]} sport=${sport} expanded=${true} large=${true}
                       onSwitch=${() => setSide(other.key)} />
        </div>
        <div class="section-label">القائمة</div>
        <div class="row-stack change" key=${`list-${side}`}>
          ${players.map((player, i) => html`
            <${RowCard} key=${player.id} index=${i} name=${player.name} avatarUrl=${player.avatarUrl}
                        accessory=${football ? html`<${PositionTag} position=${player.position} />` : null} />
          `)}
        </div>
      </div>
    </div>
  `
}
