# Llamas Cookbook — Logo & App Icon Export

This folder contains everything you need to ship the Llamas Cookbook llama as a logo and app icon for iOS (and any incidental web favicons).

## What's in here

```
assets/
├── logo.svg                       Master vector — drop this in your codebase
├── png/
│   └── logo-{1024,512,256,…}.png  Llama-only PNG renders (transparent bg)
├── ios/
│   ├── AppStore-1024.png          App Store listing artwork (required)
│   ├── iPhone-{120,180}-{2,3}x.png
│   ├── iPad-{152,167}-{2,3}x.png
│   ├── Spotlight-…  Settings-…  Notification-…
│   └── Contents.json              Drop this whole folder into Assets.xcassets/AppIcon.appiconset
└── favicon/
    └── favicon-{16,32,48,64,192,512}.png
```

> Android exports were dropped — the app is iOS-only. If we ever
> add an Android target, re-export from `logo.svg` with the same
> tooling that generated this set.

## Drop shadow — wiring the color picker

The drop shadow is **driven by a CSS custom property** so your color picker can swap it live without re-rendering the SVG.

The SVG declares:

```css
--llama-shadow: rgba(180, 90, 53, 0.45);   /* default */
filter: drop-shadow(0 14px 18px var(--llama-shadow));
```

### From your app code

```js
// Whenever the user picks a new color from the picker:
document.documentElement.style.setProperty('--llama-shadow', 'rgba(120, 50, 90, 0.55)');
// — or scoped to a specific element:
logoEl.style.setProperty('--llama-shadow', userPickedRgba);
```

Any SVG, image, or React component that references `var(--llama-shadow)` updates instantly.

### Inline-importing the SVG (recommended)

Inlining the SVG (instead of using `<img src>`) is what lets the CSS variable cascade into the shadow filter. Example:

**React + Vite/Webpack** with `?react` or `vite-plugin-svgr`:

```jsx
import LlamaLogo from './logo.svg?react';

function Header() {
  return <LlamaLogo style={{ width: 80, height: 'auto' }} />;
}
```

**Plain HTML** — just paste the contents of `logo.svg` inline, or fetch + inject:

```js
fetch('/logo.svg').then(r => r.text()).then(svg => {
  document.getElementById('logo-slot').innerHTML = svg;
});
```

> If you load the SVG via `<img src="logo.svg">` the CSS variable will not apply (separate document context). Inline it.

### iOS note

Native app icons are rasterized at build time, so the home-screen app icon's shadow does **not** dynamically change. The exported `ios/` set bakes in the default warm-terracotta shadow. The customizable shadow only applies inside the running app where the logo is rendered live (toolbars, watermark, accent-color picker preview, etc.) — see `Views/Components/LlamaLogo.swift` for the SwiftUI side.

If you want themed app-icon variants (plum, forest, charcoal) we can re-render the icon set with whatever shadow you pick.

## Installing the app icons

### iOS (Xcode) — already wired

The `ios/` PNGs and `Contents.json` are already copied into `ios-native/Resources/Assets.xcassets/AppIcon.appiconset/` and the CI workflow strips alpha at archive time. You only need to repeat this if the artwork is re-exported.

1. Replace every PNG under `Assets.xcassets/AppIcon.appiconset/` with the matching new file from `assets/ios/`.
2. Replace `Assets.xcassets/AppIcon.appiconset/Contents.json` with `assets/ios/Contents.json` if the slot mapping changed.
3. Push — CI's "Sanitize app icon PNGs" step strips alpha and re-encodes as opaque sRGB before archive.

### Web favicons

```html
<link rel="icon" type="image/png" sizes="32x32"  href="/favicon/favicon-32.png">
<link rel="icon" type="image/png" sizes="192x192" href="/favicon/favicon-192.png">
<link rel="apple-touch-icon" sizes="180x180" href="/ios/iPhone-180-3x.png">
```

## Re-generating

Source of truth is `logo.svg`. If the design changes, re-export from there and re-rasterize the iOS PNGs + favicons.
