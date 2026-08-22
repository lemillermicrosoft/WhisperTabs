-- WhisperTabs
-- Auto-open incoming whispers as separate tabs in the default chat window.
-- Scaffold stub — full implementation to follow.

local ADDON_NAME, ns = ...
ns = ns or {}

WhisperTabsDB = WhisperTabsDB or {}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    -- init saved vars here
  elseif event == "PLAYER_LOGIN" then
    print("|cff66ccffWhisperTabs|r v0.1.0 loaded. Try /whispertabs")
  end
end)

SLASH_WHISPERTABS1 = "/whispertabs"
SLASH_WHISPERTABS2 = "/wtabs"
SlashCmdList["WHISPERTABS"] = function(msg)
  print("|cff66ccffWhisperTabs|r: hello from the scaffold. Tab-per-whisper logic coming soon.")
end
