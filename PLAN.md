# WhisperTabs — Plan

## Vision

Whisper conversations should feel like tabs in a modern chat app, not a firehose. WhisperTabs auto-opens each incoming whisper as its own tab in the default WoW chat window — one tab per correspondent — so you can follow multiple conversations in parallel without them blurring together in General chat.

## Scope (MVP)

1. **Auto-tab on incoming whisper.** When `CHAT_MSG_WHISPER` fires from a new player this session, create a new chat tab named after that player.
2. **Auto-tab on outgoing whisper.** Same treatment for `CHAT_MSG_WHISPER_INFORM` — sending `/w Foo hi` opens a Foo tab if one doesn't exist.
3. **Route messages to the right tab.** Only the whisper thread with that player appears in their tab; other chat stays in the main window.
4. **Reuse existing tabs.** If a tab for that player already exists (this session or persisted), reuse it — don't spawn duplicates.
5. **Slash config.** `/wtabs` toggles: enable/disable, whether tabs persist across sessions, max concurrent tabs.

## Technical Tasks

- Hook `ChatFrame_MessageEventHandler` or use `ChatFrame_AddMessageEventFilter` to intercept whisper events before they render.
- Use `FCF_OpenNewWindow(name)` to spawn tabs; `FCF_SetWindowName` for renames.
- Register the new frame for `CHAT_MSG_WHISPER` / `CHAT_MSG_WHISPER_INFORM` filtered by `arg2 == playerName`.
- Track `openTabs[playerName] = chatFrameIndex` in `WhisperTabsDB` (or session-only, per config).
- Handle edge cases: BN whispers, cross-realm names, GM whispers, AFK auto-replies.

## QA

- 1v1 whisper opens a new tab; second message goes to same tab.
- Two simultaneous whisperers → two tabs, no cross-talk.
- Outgoing `/w Foo` with no prior message from Foo still opens Foo tab.
- `/reload` preserves tabs when persistence enabled; clears them when disabled.
- No taint on protected chat frame APIs in combat.

## Post-MVP

- Unread indicator (dot / count) on tabs with new messages while not focused.
- Configurable auto-close after N minutes of inactivity.
- Optional sound cue per new tab.
- BN whisper support with proper display name.
- LibSharedMedia sound/font hooks.

## Deliverables

- `WhisperTabs.toc`, `WhisperTabs.lua` (loads clean in TBC Classic 2.5.6).
- `Media\icon.png` (64×64).
- Slash: `/whispertabs`, `/wtabs`.
- SavedVariables: `WhisperTabsDB`.
- CurseForge release + GitHub release once shipped.
