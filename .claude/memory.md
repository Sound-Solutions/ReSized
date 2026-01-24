# Project Memory

## Last Updated
2026-01-22 12:30

## Current Focus
ReSized macOS window management app - just completed nested container feature and built installer

## Session Summary
- Implemented nested container support for split layouts (sub-columns within columns, sub-rows within rows)
- Fixed multiple SwiftUI change detection issues with Equatable implementations
- Added split button that appears on hover, resizable dividers within nested containers
- Built, signed, notarized, and created .pkg installer (v1.0)
- Committed and pushed to GitHub

## In Progress
- User asked about licensing: App has 7-day trial with Lemon Squeezy integration
- Awaiting decision: Keep trial, remove licensing, or modify

## Key Decisions
- Nested containers use horizontal splits for columns, vertical splits for rows
- Drop zone only shows when there's exactly 1 child (after initial split)
- Equatable compares first child's proportion to detect resize changes

## Established Patterns
- Full struct recreation needed for SwiftUI change detection (not just array modification)
- Store initial proportions at drag start for divider resizing
- Use `objectWillChange.send()` for explicit change notifications

## Blockers / Issues
None currently

## Next Steps
- [ ] Decide on licensing: keep 7-day trial or make free
- [ ] If removing licensing, delete LicenseManager.swift and related UI code

## Notes
- Installer at: `Installer/ReSized-Installer.pkg` (589 KB, signed & notarized)
- Test license keys: anything starting with "RESIZED-" works
- Store URL: https://resized.lemonsqueezy.com/buy/748344
