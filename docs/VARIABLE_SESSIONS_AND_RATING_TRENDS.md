# Variable sessions and rating changes

Implementation scope agreed with the user, 2026-09-17.

- Home shows one poster per workspace. Dates live in a horizontal card browser inside that workspace; each date retains its own roster, payments and capacity. Workspace membership and invite URL stay shared.
- Every workspace without a current/upcoming event remains reachable through one unscheduled poster. It is a workspace presentation, never a fabricated database event. Historical payment actions remain separate.
- The unscheduled detail retains the existing art, title and group-details entry. It says «لا يوجد موعد» and offers a white «إنشاء موعد» button to the owner. Members see the empty state without an owner action.
- The workspace browser offers one fixed «＋ موعد جديد» action for its owner. Empty workspaces retain a prominent white «إنشاء موعد» action. Creation opens the newly created date in full screen; re-entering a workspace with several dates restores the card browser.
- Reuse the composer, with explicit workspace identity, saved payment methods, deliberate date/location/capacity/cost selection and «ثابت / متغير» labels. One-off sessions may start today; validate past times. Multiple concurrent sessions are allowed.
- Preserve completed rosters/history; no automatic enrollment of workspace members in new dates. Publication uses the existing invitation/notification backend.
- Football rating trend compares the anonymous rounded aggregate before/after the latest effective rating change. Do not identify a rater or mistake initial/unmodified ratings for improvement. Show direction, magnitude and an accessible explanation alongside the total.
- Verify database authorization, aggregate arithmetic and no-op behavior; compile and inspect the actual app. Provide Debug demo data with a 300-member padel community, simultaneous and full/open dates, an expired-only group, member access and football increase/decrease/unchanged examples. Demo writes must remain local.

## Verification log

Debug and Release simulator builds pass. Seventeen checks against the actual HomeStore pass: first group creation, shared membership, simultaneous dates, independent rosters, expiry, member permissions, saved payment methods, captured workspace identity, past-date validation and rating change/no-op behavior.

The isolated PostgreSQL runner applies all 79 canonical migrations and passes these six suites:

- `player_ratings_test.sql`
- `player_rating_changes_test.sql`
- `create_event_goes_live_test.sql`
- `get_my_feed_test.sql`
- `variable_sessions_test.sql`
- `recurring_events_test.sql`

The new session test uses 300 members, verifies 299 invitation outbox entries per publication, and checks owner authorization and independent event registration. The rating tests cover increase/decrease, rounding, unchanged saves, workspace isolation, privacy and position changes. The runner uses PGlite with adapters for Supabase auth/storage and cron registration; external push delivery and concurrent transactions are not exercised.

An additional existing `workspaces_test.sql` run fails because its fixture registers participants in an already-ended event, which the later lifecycle guard rejects. This suite is not included in the focused runner; it was not changed.

Simulator inspection verified the live-event creation button, the existing group-details sheet with 300 members, the creation composer with saved payment methods, the fixed/variable control, the empty owner page and the upward rating indicator/explanation. The Mac locked during the final member-screen inspection; member permissions and downward/no-change rating behavior are covered by the automated checks, but their final visual inspection remains outstanding.

## Try the local demo

Choose the **Community and Ratings Demo** Xcode scheme and run on an iOS 26 simulator. The launch argument is `-demoCommunitySchedules`.

- **مجتمع البادل:** 300 members, four upcoming dates including simultaneous dates, open/full rosters and one past event.
- **بادل بلا موعد:** owner access to a 60-member group whose last date ended. Create a date from the empty page.
- **بادل الأصدقاء:** member access to a 60-member group without a date; no owner creation action.
- **كورة وتقييمات:** 30 members and a full 16-player date. The first three rated players show an increase, a decrease and no change. Edit a rating to exercise the aggregate indicator.

Demo membership, creation and ratings are local, reset on relaunch, and are excluded from Release builds. The demo creates the nearest occurrence for the first selected weekday in fixed scheduling; full recurring-series generation is exercised by the database tests.

Optional launch arguments: `-demoCommunityEmpty`, `-demoCommunityMember`, `-demoCommunityFootball` focus the corresponding card. `-runCommunityChecks` writes the 17-check result to the app's Documents/community-checks.txt and then restores the fixture.

