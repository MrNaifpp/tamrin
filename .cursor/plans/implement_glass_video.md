# Implement Glass Style from Video in EventHeroDetailView

- In `[Sirr/Components/EventHeroDetailView.swift](/Users/naifalialshahrani/Documents/tamrin/Sirr/Components/EventHeroDetailView.swift)`, build a layered ZStack: base image + gradient, then a full-height frosted backdrop (material blur, no whitening), then content.
- Wrap the ScrollView content in a rounded glass container (material fill, softened tint, blur, shadow) similar to the video’s glass card; ensure corners/padding mirror the reference.
- Convert action chips, progress card, and participant rows to glass cards with consistent corner radius, subtle border/inner shadow, and spacing; keep text/icons legible on blur.
- Style the primary CTA and top control as floating pill/circle with appropriate shadow and padding to match the video’s emphasis.
- Normalize vertical/horizontal spacing to match the reference proportions shown.

Todos:
- `glass-layering` — Create layered background + frosted backdrop + glass container
- `glass-controls` — Restyle CTA, top control, and chips to glass styling
- `glass-cards` — Restyle progress card and participant rows as glass cards with consistent spacing

