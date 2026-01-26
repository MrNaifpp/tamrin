# Refactor Event Hero Screen to Match Reference

- Unify background stack: softened image with gradient mask; add full-height frosted glass behind content only (no extra white wash).
- Rebuild header section: center title/date with tighter spacing; reposition top-right close/back control to match reference icon.
- Restyle primary CTA: blue pill with rounded corners, consistent vertical padding and shadow.
- Restyle action chips: 3 glass buttons with equal widths, light blur, subtle border/inner shadow to match reference.
- Rework progress card: glass background, rounded corners, left-aligned count, styled progress bar and label row spacing per reference.
- Rework participant rows: glass cards with avatar on left and status avatar on right, consistent padding, corner radius, and spacing.
- Normalize global paddings/spacing to align with reference layout proportions.

Todos:
- `bg-glass` — Normalize background/glass layering for the content region
- `header-cta` — Align header/title/date and primary blue CTA styling
- `chips-progress` — Restyle action chips and progress card to match glass look
- `participants` — Restyle participant list rows for glass look/spacing

