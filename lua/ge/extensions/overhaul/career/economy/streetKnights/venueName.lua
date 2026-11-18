local M={}
function M.resolve(v)
  if not v then return nil end
  local n=v.name and v.name:gsub('^No Prep Knights%s*%-%s*','') or ''
  if n~='' and n~='Street Knights' then return n end
  n=tostring(v.id or 'Street Knights'):gsub('_meet$',''):gsub('_',' ')
  return (n:gsub('(%a)(%w*)',function(a,b) return a:upper()..b end))
end
return M
