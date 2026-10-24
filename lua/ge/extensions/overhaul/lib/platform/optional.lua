-- Looks up an add-on or registry-named extension by global name, without loading it.
-- Read the single live lookup; callers decide whether an absent registry owner is allowed.

return function(name)
  return rawget(_G, name)
end
