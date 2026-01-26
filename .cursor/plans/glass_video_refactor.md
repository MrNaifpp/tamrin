# Apply Video Glass Idea to EventHeroDetailView

- Layer stack: keep image + gradient; add full-height frosted backdrop (material blur) behind content, avoid white wash.
- Content container: wrap ScrollView in a rounded glass card (material fill, blur, subtle tint/shadow) sized to content area.
- Controls: floating circular glass close/back; primary CTA as blue pill with shadow; action chips restyled as glass buttons with consistent radius/spacing.
- Cards: progress card and participant rows become glass cards with matching radius, light border/inner shadow, and balanced padding.
- Spacing: normalize vertical/horizontal padding to mirror the reference proportions.

Todos:
- `glass-backdrop-video` — Build layered background + frosted backdrop + glass content container
- `glass-controls-video` — Restyle header/CTA/chips to glass look from video
- `glass-cards-video` — Restyle progress + participant cards to glass style

