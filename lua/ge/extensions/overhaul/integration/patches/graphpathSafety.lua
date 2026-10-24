-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Keeps cycle-safe path unrolling; heap lifetime follows stock BeamNG 0.40.1.
-- Patches the live class while Overhaul runs; the stock graphpath module stays loaded.
-- Fork of stock lua/common/graphpath.lua (BeamNG 0.40.1).

local M = {}

local graphpath = require('graphpath')


local UNROLL_HOP_CAP = 100000
local sharedQueue

-- Stock's unroll is inline, so the search override remains necessary. Reuse its
-- non-yielding heap instead of allocating another heap for every traffic search.
local function stockQueue(original)
  for index = 1, math.huge do
    local name, value = debug.getupvalue(original, index)
    if not name then break end
    if name == 'que' then return value end
  end
end

local function patchedImpl(self, sourcePos, iter, targetPos, cutOffDrivability, dirMult, penaltyAboveCutoff, penaltyBelowCutoff, wZ, yieldFn)
  if sourcePos == nil or targetPos == nil or sourcePos == targetPos then return {} end

  local sourceNode, sourceCost, sourceXnorm = iter()
  if sourceNode == nil then return {} end

  local minCost = table.new(0, 32)
  minCost[sourceNode] = sourceCost
  local xnorms = table.new(0, 32)
  xnorms[sourceNode] = sourceXnorm
  local minParent = table.new(0, 32)
  minParent[sourceNode] = false

  local node, cost = sourceNode, sourceCost
  sourceNode, sourceCost, sourceXnorm = nil, nil, nil

  local graph = self.graph
  local positions = self.positions

  wZ = wZ or 1
  cutOffDrivability = cutOffDrivability or 0
  penaltyAboveCutoff = penaltyAboveCutoff or 1
  penaltyBelowCutoff = penaltyBelowCutoff or 10000

  local dirCoeff = {[true] = dirMult or 1, [false] = 1}
  local drivCoeff = {[true] = penaltyAboveCutoff, [false] = penaltyBelowCutoff}

  local road = table.new(0, 32)
  local targetMinCost = square(square(sourcePos.x-targetPos.x) + square(sourcePos.y-targetPos.y) + square(wZ * (sourcePos.z-targetPos.z)))
  local targetMinCostLink = nil
  local nodePos, tmpVec, nodeToTargetVec = vec3(), vec3(), vec3()

  local tmpNode = table.new(0, 2)
  local tmpEdge1Data = table.new(0, 4)
  local tmpEdge2Data = table.new(0, 4)

  if not yieldFn and not sharedQueue then sharedQueue = graphpath.newMinheap() end
  local que = yieldFn and graphpath.newMinheap() or sharedQueue
  que:clear()
  repeat
    profilerPushEvent("Graphpath:getPointToPointPathImpl")
    if road[node] == nil then
      road[node] = minParent[node]
      if node == targetPos then break end

      local nodeLinks
      if graph[node] then
        nodeLinks = graph[node]
        nodePos:set(positions[node])
      else
        local n1id, n2id = node[1], node[2]
        local edgeData = graph[n1id][n2id]
        local dist, driv, inNode, oneWay = edgeData.len, edgeData.drivability, edgeData.inNode, edgeData.oneWay
        local xnorm = xnorms[node]

        table.clear(tmpNode)

        tmpEdge1Data.len = dist * xnorm
        tmpEdge1Data.drivability = driv
        tmpEdge1Data.inNode = (inNode == n2id and node) or inNode
        tmpEdge1Data.oneWay = oneWay
        tmpNode[n1id] = tmpEdge1Data

        tmpEdge2Data.len = dist * (1 - xnorm)
        tmpEdge2Data.drivability = driv
        tmpEdge2Data.inNode = (inNode == n1id and node) or inNode
        tmpEdge2Data.oneWay = oneWay
        tmpNode[n2id] = tmpEdge2Data

        nodeLinks = tmpNode
        nodePos:setLerp(positions[n1id], positions[n2id], xnorm)
      end

      nodeToTargetVec:setSub2(targetPos, nodePos)
      local pathCost = cost + square(square(nodeToTargetVec.x) + square(nodeToTargetVec.y) + square(wZ * nodeToTargetVec.z))
      if pathCost < targetMinCost then
        que:insert(pathCost, targetPos)
        targetMinCost = pathCost
        minParent[targetPos] = node
        targetMinCostLink = nil
      end

      local parent = road[node]
      for child, edgeData in pairs(nodeLinks) do
        local edgeCost
        if road[child] == nil then
          edgeCost = edgeData.len * dirCoeff[edgeData.oneWay and edgeData.inNode == child] * drivCoeff[edgeData.drivability > cutOffDrivability]
          local pathToChildCost = cost + edgeCost
          if pathToChildCost < (minCost[child] or math.huge) then
            que:insert(pathToChildCost, child)
            minCost[child] = pathToChildCost
            minParent[child] = node
          end
        end

        if cost < targetMinCost and child ~= parent then
          tmpVec:setSub2(positions[child], nodePos)
          local xnorm = tmpVec:dot(nodeToTargetVec) / (tmpVec:squaredLength() + 1e-30)
          if xnorm > 0 and xnorm < 1 then
            tmpVec:setScaled(-xnorm)
            tmpVec:setAdd(nodeToTargetVec)
            pathCost = cost +
                      (edgeCost or edgeData.len * dirCoeff[edgeData.oneWay and edgeData.inNode == child] * drivCoeff[edgeData.drivability > cutOffDrivability]) * xnorm +
                      square(square(tmpVec.x) + square(tmpVec.y) + square(wZ * tmpVec.z))
            if pathCost < targetMinCost then
              que:insert(pathCost, targetPos)
              targetMinCost = pathCost
              minParent[targetPos] = node
              targetMinCostLink = child
            end
          end
        end
      end
    end

    if not sourceNode then
      sourceNode, sourceCost, sourceXnorm = iter()
    end

    if (que:peekKey() or math.huge) <= (sourceCost or math.huge) then
      cost, node = que:pop()
    else
      minCost[sourceNode] = sourceCost
      xnorms[sourceNode] = sourceXnorm
      minParent[sourceNode] = false
      node, cost = sourceNode, sourceCost
      sourceNode, sourceCost, sourceXnorm = nil, nil, nil
    end

    if yieldFn then yieldFn() end
    profilerPopEvent("Graphpath:getPointToPointPathImpl")
  until not node

  if not node then return {} end

  local path = {targetMinCostLink}
  local e = #path
  local target = road[node]
  local seen = table.new(0, 32)
  local hops = 0
  while target do
    if seen[target] or hops >= UNROLL_HOP_CAP then
      return {}
    end
    seen[target] = true
    hops = hops + 1
    e = e + 1
    path[e] = target
    target = road[target]
  end

  if e == 0 then return {} end

  if graph[path[e]] == nil then
    local tmp1 = path[e][1]
    local tmp2 = path[e][2]
    path[e] = nil
    e = e - 1
    if path[e] == tmp1 and path[e-1] ~= tmp2 then
      e = e + 1
      path[e] = tmp2
    elseif path[e] == tmp2 and path[e-1] ~= tmp1 then
      e = e + 1
      path[e] = tmp1
    end
  end

  for i = 1, e * 0.5 do
    path[i], path[e] = path[e], path[i]
    e = e - 1
  end

  return path
end

local PATCH_ID = 'graphpathSafety'
local graphpathClass

-- The Graphpath class is not exported; a throwaway instance exposes its metatable.
local function resolveClass()
  if not graphpathClass and type(graphpath.newGraphpath) == 'function' then
    local class = getmetatable(graphpath.newGraphpath(0))
    if type(class) == 'table' then graphpathClass = class end
  end
  return graphpathClass
end

local function onExtensionLoaded()
  overhaul_shell_patches.registerFields(PATCH_ID, resolveClass, {
    _getPointToPointPathImpl = function(original)
      if type(original) == 'function' then
        sharedQueue = stockQueue(original)
        return patchedImpl
      end
    end,
  })
end

local function onExtensionUnloaded()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

M.dependencies = {'overhaul_shell_patches'}
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
