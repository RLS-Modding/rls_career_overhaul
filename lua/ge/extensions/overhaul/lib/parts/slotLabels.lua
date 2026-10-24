-- Slot descriptions belong to the selected parent part, not to a slot type.
local M = {}

function M.getSlotInfo(parent, slotName)
  if not parent then return end
  for _, section in ipairs({"slots2", "slots"}) do
    local slots = parent[section]
    if slots then
      local header = slots[1]
      local columns = {}
      if type(header) == "table" and type(header[1]) == "string" then
        for index, key in ipairs(header) do columns[key] = index end
      end
      for _, slot in ipairs(slots) do
        if slot.name or slot.type then
          if (slot.name or slot.type) == slotName then return slot end
        elseif next(columns) then
          local name = slot[columns.name or columns.type]
          if name == slotName then
            local info = {name = name}
            for key, index in pairs(columns) do info[key] = slot[index] end
            local options = slot[#header + 1]
            if type(options) == "table" then
              for key, value in pairs(options) do info[key] = value end
            end
            return info
          end
        end
      end
    end
  end
  return parent.slotInfoUi and parent.slotInfoUi[slotName]
end

function M.getLabel(slotName, slotInfo, translate)
  local description = slotInfo and slotInfo.description
  -- Some callers carry an already resolved description wrapper.
  if type(description) == "table" and description.description then description = description.description end
  if description == nil or description == "" then return slotName end
  return translate and translate(description, "ui.vehicleconfig.slot.description.") or description
end

return M
