-- Blizzard Interface Options panel for WhisperTabs (TBC Classic 2.5.6).
-- Uses the classic InterfaceOptions_AddCategory API (available in 2.5.6).

local ADDON_NAME, ns = ...

local function L(k) return k end -- localization stub

local panel = CreateFrame("Frame", "WhisperTabsOptionsPanel", UIParent)
panel.name = "WhisperTabs"

-- ---------- widget helpers ----------

local function makeCheckbox(parent, label, tooltip, getter, setter)
  local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  cb.Text:SetText(label)
  if tooltip then cb.tooltipText = tooltip end
  cb:SetScript("OnShow", function(self) self:SetChecked(getter() and true or false) end)
  cb:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
  return cb
end

local function makeSlider(parent, label, minV, maxV, step, getter, setter)
  local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
  s:SetWidth(200); s:SetHeight(16)
  s:SetMinMaxValues(minV, maxV); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
  _G[s:GetName() and (s:GetName().."Low")  or ""] = nil
  if s.Low  then s.Low:SetText(tostring(minV)) end
  if s.High then s.High:SetText(tostring(maxV)) end
  if s.Text then s.Text:SetText(label .. ": " .. tostring(getter())) end
  s:SetScript("OnShow",  function(self) self:SetValue(getter()) end)
  s:SetScript("OnValueChanged", function(self, v)
    v = math.floor(v + 0.5)
    setter(v)
    if self.Text then self.Text:SetText(label .. ": " .. tostring(v)) end
  end)
  return s
end

-- ---------- panel layout ----------

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("WhisperTabs")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetPoint("RIGHT", -16, 0)
subtitle:SetJustifyH("LEFT"); subtitle:SetJustifyV("TOP")
subtitle:SetText("Auto-open a chat tab per whisper correspondent. Focus never switches during combat.")

local function DB() return WhisperTabsDB or {} end

local cbEnabled = makeCheckbox(panel, "Enable WhisperTabs",
  "Auto-open a new chat tab per whisper correspondent.",
  function() return DB().enabled end,
  function(v) DB().enabled = v end)
cbEnabled:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -16)

local cbAutoSwitch = makeCheckbox(panel, "Switch focus to new whisper tab",
  "When a new whisper tab opens, jump to it. NEVER applies during combat lockdown. Default: off.",
  function() return DB().autoSwitch end,
  function(v) DB().autoSwitch = v end)
cbAutoSwitch:SetPoint("TOPLEFT", cbEnabled, "BOTTOMLEFT", 0, -4)

local cbPersist = makeCheckbox(panel, "Persist tabs across sessions",
  "Remember whisper tabs across /reload and re-login.",
  function() return DB().persist end,
  function(v) DB().persist = v end)
cbPersist:SetPoint("TOPLEFT", cbAutoSwitch, "BOTTOMLEFT", 0, -4)

local slMax = makeSlider(panel, "Max concurrent tabs", 1, 50, 1,
  function() return DB().maxTabs or 20 end,
  function(v) DB().maxTabs = v end)
slMax:SetPoint("TOPLEFT", cbPersist, "BOTTOMLEFT", 8, -24)

-- ---------- registration ----------

-- Classic 2.5.6 API. Fall back gracefully if names change.
if InterfaceOptions_AddCategory then
  InterfaceOptions_AddCategory(panel)
elseif Settings and Settings.RegisterCanvasLayoutCategory then
  local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
  ns.__settingsCategory = category
end

function ns.OpenOptions()
  if InterfaceOptionsFrame_OpenToCategory then
    -- Blizzard bug (classic): call twice to actually land on the right pane.
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
  elseif Settings and Settings.OpenToCategory and ns.__settingsCategory then
    Settings.OpenToCategory(ns.__settingsCategory:GetID())
  end
end
