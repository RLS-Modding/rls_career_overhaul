-- Parcel count is authoritative for the issued load, including short routes.
-- Read targetLoad, surgeLeaf in order.

local M = {}

function M.targetLoad(job)
  return job.cargoIds and #job.cargoIds or job.standardLoad
end
function M.surgeLeaf() return 'delivery_parcel' end
return M
