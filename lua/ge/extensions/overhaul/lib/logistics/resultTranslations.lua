-- Resolve delivery text when the shipping locale cache has not loaded mod keys.
local M = {}
local english
local function fallback(key)
  if not key:match("^ui%.") then return key end
  if not english then
    english = type(jsonReadFile) == "function" and jsonReadFile("/locales/translations/en-US/rls_career_overhaul.delivery.translation.json") or {}
    if type(english) ~= "table" then english = {} end
  end
  return english[key] or key
end
local function resolved(value, key)
  return type(value) == "string" and value ~= "" and value ~= key
end
function M.text(key)
  if type(key) ~= "string" then return key end
  local value = type(_tr) == "function" and _tr(key) or nil
  return resolved(value, key) and value or fallback(key)
end
function M.context(key, params)
  local value = core_locales and type(core_locales.contextTranslate) == "function" and core_locales.contextTranslate(key, params) or nil
  if resolved(value, key) then return value end
  return (fallback(key):gsub("{{(%w+)}}", function(name)
    local param = params and params[name]
    return param ~= nil and tostring(param) or "{{" .. name .. "}}"
  end))
end
return M
