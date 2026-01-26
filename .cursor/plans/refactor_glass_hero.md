# Refactor Event Hero Detail to “Glass” Stack

- Layer structure: keep full-screen image + gradient, add a glassy full-height backdrop behind content using material blur (no whitening), then place content in a rounded container with shadow per reference.
- Restyle top/header: center title/date block with tighter spacing; position close/back control in a floating circular glass button.
- Primary CTA: bright blue pill with consistent height, horizontal padding, and soft shadow.
- Action chips: three equal-width glass buttons with subtle border/inner shadow, matching corner radius and spacing.
- Progress card: glass background with rounded corners, left-aligned count, styled progress bar, and label layout per reference.
- Participants: glass row cards with avatar left, status icon right, consistent padding and radius; adjust spacing/opacity to match reference.
- Normalize global padding/spacing to align proportions with the screenshot.

Todos:
- `glass-backdrop` — Implement layered glass backdrop behind content, avoid white wash
- `header-cta-glass` — Restyle header/title/date and CTA + top control to match reference
- `chips-progress-glass` — Restyle action chips and progress card with glass styling
- `participants-glass` — Restyle participant rows with glass cards and spacing

