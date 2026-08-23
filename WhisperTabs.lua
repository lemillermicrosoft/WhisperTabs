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

local function keyFor(playerName)
  return playerName and playerName:lower() or nil
end

local function print_(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWhisperTabs|r: " .. tostring(msg))
end

-- Find an existing chat window by exact tab title (case-insensitive).
local function findChatFrameByName(name)
  if not name then return nil end
  local target = name:lower()
  for i = 1, NUM_CHAT_WINDOWS do
    local title = GetChatWindowInfo(i)
    if title and title:lower() == target then
      return _G["ChatFrame" .. i], i
    end
  end
  return nil
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
-- After a user closes a tab via the UI, GetChatWindowInfo(id) returns nil or
-- empty for that slot. That's our liveness probe.
local function isFrameAlive(frame)
  if not frame then return false end
  local id = frame.GetID and frame:GetID() or nil
  if not id then return false end
  local name = GetChatWindowInfo(id)
  if not name or name == "" then return false end
  -- Also make sure the tab UI still exists.
  local tabBtn = _G["ChatFrame" .. id .. "Tab"]
  if not tabBtn then return false end
  return true
end

-- Create (or reuse) a tab for playerName. Returns the ChatFrame or nil.
local function ensureTab(playerName)
  local key = keyFor(playerName)
  if not key then return nil end

  local existing = openTabs[key]
  if existing and isFrameAlive(existing) then
    return existing
  elseif existing then
    -- Cached frame is dead (user closed the tab). Evict and fall through.
    openTabs[key] = nil
  end

  local title = tabTitleFor(playerName)

  -- Reuse a pre-existing tab if the user (or a prior session) already made one.
  if WhisperTabsDB.routeExisting then
    local frame = findChatFrameByName(title)
    if frame then
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
  local fid = frame:GetID()
  frame:Show()
  local tabBtn = _G["ChatFrame" .. fid .. "Tab"]
  if tabBtn then
    tabBtn:Show()
    if tabBtn.SetAlpha then tabBtn:SetAlpha(1) end
  end

  -- Re-assign name in case the recycled slot kept a stale/empty one.
  if FCF_SetWindowName then FCF_SetWindowName(frame, title) end

  -- Re-dock if we're recycling a previously-undocked-then-closed slot.
  if FCF_DockFrame and not frame.isDocked then
    FCF_DockFrame(frame)
  end

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

  if WhisperTabsDB.persist then
    -- Store by normalized full name so cross-realm re-open works.
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

local function makeFilter(event)
  return function(chatFrame, evt, msg, author, ...)
    if not WhisperTabsDB.enabled then return false end
    if not author or author == "" then return false end

    -- COMBAT LOCKDOWN SAFETY (issue #6): do nothing during combat.
    -- No tab creation, no suppression, no frame manipulation. Blizzard's
    -- untampered default dispatch handles it; whispers still show in General.
    if InCombatLockdown and InCombatLockdown() then
      return false
    end

    -- Ensure a tab exists for this author. This also registers it for the
    -- WHISPER message groups so future dispatches deliver here automatically.
    local tab = ensureTab(author)

    -- If tab creation failed (cap, or deferred), fall back to default routing.
    if not tab then return false end

    -- If this filter invocation is for the tab itself, allow render.
    if chatFrame == tab then return false end

    -- For OTHER frames: decide suppression.
    -- DEFAULT_CHAT_FRAME (General) respects duplicateInGeneral.
    if chatFrame == DEFAULT_CHAT_FRAME then
      if WhisperTabsDB.duplicateInGeneral then
        return false
      else
        return true
      end
    end

    -- Any other whisper-capable frame: suppress to avoid dupes.
    if isWhisperCapable(chatFrame) then
      return true
    end

    return false
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
    print_("v0.1.0 loaded. /whispertabs for options.")
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
