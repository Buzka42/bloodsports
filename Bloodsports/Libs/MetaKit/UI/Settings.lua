-- UI kit: Settings. Registers a native Settings (Options > AddOns) vertical category from a list of options,
-- bound to keys of a saved-variables table. Every API call is pcall'd; without a `Settings` global it is a no-op.
--   UI.Settings{ name, db, options = { {type="check", key, label, tooltip, default, onChange},
--                {type="slider", key, label, tooltip, min, max, step, default, onChange}, {type="header", label} } }
--   -> category (or nil); UI.OpenSettings(category)

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI

UI.SettingsCategories = {}

local function tryHeader(layout, text)
  if not layout or not CreateSettingsListSectionHeaderInitializer then return end
  local ok, init = pcall(CreateSettingsListSectionHeaderInitializer, text)
  if ok and init and layout.AddInitializer then pcall(layout.AddInitializer, layout, init) end
end

local function register(category, name, db, opt)
  local key = opt.key
  local isCheck = opt.type == "check"
  if db[key] == nil then
    local d = opt.default
    if d == nil then d = isCheck and false or (opt.min or 0) end
    db[key] = d
  end
  local default = opt.default
  if default == nil then default = db[key] end
  local vtype = Settings.VarType and (isCheck and Settings.VarType.Boolean or Settings.VarType.Number)
  local ok, setting = pcall(Settings.RegisterAddOnSetting, category, name .. "_" .. key, key, db, vtype, opt.label or key, default)
  if not ok or not setting then return end
  if opt.onChange and setting.SetValueChangedCallback then
    pcall(setting.SetValueChangedCallback, setting, function(_, value) opt.onChange(value) end)
  end
  if isCheck then
    pcall(Settings.CreateCheckbox, category, setting, opt.tooltip)
  else
    local ok2, sopts = pcall(Settings.CreateSliderOptions, opt.min or 0, opt.max or 1, opt.step or 1)
    if ok2 and sopts then
      local fmt = MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label and MinimalSliderWithSteppersMixin.Label.Right
      if fmt and sopts.SetLabelFormatter then pcall(sopts.SetLabelFormatter, sopts, fmt) end
      pcall(Settings.CreateSlider, category, setting, sopts, opt.tooltip)
    end
  end
end

function UI.Settings(o)
  o = o or {}
  if type(Settings) ~= "table" or not Settings.RegisterVerticalLayoutCategory then return nil end
  local name = o.name or "MetaKit"
  local db = o.db or {}
  local ok, category, layout = pcall(Settings.RegisterVerticalLayoutCategory, name)
  if not ok or not category then return nil end
  for _, opt in ipairs(o.options or {}) do
    if opt.type == "header" then
      tryHeader(layout, opt.label or "")
    elseif (opt.type == "check" or opt.type == "slider") and opt.key then
      register(category, name, db, opt)
    end
  end
  if Settings.RegisterAddOnCategory then pcall(Settings.RegisterAddOnCategory, category) end
  UI.SettingsCategories[name] = category
  return category
end

function UI.OpenSettings(category)
  if not category or type(Settings) ~= "table" or not Settings.OpenToCategory then return false end
  local id = category.GetID and category:GetID() or category.ID
  return (pcall(Settings.OpenToCategory, id))
end
