# Original Brief

Vision, kept as historical context. Implementation details in code.

## Vision

A personal cookbook for recipes scattered across tabs, screenshots, notes, and paper. Save once, find quickly, cook from a calm screen.

## Goals

- Fast capture.
- Clean browsing/search/filter.
- Full edit control.
- Cook Mode with large steps, check-off, scaling, timers.
- Local/offline-first.
- No accidental data loss.

## Non-goals

- Public discovery feed.
- Grocery/delivery.
- AI-generated recipes as core product.
- Android. iPad-first work.

## UX principles

1. One-thumb friendly.
2. Input friction is fatal.
3. Cook Mode is distinct and calm.
4. Gestures need visible fallbacks.
5. UI must not add clutter to dense recipes.
6. Save silently where safe; warn only before real loss.

## Reality

Live app is native SwiftUI under `ios-native/`, not the original RN plan. See `CLAUDE.md`.
