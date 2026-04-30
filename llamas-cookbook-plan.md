# Original Product Brief

Condensed from the first planning document. Vision remains useful; old React Native implementation details are historical.

## Vision

Llamas Cookbook is a personal cookbook for people whose recipes are scattered across tabs, screenshots, notes, and paper. Save recipes once, find them quickly, and cook from a calm screen that stays useful at the stove.

## Goals

- Fast recipe capture.
- Clean browsing/search/filtering.
- Full recipe edit control.
- Cook Mode with large readable steps, check-off, scaling, and timers.
- Local/offline-first library.
- Forgiving UX: confirmations, safe cancel paths, no accidental data loss.

## Non-Goals

- Public recipe discovery feed.
- Grocery/delivery integration.
- AI-generated recipes as a core product.
- Android or iPad-first work right now.

## UX Principles

1. One-thumb friendly.
2. Input friction is fatal.
3. Cook Mode is a distinct, calm state.
4. Gestures need visible fallbacks.
5. Recipes are dense; UI should not add clutter.
6. Save silently where safe, warn only before real loss.

## Current Reality

The live app is native SwiftUI, not the original Expo/RN plan. See `CLAUDE.md`.
