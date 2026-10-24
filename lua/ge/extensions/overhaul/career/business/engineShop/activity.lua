-- Engine shop activity definition: its save hook delegates to the owner's M, so it always uses the live load.
-- Called once per owner load with M, which is why the definition is built inside the factory.
return function(M)
  local function delegate(name) return function(...) return M[name](...) end end
  return {
    id = 'engineShop', label = 'Engine shop', role = 'business', modes = {'career'},
    extension = 'overhaul_career_business_engineShop', lifecycle = 'engineShop', actions = {},
    save = delegate('onOverhaulSaveCurrentProfile'),
    transitions = {save = delegate('onOverhaulSaveCurrentProfile')},
    resources = {'timer'}, settlement = 'owner', economyKeys = {},
  }
end
