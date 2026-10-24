-- Bus seat counts: capacity from body variants and the vehicle parts tree, and the seats shown during a stop countdown.
-- Read capacity overrides, generic seat recognition, recursive accumulation and the leaving and boarding projections.
return function()
  -- Known body variants keep their existing capacity before generic seat counting.
  local function specificCapacityCases(partName)
    if partName:find("capsule") and partName:find("seats") then
      if partName:find("sd12m") then
        return 25
      elseif partName:find("sd18m") then
        return 41
      elseif partName:find("sd105") then
        return 21
      elseif partName:find("sd_seats") then
        return 33
      elseif partName:find("dd105") then
        return 29
      elseif partName:find("sd195") then
        return 43
      elseif partName:find("lhd_artic_seats_upper") then
        return 77
      elseif partName:find("lhd_artic_seats") then
        return 30
      elseif partName:find("lh_seats_upper") then
        return 53
      elseif partName:find("lh_seats") then
        return 17
      elseif partName:find("lhd_seats_upper") then
        return 53
      elseif partName:find("lhd_seats") then
        return 17
      elseif partName:find("rhd_artic_seats_upper") then
        return 77
      elseif partName:find("rhd_artic_seats") then
        return 30
      end
    end

    if partName:find("schoolbus_seats_r_c") then
      return 10
    end
    if partName:find("schoolbus_seats_l_c") then
      return 10
    end
    if partName:find("limo_seat") then
      return 8
    end

    return nil
  end

  local function isCountableSeatPartName(partName)
    return partName:find("seat")
      and not partName:find("cargo")
      and not partName:find("captains")
      and not partName:find("seatbase")
      and not partName:find("skin")
  end

  -- Count a rear bench once even when its slot container and bench parts both match.
  local function hasCountableSeatChild(partData)
    for _, child in pairs(partData.children or {}) do
      local childName = string.lower(child.chosenPartName or "")
      if isCountableSeatPartName(childName) then return true end
    end
    return false
  end

  -- Special-case body capacities override seat counting at the same tree node.
  local function cyclePartsTree(partData, seatingCapacity)
    for _, part in pairs(partData) do
      local partName = part.chosenPartName or ""

      partName = string.lower(partName)
      local specialCapacity = specificCapacityCases(partName)
      if specialCapacity or (isCountableSeatPartName(partName) and not hasCountableSeatChild(part)) then
        local seatSize = 1
        if partName:find("seats") then
          seatSize = 3
        elseif partName:find("ext") then
          seatSize = 2
        end

        seatSize = specialCapacity or seatSize
        seatingCapacity = seatingCapacity + seatSize
      end

      if part.children then
        seatingCapacity = cyclePartsTree(part.children, seatingCapacity)
      end

      if partName == "pickup" then
        seatingCapacity = math.max(seatingCapacity, 7)
      end
    end

    return seatingCapacity
  end

  local function clamp(count, capacity)
    count = math.max(0, count)
    if capacity then count = math.min(count, capacity) end
    return count
  end

  -- Seats shown at the deboarding tick that reads `remaining` (leaving..1): that passenger has left.
  local function whileLeaving(onboard, leaving, remaining)
    return clamp(onboard - (leaving - remaining + 1))
  end

  -- Seats shown at the boarding tick that reads `boarded` (1..boarding): that passenger has sat down.
  local function whileBoarding(onboard, leaving, boarded, capacity)
    return clamp(onboard - leaving + boarded, capacity)
  end

  -- Seats shown once the stop completes; the same count the job keeps.
  local function afterStop(onboard, leaving, boarding, capacity)
    return clamp(onboard + boarding - leaving, capacity)
  end

  return {cyclePartsTree = cyclePartsTree, whileLeaving = whileLeaving, whileBoarding = whileBoarding,
    afterStop = afterStop}
end