Run the database checks with a locally installed `@electric-sql/pglite`, or provide its module path:

```sh
PGLITE_MODULE=/path/to/pglite/dist/index.js node scripts/test-community-database.mjs
```

## Server rollout

Apply `supabase/migrations/20260917100000_player_rating_changes.sql` before expecting rating indicators with real accounts. The migration and RPC changes have been tested locally, but have **not** been applied to a remote Supabase project. Existing clients remain compatible and updated clients accept responses without a trend. Session publication reuses the existing workspace/event APIs and notification outbox.


## Workspace schedule browser — 2026-09-21

The current request supersedes the original one-poster-per-occurrence presentation. Home identities are workspace UUIDs, including the transition from an empty workspace to its first date. A scheduled poster shows the workspace name and the number of dates when there are several.

Entry selects the nearest current registration (including a held, unpaid seat), otherwise the nearest available published date with registration open, otherwise the nearest upcoming date. An overdue contribution remains reachable in the workspace. Explicit event links preserve their exact target; history keeps its existing detail presentation.

`ExerciseScheduleView` presents the existing `EventDetailView` content in horizontally snapping cards. Tapping the artwork/content or scrolling the detail expands the card. Back returns an expanded multi-date workspace to its cards; a second back closes the workspace. Each detail keeps separate registration, payment and roster state. Creating a date uses the captured workspace ID and selects the returned event after the composer dismisses.

The browser respects Reduce Motion and exposes an adjustable date selector to VoiceOver. Artwork is assigned from the sport's photos plus the three bundled backgrounds, using each before repeating. Assignments remain stable during the current store session when dates are added. A workspace with more simultaneous dates than bundled backgrounds eventually reuses images; the sport library can be extended without changing the browser.

Validation for this revision: Debug and Release iOS simulator builds pass, as does `git diff --check`. The real HomeStore demo runner passes 34 scenarios, including one Home representative per workspace, all dates retained, registered/unpaid/open/locked/full/declined/unavailable selection, cancellation, overdue access, photo stability, adding dates without duplicating Home, expiry and existing membership/rating checks.

Simulator inspection verified the four-date carousel, date-by-date changes in artwork/time/venue/roster, expansion and return through accessibility actions, the owner composer opening with the correct workspace, the prominent white empty-state button, and the member empty state without creation controls. The CUA pointer/drag interface returned `noWindowsAvailable`; native touch swipes and a complete composer submission were not visually exercised. Date creation and per-date roster preservation were verified by the store integration checks.

Three additional padel backgrounds are bundled under `SportArt/padel/`. Their generation prompts and exact file names are documented in [SCHEDULE_ARTWORK.md](SCHEDULE_ARTWORK.md). No remote database migration or deployment is required for this presentation change.

### Motion and page edges follow-up — 2026-09-21

The horizontal pager now keeps the same slot widths, gaps, margins and viewport during expansion. Only the selected page grows beyond its slot, preventing RTL scroll snapping from moving it sideways. Selection is held during the transition, which uses a 0.34-second smooth animation without bounce. Returning to the browser resets the detail's vertical scroll without a competing animation.

Browsing pages have rounded top corners and extend below the screen, including the bottom safe area. The owner action is aligned to the physical right, uses the app's 50-point action height with 16-point horizontal padding, and has a darker glass tint.

Both Debug and Release simulator builds pass. Simulator recordings verified expansion and return on the second date, and expansion on the last date. Frame sampling at 60 Hz measured the second page's horizontal center within half a pixel throughout expansion and collapse, while its width grew and shrank in place. The short review recording is `build/schedule-motion/schedule-expand-collapse.mp4`. These transitions were triggered through accessibility actions; native touch/drag inspection remains limited by the simulator automation issue noted above. No data or backend behavior changed in this follow-up.

### Vertical gestures and scrolling cost — 2026-09-21

The first native vertical scroll interaction expands a compact date, including short touches that move directly from idle into scrolling. A separate downward pull starting at the top of an expanded date folds it back into the same workspace browser. Scrolling from inside the roster, deceleration and bounce cannot trigger that fold; each finger gesture can change the presentation only once. The workspace blocks the Home zoom's interactive dismissal, and its horizontal scroll lock no longer disables the vertical detail scroll.

