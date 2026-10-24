-- Owner-declared temporary vehicles released at Lua reload.
-- Release runs before VM serialization so a reload cannot retain vehicles owned by discarded instances.
local M = {}

local declarations = {}  -- owner -> {release = fn}

-- An old disposer cannot withdraw a replacement declaration from the same owner.
function M.declare(owner, release)
  assert(type(owner) == "string" and owner ~= "", "temporary vehicles need an owner name")
  assert(type(release) == "function", "temporary vehicles need a release function")
  local declaration = {release = release}
  declarations[owner] = declaration
  return function()
    if declarations[owner] ~= declaration then return false end
    declarations[owner] = nil
    return true
  end
end

-- Release temporary vehicles in owner order before the engine serializes the VM.
function M.releaseAll()
  local owners = {}
  for owner in pairs(declarations) do owners[#owners + 1] = owner end
  table.sort(owners)
  for _, owner in ipairs(owners) do
    local declaration = declarations[owner]
    local ok, err = pcall(declaration.release)
    if not ok then log("W", "temporaryVehicles", "Releasing " .. owner .. " vehicles failed: " .. tostring(err)) end
  end
end

return M
