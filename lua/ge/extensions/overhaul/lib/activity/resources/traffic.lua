-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Activity resource: traffic amount. Forwards saveAndSetTrafficAmount and restoreTrafficAmount from the activityTraffic capability.
-- Not a counted lease: restoreTrafficAmount restores on every call today, so the adapter only records who cut and restored.
local capabilities = require('overhaul/lib/platform/capabilities')

local M = {}

local function trafficUtils()
  return capabilities.get("activityTraffic")
end

function M.create(owner)
  local adapter = {cuts = 0, restores = 0}

  function adapter.getOwner() return owner end

  function adapter.cut(amount)
    local utils = trafficUtils()
    if not utils or not utils.saveAndSetTrafficAmount then return nil end
    adapter.cuts = adapter.cuts + 1
    return utils.saveAndSetTrafficAmount(amount)
  end

  function adapter.restore()
    local utils = trafficUtils()
    if not utils or not utils.restoreTrafficAmount then return nil end
    adapter.restores = adapter.restores + 1
    return utils.restoreTrafficAmount()
  end

  return adapter
end

return M
