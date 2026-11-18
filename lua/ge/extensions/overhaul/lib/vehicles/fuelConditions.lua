local function preserveRlsFuelEngineStates(previous, incoming)
  if type(previous) ~= "table" or type(incoming) ~= "table" then
    return incoming
  end

  local function collectStates(node, trail, out)
    if type(node) ~= "table" then
      return
    end
    if type(node.rlsFuelEngineState) == "table" then
      out[#out + 1] = {trail = trail, state = node.rlsFuelEngineState}
    end
    if type(node.rlsFuelTank) == "table" then
      out[#out + 1] = {trail = trail, tank = node.rlsFuelTank}
    end
    for key, child in pairs(node) do
      if key ~= "rlsFuelEngineState" and key ~= "rlsFuelTank" and type(child) == "table" then
        local nextTrail = {}
        for i = 1, #trail do
          nextTrail[i] = trail[i]
        end
        nextTrail[#nextTrail + 1] = key
        collectStates(child, nextTrail, out)
      end
    end
  end

  local function ensureTrail(node, trail)
    local current = node
    for i = 1, #trail do
      local key = trail[i]
      if type(current[key]) ~= "table" then
        current[key] = {}
      end
      current = current[key]
    end
    return current
  end

  -- Live get after a fresh engine often publishes a full Original blob (tune with no
  -- decel key). That must not erase Custom Decel / presets still held on the part.
  -- Intentional Original writes include tune.decel.mode = "original", so they keep.
  local function enrichFuelState(trusted, incomingState)
    if type(trusted) ~= "table" or type(incomingState) ~= "table" then
      return
    end
    if type(trusted.tune) == "table" then
      if type(incomingState.tune) ~= "table" then
        incomingState.tune = deepcopy(trusted.tune)
      elseif type(trusted.tune.decel) == "table" and type(incomingState.tune.decel) ~= "table" then
        incomingState.tune.decel = deepcopy(trusted.tune.decel)
      end
    end
    if type(trusted.presets) == "table" and next(trusted.presets) then
      -- A newer confirmed revision may intentionally delete the last map.
      local confirmedEdit = (tonumber(incomingState.revision) or 0) > (tonumber(trusted.revision) or 0)
      if type(incomingState.presets) ~= "table" or (not next(incomingState.presets) and not confirmedEdit) then
        incomingState.presets = deepcopy(trusted.presets)
      end
    end
  end

  -- Live getPartConditions can run before Fuels hydrates a just-installed engine,
  -- and may omit integrityState entirely. Recreate the trail and keep the blob.
  for path, oldCondition in pairs(previous) do
    local newCondition = incoming[path]
    if type(oldCondition) == "table" and type(newCondition) == "table" then
      local found = {}
      collectStates(oldCondition, {}, found)
      for _, item in ipairs(found) do
        local target = ensureTrail(newCondition, item.trail)
        if item.tank then
          -- Tank composition has no other home; a get before Fuels binds the
          -- tank returns only native liters and must not reset it to regular.
          if type(target.rlsFuelTank) ~= "table" then target.rlsFuelTank = deepcopy(item.tank) end
        elseif type(target.rlsFuelEngineState) ~= "table" then
          target.rlsFuelEngineState = deepcopy(item.state)
        else
          enrichFuelState(item.state, target.rlsFuelEngineState)
        end
      end
    end
  end

  return incoming
end


return preserveRlsFuelEngineStates
