-- Activity resource: tasklist rows. Forwards owners' payload tables unchanged to the UI events they use today.
-- clearOwn clears only the rows this activity showed; clearAll keeps the global ClearTasklist for owners that use it.
local M = {}

function M.create(owner)
  local tasklist = {}
  local shown, order = {}, {}

  function tasklist.getOwner() return owner end

  -- task: the owner's payload ({id, label, type, clear, ...}); sent as-is.
  function tasklist.set(task)
    guihooks.trigger('SetTasklistTask', task)
    local id = type(task) == 'table' and task.id or nil
    if id == nil then return end
    if task.clear then
      if shown[id] then
        shown[id] = nil
        for i = #order, 1, -1 do
          if order[i] == id then table.remove(order, i) end
        end
      end
    elseif not shown[id] then
      shown[id] = true
      order[#order + 1] = id
    end
  end

  function tasklist.header(payload)
    guihooks.trigger('SetTasklistHeader', payload)
  end

  -- Clears only the rows this activity shows, in the order they were last shown; each id once.
  function tasklist.clearOwn()
    local cleared = 0
    for _, id in ipairs(order) do
      if shown[id] then
        guihooks.trigger('SetTasklistTask', {id = id, clear = true})
        shown[id] = nil
        cleared = cleared + 1
      end
    end
    order = {}
    return cleared
  end

  -- Today's global clear (every row, any owner), for owners that call ClearTasklist now.
  function tasklist.clearAll()
    guihooks.trigger('ClearTasklist', nil)
    shown, order = {}, {}
  end

  function tasklist.ids()
    local out = {}
    for _, id in ipairs(order) do
      if shown[id] then out[#out + 1] = id end
    end
    return out
  end

  return tasklist
end

return M