Horizontal browsing keeps neighboring cards touchable and at a stable stacking order throughout a drag. Detail artwork now uses an asynchronously prepared, bounded cache of the same aspect-fill crop and 26-point frost, instead of a live full-screen blur on every card. Offscreen roster and waitlist rows are lazy. Native paging speed and the previous expansion geometry remain intact.

The earlier pointer-tool limitation was worked around with a temporary XCTest UI runner using real coordinate press-and-drag events. Two scenarios passed on the iPhone 17 Pro / iOS 26 simulator: horizontal date selection followed by short-scroll expansion, top-pull collapse, compact downward-pull expansion and button return; and repeated bidirectional paging followed by deep roster scrolling, return to the top and a separate collapse gesture. Selection stayed on the same date and the workspace remained open. The scrolling signpost duration measured 1.072 seconds on average across three iterations (0.734% relative standard deviation); this simulator provided duration, not device frame-rate or hitch counts. Physical-device smoothness is not quantified by that measurement.

Final Debug and Release simulator builds and `git diff --check` pass. The touch recording is `build/schedule-motion/schedule-scroll-gestures.mp4`. The review artifacts in that directory include the UI-test source and logs. No backend or registration behavior changed.

### Compact scroll lock and native control appearance — 2026-09-21

The new recording exposed a case that the scroll-phase expansion observer did not cover. Compact dates now disable their vertical ScrollView entirely. A directional UIKit pan recognizer opens the touched date and rejects horizontal movement so the date pager keeps its native gesture. Content scrolling is enabled only after expansion settles. This also admits indirect scroll input without depending on a SwiftUI phase update. Expansion uses the touched date's identity even when horizontal snapping has not published its latest selection; interrupted transitions cannot unlock a newer transition.

Back, template details and New Date share one native, interactive Liquid Glass button style and a full-surface touch shape. The glass is untinted and uses the adaptive primary foreground, allowing each control to respond to the photograph beneath it. Explicitly resolved system background and label colors were removed because they made the controls look opaque and prevented this adaptation. The Home presentation, workspace browser and event detail no longer force dark appearance. The existing photographic backgrounds and explicit artwork text colors stay in place.

Native coordinate-drag tests passed across all four dates, covering slow and fast gestures in both vertical directions. Each first gesture opened the date with its title still at the unscrolled position; horizontal paging and the full-surface Back button continued to work. This check passed in light and dark appearance. The existing native tests for short gestures, deep roster scrolling, top-pull collapse and staying inside the workspace also passed. Final palette inspection switched the system appearance on the same open date and verified all three controls together; the simulator was restored to its original light appearance. Screenshots, test source and logs are in `build/schedule-motion/compact-scroll/`.

The scroll-lock implementation passed Debug and Release simulator builds. After removing the forced glass palette, the Debug build and the four-date native gesture check passed again (one test, zero failures). The corrected controls were visually inspected in both system appearances; `liquid-glass-light.png` and `liquid-glass-dark.png` in the same artifact directory supersede the earlier solid-palette screenshots. The simulator was restored to light appearance. `git diff --check` passes.

### Frost continuity during card expansion — 2026-09-21

The 20:25 recording shows sharp artwork briefly appearing behind the title at approximately 2.05 seconds as the compact date starts expanding. This also reproduced in the simulator. The frost mask previously subtracted two global geometry measurements while their containing card was animating; those measurements could represent different positions during the transition and temporarily move the mask away from the panel.

The mask now derives its panel edge from the vertical ScrollView's normalized content offset and the fixed artwork-window height. Expanding or collapsing the card cannot change this local position. Offset updates disable inherited animation so the frost follows actual content scrolling directly. The cached blurred image and the card's expansion animation remain intact.

Validation: the Debug simulator build passed; the existing four-date opening test and the paging/deep-roster/top-pull test passed (two tests, zero failures). Before/after recordings and consecutive transition frames are in `build/schedule-motion/frost-transition/`. Frame inspection confirms that the mask no longer uncovers sharp artwork during expansion. The short `fixed-transition.mp4` shows the corrected first-date expansion and return.
