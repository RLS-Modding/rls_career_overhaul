-- Convert transient vehicle IDs into a durable graph of owned inventory/node names.
local M = {}
function M.capture(spawned)
  local owners,edges,seen={},{},{}
  for id,saved in pairs(spawned) do if saved.vehicleId then owners[saved.vehicleId]=tostring(id) end end
  for id,saved in pairs(spawned) do
    for _,edge in ipairs(saved.runtime and saved.runtime.couplings or {}) do
      local partnerId=owners[edge.otherVehicleId]
      local partner=partnerId and spawned[partnerId]
      if not partner then return nil,'Unhook vehicles connected to traffic, borrowed vehicles or other vehicles outside your saved garage before exporting.' end
      local reciprocal
      for _,other in ipairs(partner.runtime and partner.runtime.couplings or {}) do
        if other.node.cid==edge.otherNodeCid and other.otherVehicleId==saved.vehicleId and other.otherNodeCid==edge.node.cid then
          reciprocal=other;break
        end
      end
      if not reciprocal then return nil,'The game could not confirm both ends of a parked coupling. Check the connected vehicles and try again.' end
      local a,b={inventoryId=tostring(id),node=edge.node},{inventoryId=partnerId,node=reciprocal.node}
      local ak,bk=a.inventoryId..':'..a.node.name,b.inventoryId..':'..b.node.name
      local key=ak<bk and ak..'/'..bk or bk..'/'..ak
      if not seen[key] then
        if not a.node.canAttach and not b.node.canAttach then return nil,'A parked connection cannot be restored automatically. Unhook those vehicles before exporting.' end
        local preferB=b.node.canAttach and (b.node.kind=='fifthwheel' and a.node.kind~='fifthwheel'
          or b.node.kind==a.node.kind and bk<ak)
        if not a.node.canAttach or preferB then a,b=b,a end
        edges[#edges+1]={a=a,b=b};seen[key]=true
      end
    end
  end
  return edges
end
local function findNode(data,name)
  local found
  for _,node in pairs(data and data.vdata and data.vdata.nodes or {}) do
    if node.name==name then if found then return nil end;found=node.cid end
  end
  return found
end
function M.resolve(spawned,edges,vehicleIdFor,dataFor)
  local plan={}
  for id in pairs(spawned) do
    local vehicleId=vehicleIdFor(tonumber(id))
    if not vehicleId then return nil,'A parked vehicle is missing on the way back.' end
    plan[id]={vehicleId=vehicleId,edges={}}
  end
  for _,edge in ipairs(edges or {}) do
    local a,b=plan[edge.a.inventoryId],plan[edge.b.inventoryId]
    if not a or not b then return nil,'A saved coupling partner is missing.' end
    local ac=findNode(dataFor(a.vehicleId),edge.a.node.name)
    local bc=findNode(dataFor(b.vehicleId),edge.b.node.name)
    if not ac or not bc then return nil,'A saved coupling node is missing. Check the vehicle mods before returning.' end
    a.edges[#a.edges+1]={name=edge.a.node.name,cid=ac,otherVehicleId=b.vehicleId,otherNodeCid=bc,settings=edge.a.node}
    b.edges[#b.edges+1]={name=edge.b.node.name,cid=bc,otherVehicleId=a.vehicleId,otherNodeCid=ac}
  end
  return plan
end
return M
