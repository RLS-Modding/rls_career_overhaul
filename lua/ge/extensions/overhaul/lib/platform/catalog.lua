-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Read-only VFS discovery shared by platform registries. Nothing is cached here: every scan returns
-- fresh data, and extension owners keep whatever they derive in their own instances.
local M = {}

function M.string(value)
  return type(value) == "string" and value ~= ""
end

function M.id(value)
  return M.string(value) and value:match("^[%w][%w%._%-]*$") ~= nil
end

function M.number(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- A UI component lives under /ui/ui-vue/mods/<mod>/ and cannot climb out with ".." or use backslashes.
function M.component(value)
  return M.string(value) and value:match("^/ui/ui%-vue/mods/[^/]+/.+%.vue$") ~= nil
    and not value:find("..", 1, true) and not value:find("\\", 1, true)
end

-- A list is a table whose keys are exactly 1..#value.
function M.list(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return false end
    count = count + 1
  end
  return count == #value
end

-- Why a manifest is not a valid object for its file, or nil when it is.
function M.identity(data, file)
  if type(data) ~= "table" then return "not a JSON object" end
  if not M.id(data.id) then return "invalid id" end
  if data.id ~= file:match("([^/\\]+)%.json$") then return "id must match file name" end
  if data.order ~= nil and not M.number(data.order) then return "order must be finite" end
  if data.namespace ~= nil and (not M.id(data.namespace) or data.id:sub(1, #data.namespace + 1) ~= data.namespace .. "-") then
    return "id must start with namespace followed by '-'"
  end
end

function M.warn(tag, message)
  log("W", tag, message)
end

-- Why one manifest is unusable, or nil. Identity is checked first, then the caller's validator, then the id.
local function rejectionReason(data, file, validate, seen)
  local reason = M.identity(data, file)
  if reason then return reason end
  reason = validate(data, file)
  if reason then return reason end
  if seen[data.id] then return "duplicate id (first path wins)" end
  return nil
end

local function byOrderThenId(left, right)
  local leftOrder, rightOrder = left.order or 999, right.order or 999
  if leftOrder ~= rightOrder then return leftOrder < rightOrder end
  return left.id < right.id
end

-- Usable entries sorted by order then id, and {file, reason} for each rejected file.
function M.scan(dir, validate, tag)
  local files = FS:findFiles(dir, "*.json", 0, false, false) or {}
  table.sort(files)
  local entries, rejected, seen = {}, {}, {}
  for _, file in ipairs(files) do
    local data = jsonReadFile(file)
    local reason = rejectionReason(data, file, validate, seen)
    if reason then
      rejected[#rejected + 1] = {file = file, reason = reason}
      M.warn(tag, "Ignoring manifest " .. file .. ": " .. reason)
    else
      seen[data.id] = true
      entries[#entries + 1] = data
    end
  end
  table.sort(entries, byOrderThenId)
  return entries, rejected
end

-- The scan as a UI payload: a failing scan reports its error instead of throwing into the view.
function M.listForUi(scan)
  local ok, entries, rejected = pcall(scan)
  if not ok then return {entries = {}, rejected = {}, error = tostring(entries)} end
  return {entries = entries, rejected = rejected}
end

return M
