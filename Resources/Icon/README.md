# Chirp brand artwork — icon, SVG mark, promo art

The pixel-art splendid fairy-wren, on a warm cream field. Same character
and palette as the desktop pet (`Sources/Chirp/Resources/Pet/`).

| File | Role |
|---|---|
| `Resources/ChirpMascot.png` | The 1024×1024 master. `scripts/make_icon.sh` reads this. |
| `Resources/Chirp.icns` | Generated from the master; copied into the `.app` by `scripts/make_app.sh` and named by `Info.plist`'s `CFBundleIconFile`. |
| `Resources/Chirp.svg` | The wren vector mark — no background, no wordmark. |
| `Resources/Icon/` (this folder) | Design sources: the master PNG and the full `.iconset`. |
| `Resources/Promo/` | Promo images — square, 16:9, 9:16. The 16:9 one is the README banner. |

## Regenerating the icon

```bash
./scripts/make_icon.sh     # ChirpMascot.png -> Chirp.icns
```

Checked at 16/32/64/128/256px: the silhouette reads as a blue bird even
at 16px, and the wordmark becomes legible from 64px up.

## The SVG mark

`Chirp.svg` is a real vector, not a raster embed — each pixel is an SVG
`<rect>`, run-length-encoded per row, with `shape-rendering: crispEdges`
so it stays crisp pixel art at any size. No font dependency, so it is the
most portable single asset (favicon, badge, anywhere a plain mark beats
the full lockup).
