-- WhisperTabs
-- Auto-open incoming whispers as separate tabs in the default chat window,
-- one tab per conversation. TBC Classic 2.5.6.

local ADDON_NAME, ns = ...

WhisperTabsDB = WhisperTabsDB or {}
local defaults = {
  enabled            = true,
  persist            = true,    -- restore tabs across sessions
  maxTabs            = 20,      -- safety cap
  routeExisting      = true,    -- also route to a pre-existing tab named after the player
  autoSwitch         = false,   -- switch focus to the new tab when it opens (never in combat)
  duplicateInGeneral = true,    -- also keep whispers in the default (General) chat frame
}

-- Runtime state: playerName (normalized) -> ChatFrame table.
local openTabs = {}

-- Ring buffer of recent whisper events for /wtabs report (see issue #14).
-- Each entry: { t=GetTime, event=, author=, msgLen=, key=, tabId=, replayed=bool, note= }.
local REPORT_MAX = 40
local reportRing = {}
local function reportPush(entry)
  entry.t = GetTime and GetTime() or 0
  table.insert(reportRing, entry)
  while #reportRing > REPORT_MAX do table.remove(reportRing, 1) end
end

-- ---------- helpers ----------

local function initDB()
  for k, v in pairs(defaults) do
    if WhisperTabsDB[k] == nil then WhisperTabsDB[k] = v end
  end
  WhisperTabsDB.tabs = WhisperTabsDB.tabs or {} -- persisted list of player names
end

-- Normalize a whisper "sender" arg into a stable tab key.
-- Strips realm suffix ("Foo-Illidan" -> "Foo") for the tab title, keeps the full
-- name as the routing key so cross-realm doesn't collide.
local function tabTitleFor(playerName)
  if not playerName then return "?" end
  local base = playerName:match("^([^-]+)") or playerName
  return base
end

-- Keys uniquely identify a conversation for our runtime map.
-- Non-BN whispers key by the full (cross-realm-safe) player name, lowercased.
-- BN whispers key by the invisible bnetIDAccount so we do NOT collide with
-- pre-existing user tabs that happen to share a title with the BN presenceName
-- (issue #12: e.g. Nokkar's BN presenceName "Sarah Green" collided with an
-- unrelated IRL contact tab titled "Sarah Green").
local function keyFor(playerName)
  return playerName and playerName:lower() or nil
end

local function bnKeyFor(bnetIDAccount)
  if not bnetIDAccount then return nil end
  return "bn:" .. tostring(bnetIDAccount)
end

local function print_(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWhisperTabs|r: " .. tostring(msg))
end

-- Map bnetIDAccount -> presenceName last seen, so INFORM (which lacks author
-- string for BN in some paths) can still resolve back to a title.
local bnDisplayName = {}

-- Find an existing chat window by exact tab title (case-insensitive).
-- Prefers a currently-shown match; falls back to a hidden match so we can
-- ADOPT and RE-SHOW it instead of spawning yet another duplicate slot (#10).
local function findChatFrameByName(name)
  if not name then return nil, nil end
  local target = name:lower()
  local hiddenMatch, hiddenIdx
  for i = 1, NUM_CHAT_WINDOWS do
    local title, _, _, _, _, _, shown = GetChatWindowInfo(i)
    if title and title:lower() == target then
      local cf = _G["ChatFrame" .. i]
      if cf then
        if shown then return cf, i end
        if not hiddenMatch then hiddenMatch, hiddenIdx = cf, i end
      end
    end
  end
  return hiddenMatch, hiddenIdx
end

-- Ensure a frame + its tab button are actually visible. Deliberately does NOT
-- force-dock — that fights ElvUI's chat layout and causes visual shuffling when
-- switching tabs. If the frame was docked before being closed, it'll re-dock
-- naturally; if it was floating, we leave it floating.
local function forceShowFrame(frame)
  if not frame then return end
  local id = frame:GetID()
  frame:Show()
  local tabBtn = _G["ChatFrame" .. id .. "Tab"]
  if tabBtn then
    tabBtn:Show()
    if tabBtn.SetAlpha then tabBtn:SetAlpha(1) end
  end
end

-- Configure a chat frame to only display whispers to/from playerName.
local function configureWhisperFrame(frame, playerName)
  if not frame then return end
  -- Clear all existing message groups on this frame, then add whisper groups only.
  ChatFrame_RemoveAllMessageGroups(frame)
  ChatFrame_AddMessageGroup(frame, "WHISPER")
  ChatFrame_AddMessageGroup(frame, "BN_WHISPER")
  -- Track per-player channel filtering via a message filter (below).
  frame.whisperTabsPlayer = playerName
end

-- Is a chat window slot still a real, user-visible tab?
--
-- A closed tab in WoW keeps its slot name in the saved layout but is hidden.
-- So `name ~= ""` alone is NOT sufficient — we also need the frame to be shown.
-- Otherwise we'll adopt a ghost slot and route whispers into an invisible tab
-- (see issue #10 debug: slot 6 name="Deehorlok" shown=false).
local function isFrameAlive(frame)
  if not frame then return false end
  local id = frame.GetID and frame:GetID() or nil
  if not id then return false end
  local name, _, _, _, _, _, shown = GetChatWindowInfo(id)
  if not name or name == "" then return false end
  if not shown then return false end
  local tabBtn = _G["ChatFrame" .. id .. "Tab"]
  if not tabBtn then return false end
  if not tabBtn:IsShown() then return false end
  return true
end

-- Force a chat frame into the main chat dock. Prevents floating whisper tabs
-- from overlapping and un-glowing the unread highlight (#12). We only dock
-- when the frame is a real chat frame that Blizzard's dock manager accepts.
local function forceDockFrame(frame)
  if not frame or not FCF_DockFrame then return end
  -- Avoid touching in combat (docking manipulates protected UI in some clients).
  if InCombatLockdown and InCombatLockdown() then return end
  -- Already docked? Nothing to do.
  local id = frame.GetID and frame:GetID()
  if id then
    local _, _, _, _, _, _, _, _, docked = GetChatWindowInfo(id)
    if docked and docked ~= 0 and docked ~= false then return end
  end
  -- Dock to the default chat frame's dock.
  pcall(FCF_DockFrame, frame)
end

-- Create (or reuse) a tab for playerName. Returns the ChatFrame or nil.
-- `opts` (optional): { bnetIDAccount = <number>, isBN = <bool> }
--   - When isBN is true we key/track by bnetIDAccount to avoid title-collision
--     with pre-existing user tabs (#12).
local function ensureTab(playerName, opts)
  opts = opts or {}
  local isBN = opts.isBN and opts.bnetIDAccount
  local key = isBN and bnKeyFor(opts.bnetIDAccount) or keyFor(playerName)
  if not key then return nil end

  local existing = openTabs[key]
  if existing and isFrameAlive(existing) then
    return existing
  elseif existing then
    -- Cached frame is dead (user closed the tab). Evict and fall through.
    openTabs[key] = nil
  end

  local title = tabTitleFor(playerName)
  if isBN then
    -- Remember display name for later INFORM lookups.
    if playerName then bnDisplayName[opts.bnetIDAccount] = playerName end
  end

  -- Reuse a pre-existing tab if the user (or a prior session) already made one.
  -- This includes HIDDEN slots with the same name — we adopt and re-show them
  -- rather than piling up duplicates in the saved layout (#10).
  --
  -- BN whispers SKIP this adoption path: their titles are user-controlled
  -- presenceNames that frequently collide with unrelated user tabs (issue #12).
  -- Always spawn a fresh tab for BN convos and rely on the bnetIDAccount key.
  if WhisperTabsDB.routeExisting and not isBN then
    local frame = findChatFrameByName(title)
    if frame then
      forceShowFrame(frame)
      forceDockFrame(frame)
      configureWhisperFrame(frame, playerName)
      openTabs[key] = frame
      return frame
    end
  end

  -- Safety cap.
  local count = 0
  for _ in pairs(openTabs) do count = count + 1 end
  if count >= (WhisperTabsDB.maxTabs or defaults.maxTabs) then
    print_("max tabs reached (" .. count .. "); not opening a new one for " .. title)
    return nil
  end

  -- FCF_OpenNewWindow is protected in some contexts (combat). Guard it.
  if InCombatLockdown and InCombatLockdown() then
    -- Defer: stash the name; we'll retry on PLAYER_REGEN_ENABLED.
    ns.pendingTabs = ns.pendingTabs or {}
    ns.pendingTabs[key] = playerName
    return nil
  end

  -- Remember which tab had focus so we can restore it if autoSwitch is off.
  local prevSelected = SELECTED_CHAT_FRAME

  local frame = FCF_OpenNewWindow(title)
  if not frame then
    -- Some clients return nil and instead use the "next available" frame.
    -- Fall back to scanning for the one with our title.
    frame = findChatFrameByName(title)
  end
  if not frame then
    -- Second fallback: the previously-closed slot may not have been rebound to
    -- our title. Find any inactive slot, name it, and use that.
    for i = 1, NUM_CHAT_WINDOWS do
      local name = GetChatWindowInfo(i)
      if not name or name == "" then
        local cf = _G["ChatFrame" .. i]
        if cf and FCF_SetWindowName then
          FCF_SetWindowName(cf, title)
          frame = cf
          break
        end
      end
    end
  end
  if not frame then
    print_("failed to open tab for " .. title)
    return nil
  end

  -- Force-show the frame and its tab button. FCF_Close hides both without
  -- destroying them, and FCF_OpenNewWindow doesn't always re-show a recycled
  -- slot (esp. under ElvUI). See issue #10.
  forceShowFrame(frame)

  -- Dock the new frame so it doesn't float over the main chat and so the
  -- unread-message tab glow works (#12).
  forceDockFrame(frame)

  -- Re-assign name in case the recycled slot kept a stale/empty one.
  if FCF_SetWindowName then FCF_SetWindowName(frame, title) end

  configureWhisperFrame(frame, playerName)
  openTabs[key] = frame

  -- FCF_OpenNewWindow selects the new tab. Restore focus unless the user opted in,
  -- and NEVER auto-switch during combat lockdown regardless of setting.
  local inCombat = InCombatLockdown and InCombatLockdown()
  if (not WhisperTabsDB.autoSwitch) or inCombat then
    if prevSelected and FCF_SelectDockFrame then
      -- FCF_SelectDockFrame is the safe, non-protected switcher for docked frames.
      FCF_SelectDockFrame(prevSelected)
    elseif prevSelected and prevSelected.SetFocus then
      SELECTED_CHAT_FRAME = prevSelected
    end
  end

  if WhisperTabsDB.persist and not isBN then
    -- Store by normalized full name so cross-realm re-open works.
    -- BN tabs are session-only for now (persistence would require also saving
    -- bnetIDAccount and re-resolving presenceName on login, which is fragile).
    local list = WhisperTabsDB.tabs
    local seen = false
    for _, n in ipairs(list) do if n:lower() == key then seen = true break end end
    if not seen then table.insert(list, playerName) end
  end

  return frame
end

-- ---------- message routing ----------
--
-- Design (post issue #9):
--
--   We DO NOT call ChatFrame_MessageEventHandler ourselves. ElvUI and other
--   chat overhauls replace/shadow it, causing nil-call errors. WIM also warned
--   this pattern taints in combat.
--
--   Instead: when a tab is created/adopted, register it for the WHISPER /
--   BN_WHISPER message groups. Blizzard's own dispatcher will then deliver
--   subsequent whispers to it naturally, alongside any other whisper-capable
--   frames (like General).
--
--   Filter's ONLY job: decide whether to suppress duplicate delivery in
--   non-tab whisper-capable frames, honoring the duplicateInGeneral toggle.
--
--   Consequence: the very first whisper from a brand-new author may only
--   appear in General (because the tab didn't exist when the current dispatch
--   computed its target set). Every whisper after that lands in the tab.
--   Acceptable tradeoff for zero-taint + ElvUI compatibility.

local function isWhisperCapable(frame)
  local id = frame and frame:GetID()
  if not id then return false end
  local groups = { GetChatWindowMessages(id) }
  for _, g in ipairs(groups) do
    if g == "WHISPER" or g == "BN_WHISPER" then return true end
  end
  return false
end

-- Track which (event, author-key, msg) triples the tab has ALREADY seen this
-- session tick, so we don't double-print when Blizzard's dispatcher also lands
-- the message on the tab naturally (post-registration).
--
-- Keyed by tab frame identity so distinct convos don't clobber each other.
local replayedInTab = setmetatable({}, { __mode = "k" })
local function markReplayed(tab, event, author, msg)
  local t = replayedInTab[tab]
  if not t then t = {}; replayedInTab[tab] = t end
  t[tostring(event) .. "|" .. tostring(author) .. "|" .. tostring(msg)] = GetTime and GetTime() or 0
end
local function alreadyReplayed(tab, event, author, msg)
  local t = replayedInTab[tab]
  if not t then return false end
  return t[tostring(event) .. "|" .. tostring(author) .. "|" .. tostring(msg)] ~= nil
end

-- Render a whisper into the target tab using tab:AddMessage. Deliberately
-- does NOT call ChatFrame_MessageEventHandler — that's shadowed by ElvUI and
-- caused issue #9. We reproduce Blizzard's default whisper coloring here.
--
-- Color handling (#14): ChatTypeInfo can be stomped or partially populated by
-- other addons in some contexts. Always fall back to Blizzard's known whisper
-- RGB (1.0, 0.5, 1.0 — the classic pink) if the info table is missing OR any
-- component is nil.
--
-- BN links (#14): presenceNames contain spaces, which break |Hplayer:...|h and
-- swallow color codes downstream. Use a plain bracketed name for BN events.
local function whisperColor(event)
  local key = (event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM")
    and "BN_WHISPER" or "WHISPER"
  local info = ChatTypeInfo and ChatTypeInfo[key]
  local r = info and info.r or 1.0
  local g = info and info.g or 0.5
  local b = info and info.b or 1.0
  -- Guard against nil-per-component (rare but seen in the wild under heavy addons).
  if r == nil then r = 1.0 end
  if g == nil then g = 0.5 end
  if b == nil then b = 1.0 end
  return r, g, b
end

local function renderInTab(tab, event, msg, author)
  if not tab or not tab.AddMessage then return end
  msg = msg or ""
  author = author or "?"
  local r, g, b = whisperColor(event)

  local isBN = (event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM")
  local nameToken
  if isBN then
    -- Spaces in presenceName break the player-link hyperlink.
    nameToken = string.format("[%s]", author)
  else
    nameToken = string.format("|Hplayer:%s|h[%s]|h", author, author)
  end

  local line
  if event == "CHAT_MSG_WHISPER" then
    line = string.format("%s whispers: %s", nameToken, msg)
  elseif event == "CHAT_MSG_WHISPER_INFORM" then
    line = string.format("To %s: %s", nameToken, msg)
  elseif event == "CHAT_MSG_BN_WHISPER" then
    line = string.format("%s: %s", nameToken, msg)
  elseif event == "CHAT_MSG_BN_WHISPER_INFORM" then
    line = string.format("To %s: %s", nameToken, msg)
  else
    line = msg
  end
  tab:AddMessage(line, r, g, b)
end

-- Per-tick dedupe so we schedule the replay closure at most once per event,
-- regardless of which filter invocation (General, tab, other whisper-capable
-- frame) gets to it first. Keyed by event|author|msg with the current game
-- time truncated to millisecond precision. Cleared opportunistically.
local scheduledReplay = {}
local function scheduleKey(evt, author, msg)
  local now = GetTime and GetTime() or 0
  return string.format("%s|%s|%s|%.3f", tostring(evt), tostring(author), tostring(msg), now)
end

local function makeFilter(event)
  local isBNEvent = (event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM")
  return function(chatFrame, evt, msg, author, ...)
    if not WhisperTabsDB.enabled then return false end
    if not author or author == "" then return false end

    -- COMBAT LOCKDOWN SAFETY (issue #6): do nothing during combat.
    if InCombatLockdown and InCombatLockdown() then
      return false
    end

    -- BN whispers: extract bnetIDAccount so we can key the tab by an invisible
    -- ID (#12). Classic 2.5.6 CHAT_MSG_BN_WHISPER* signature after author:
    -- lang(5), chan(6), target(7), flags(8), zone(9), chanIdx(10), chanBase(11),
    -- unused(12), lineID(13), guid(14), bnetIDAccount(15).
    -- Inside this closure, ... starts at arg #5, so bnetIDAccount = select(11, ...).
    local bnetIDAccount = nil
    if isBNEvent then
      bnetIDAccount = select(11, ...)
    end

    -- Compute a stable tab key up-front so the deferred replay can re-resolve
    -- the *current* tab for this author (#14 anti cross-routing). Capturing
    -- the tab reference at filter time and using it inside the timer callback
    -- was fine in isolation, but if two whispers from different authors arrive
    -- in the same tick and the second call to ensureTab churns the map (e.g.
    -- adoption re-uses a slot), the first closure could render into the wrong
    -- frame. Re-resolving from openTabs by key at fire-time avoids that.
    local resolveKey
    if isBNEvent then
      resolveKey = bnKeyFor(bnetIDAccount)
    else
      resolveKey = keyFor(author)
    end

    -- Ensure a tab exists for this conversation.
    local tab
    if isBNEvent then
      tab = ensureTab(author, { isBN = true, bnetIDAccount = bnetIDAccount })
    else
      tab = ensureTab(author)
    end

    -- Log for /wtabs report regardless of what happens next.
    reportPush({
      event = evt, author = author, msgLen = #(msg or ""),
      key = resolveKey,
      tabId = (tab and tab.GetID and tab:GetID()) or nil,
      frame = chatFrame and chatFrame.GetID and chatFrame:GetID() or nil,
      isBN = isBNEvent,
    })

    -- If tab creation failed (cap, or deferred), fall back to default routing.
    if not tab then return false end

    -- If this filter invocation is for the tab itself: allow render and mark
    -- so a subsequent replay (see below) knows to skip.
    if chatFrame == tab then
      markReplayed(tab, evt, author, msg)
      return false
    end

    -- Decide suppression for other frames.
    local suppress
    if chatFrame == DEFAULT_CHAT_FRAME then
      suppress = (not WhisperTabsDB.duplicateInGeneral)
    elseif isWhisperCapable(chatFrame) then
      suppress = true
    else
      suppress = false
    end

    -- Ensure the tab actually SEES the message this tick, even if Blizzard's
    -- dispatcher didn't route to it yet. Previously we only scheduled from
    -- DEFAULT_CHAT_FRAME's invocation, which meant profiles where General
    -- doesn't receive the filter call (e.g. General not whisper-capable, or
    -- ElvUI reordering) would silently drop the replay and the tab would show
    -- nothing (#14). Now: any non-tab filter invocation may schedule, but we
    -- dedupe by (event, author, msg, ~tick) so only ONE closure ever fires.
    local skey = scheduleKey(evt, author, msg)
    if not scheduledReplay[skey] then
      scheduledReplay[skey] = true
      local capturedEvt, capturedMsg, capturedAuthor = evt, msg, author
      local capturedKey = resolveKey
      C_Timer.After(0, function()
        scheduledReplay[skey] = nil
        -- Re-resolve the tab *now* by key, so we always render into the
        -- current tab for this author (#14 anti cross-routing).
        local liveTab = capturedKey and openTabs[capturedKey] or nil
        if not liveTab or not isFrameAlive(liveTab) then return end
        if alreadyReplayed(liveTab, capturedEvt, capturedAuthor, capturedMsg) then
          return
        end
        renderInTab(liveTab, capturedEvt, capturedMsg, capturedAuthor)
        markReplayed(liveTab, capturedEvt, capturedAuthor, capturedMsg)
        -- Update the last report entry with the replay outcome (best-effort).
        local last = reportRing[#reportRing]
        if last and last.event == capturedEvt and last.author == capturedAuthor then
          last.replayed = true
          last.renderedTabId = liveTab.GetID and liveTab:GetID() or nil
        end
      end)
    end

    return suppress
  end
end

local function installFilters()
  ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER",         makeFilter("CHAT_MSG_WHISPER"))
  ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM",  makeFilter("CHAT_MSG_WHISPER_INFORM"))
  if ChatFrame_AddMessageEventFilter and CHAT_MSG_BN_WHISPER then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER",         makeFilter("CHAT_MSG_BN_WHISPER"))
    ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER_INFORM",  makeFilter("CHAT_MSG_BN_WHISPER_INFORM"))
  end
end

-- Restore persisted tabs on login.
local function restorePersistedTabs()
  if not WhisperTabsDB.persist then return end
  local kept = {}
  for _, playerName in ipairs(WhisperTabsDB.tabs or {}) do
    local title = tabTitleFor(playerName)
    local frame = findChatFrameByName(title)
    if frame and isFrameAlive(frame) then
      configureWhisperFrame(frame, playerName)
      forceDockFrame(frame) -- keep restored tabs docked (#12)
      openTabs[keyFor(playerName)] = frame
      table.insert(kept, playerName)
    end
    -- If not found or not alive: drop from persisted list. Next real whisper
    -- from this player will spawn a fresh tab cleanly.
  end
  WhisperTabsDB.tabs = kept
end

-- ---------- events ----------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    initDB()
  elseif event == "PLAYER_LOGIN" then
    restorePersistedTabs()
    installFilters()
    print_("loaded. /whispertabs for options.")
  elseif event == "PLAYER_REGEN_ENABLED" then
    if ns.pendingTabs then
      for key, name in pairs(ns.pendingTabs) do
        ensureTab(name)
        ns.pendingTabs[key] = nil
      end
    end
  end
end)

-- ---------- slash commands ----------

SLASH_WHISPERTABS1 = "/whispertabs"
SLASH_WHISPERTABS2 = "/wtabs"
SlashCmdList["WHISPERTABS"] = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "" or msg == "help" then
    print_("commands:")
    print_("  /wtabs on|off        - enable/disable auto-tabbing")
    print_("  /wtabs autoswitch on|off - switch focus to new tab (never in combat)")
    print_("  /wtabs general on|off - also show whispers in the default (General) chat")
    print_("  /wtabs persist on|off- restore tabs across sessions")
    print_("  /wtabs max <n>       - max concurrent tabs (default 20)")
    print_("  /wtabs clear         - forget persisted tab list")
    print_("  /wtabs options       - open Blizzard options panel")
    print_("  /wtabs cleanup       - close all hidden ghost tab slots (recovery)")
    print_("  /wtabs report        - dump last ~40 whisper events (raid diagnostics)")
    print_("  /wtabs debug         - dump chat window + tab tracking state")
    print_("  /wtabs reset         - clear all WhisperTabs tab tracking")
    print_("  /wtabs status        - show current settings")
  elseif msg == "on" then
    WhisperTabsDB.enabled = true;  print_("enabled")
  elseif msg == "off" then
    WhisperTabsDB.enabled = false; print_("disabled")
  elseif msg == "persist on" then
    WhisperTabsDB.persist = true;  print_("persist: on")
  elseif msg == "persist off" then
    WhisperTabsDB.persist = false; print_("persist: off")
  elseif msg == "autoswitch on" then
    WhisperTabsDB.autoSwitch = true;  print_("autoSwitch: on (never applies in combat)")
  elseif msg == "autoswitch off" then
    WhisperTabsDB.autoSwitch = false; print_("autoSwitch: off")
  elseif msg == "general on" then
    WhisperTabsDB.duplicateInGeneral = true;  print_("duplicateInGeneral: on (whispers also stay in General)")
  elseif msg == "general off" then
    WhisperTabsDB.duplicateInGeneral = false; print_("duplicateInGeneral: off (whispers only in tabs)")
  elseif msg == "options" or msg == "config" then
    if ns.OpenOptions then ns.OpenOptions() end
  elseif msg:match("^max%s+(%d+)$") then
    local n = tonumber(msg:match("^max%s+(%d+)$"))
    WhisperTabsDB.maxTabs = math.max(1, math.min(50, n))
    print_("maxTabs: " .. WhisperTabsDB.maxTabs)
  elseif msg == "clear" then
    WhisperTabsDB.tabs = {}
    print_("persisted tab list cleared (existing tabs remain until /reload)")
  elseif msg == "cleanup" then
    -- Find all hidden slots and Close them so Blizzard frees their names.
    -- This cleans up ghost duplicates left over from prior WhisperTabs bugs.
    local closed = 0
    for i = 3, NUM_CHAT_WINDOWS do -- skip General (1) and Log (2)
      local name, _, _, _, _, _, shown = GetChatWindowInfo(i)
      if name and name ~= "" and not shown then
        local cf = _G["ChatFrame" .. i]
        if cf then
          if FCF_Close then FCF_Close(cf) end
          -- FCF_Close hides but preserves the name in saved layout. Force-clear
          -- name and message groups so the slot becomes reusable / empty.
          if FCF_SetWindowName then FCF_SetWindowName(cf, " ") end -- Blizzard rejects ""
          if ChatFrame_RemoveAllMessageGroups then
            ChatFrame_RemoveAllMessageGroups(cf)
          end
          closed = closed + 1
        end
      end
    end
    for k in pairs(openTabs) do openTabs[k] = nil end
    WhisperTabsDB.tabs = {}
    print_(string.format("cleanup: closed %d hidden ghost slot(s). /reload REQUIRED to persist.", closed))
  elseif msg == "debug" then
    print_("--- debug dump ---")
    print_("NUM_CHAT_WINDOWS=" .. tostring(NUM_CHAT_WINDOWS))
    for i = 1, NUM_CHAT_WINDOWS do
      local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
      local cf = _G["ChatFrame" .. i]
      local visible = cf and cf:IsShown()
      print_(string.format("  slot %d: name=%q shown=%s visible=%s docked=%s",
        i, tostring(name or ""), tostring(shown), tostring(visible), tostring(docked)))
    end
    print_("openTabs runtime map:")
    for k, f in pairs(openTabs) do
      local fid = f and f.GetID and f:GetID() or "?"
      local alive = isFrameAlive(f)
      print_(string.format("  %s -> ChatFrame%s alive=%s", tostring(k), tostring(fid), tostring(alive)))
    end
    print_("persisted list (WhisperTabsDB.tabs):")
    for i, n in ipairs(WhisperTabsDB.tabs or {}) do
      print_(string.format("  [%d] %s", i, tostring(n)))
    end
    print_("--- end debug ---")
  elseif msg == "report" or msg == "report copy" then
    -- In-raid diagnostics (#14): show the recent whisper ring buffer. Also
    -- persist a snapshot to WhisperTabsDB.lastReport so deehoc can view it
    -- later with /dump WhisperTabsDB.lastReport, share via export, etc.
    print_("--- whisper report (last " .. tostring(#reportRing) .. " events) ---")
    local snapshot = {}
    for i, e in ipairs(reportRing) do
      local line = string.format(
        "%2d) t=%.1f evt=%s author=%q key=%s tab=%s frame=%s bn=%s replayed=%s%s",
        i, e.t or 0, tostring(e.event):gsub("CHAT_MSG_",""),
        tostring(e.author), tostring(e.key),
        tostring(e.tabId), tostring(e.frame),
        tostring(e.isBN), tostring(e.replayed and true or false),
        e.renderedTabId and (" rendered=" .. tostring(e.renderedTabId)) or ""
      )
      print_(line)
      snapshot[i] = line
    end
    WhisperTabsDB.lastReport = snapshot
    print_("--- end report (saved to WhisperTabsDB.lastReport) ---")
  elseif msg == "reset" then
    WhisperTabsDB.tabs = {}
    for k in pairs(openTabs) do openTabs[k] = nil end
    print_("reset runtime + persisted tab tracking. /reload for a clean slate.")
  elseif msg == "status" then
    print_(string.format("enabled=%s autoSwitch=%s duplicateInGeneral=%s persist=%s maxTabs=%d openTabs=%d",
      tostring(WhisperTabsDB.enabled), tostring(WhisperTabsDB.autoSwitch),
      tostring(WhisperTabsDB.duplicateInGeneral),
      tostring(WhisperTabsDB.persist),
      WhisperTabsDB.maxTabs or defaults.maxTabs, (function() local c=0; for _ in pairs(openTabs) do c=c+1 end; return c end)()))
  else
    print_("unknown command. try /wtabs help")
  end
end
