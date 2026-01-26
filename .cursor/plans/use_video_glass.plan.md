# Apply Video Glass Effect to EventHeroDetailView

- Layering: keep full-screen image + gradient; add a full-height frosted material layer behind content (blur, slight tint, no white wash), then a rounded glass container for the ScrollView.
- Header/CTA: center title/date; floating circular glass close/back; blue pill CTA with shadow.
- Controls/Cards: restyle action chips, progress card, and participant rows as glass cards (matching radius, subtle border/inner shadow, balanced padding).
- Spacing: normalize horizontal/vertical padding to mirror the video/reference proportions.

Todos:
- `glass-layering` — Build layered background + frosted backdrop + glass content container
- `glass-header-cta` — Restyle header and CTA to glass style
- `glass-cards` — Restyle chips/progress/participant rows as glass cards

