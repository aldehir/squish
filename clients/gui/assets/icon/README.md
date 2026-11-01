# Squish icon

| File | What it is |
|---|---|
| `squish.svg` | Full icon: squish on the cream-to-pink rounded-square background. Used above 48px. |
| `squish-small.svg` | Small-size cut: squish only, transparent background, tight crop, no shadow or sparkle dots, bolder smile. Used for 48px and below. |

The build renders both with `src/build/icon.zig` into `squish.ico`
(16-256px, linked into the exe through `src/squish.rc`). `zig build icons`
also writes `squish-16.png` through `squish-1024.png` to `zig-out/icons`.

## Editing

Edit both SVGs if you change the squish itself (body, eyes, shine, colors).
The small SVG is the full one with the background, ground shadow and
sparkle dots removed, the smile stroke raised from 15 to 20, and the viewBox
cropped to `108 158 808 808`. Keep the root `width`/`height` at 1024: the
renderer scales from that.
