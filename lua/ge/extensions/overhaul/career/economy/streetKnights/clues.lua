local rules=require('overhaul/career/economy/streetKnights/pinkOffers')
local M={}
function M.validate(meta,entry,read)
  if not meta or meta.model~=entry.model or meta.configId~=entry.id or type(meta.clues)~='table' or #meta.clues<3 then return false end
  if type(meta.evidence)=='table' and meta.evidence.healthy==false then return false end
  local bytes=read(entry.config)
  if not bytes or rules.fingerprint(bytes)~=meta.configFingerprint then return false end
  for _,source in ipairs(meta.sources or {}) do
    local contents=read(source.path)
    if not contents or rules.fingerprint(contents)~=source.fingerprint then return false end
  end
  return true
end
return M
