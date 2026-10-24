-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/gameplay/pedestrian.lua (BeamNG 0.40).

-- Bus walker paths. Stock-derived: the sidewalk offset (calculateTarget) and ground snap of the
-- pedestrian prototype gameplay/pedestrian.lua from BeamNG 0.34-0.36.4 (beamArchive de4962ce; the
-- file left the game in 0.36.4 pt 2), kept here with
-- archivedUpstream. Only what bus walkers need is kept; the prototype's per-frame rays, kd-tree,
-- crossings and spawning are not. Spot separation and path sampling are Overhaul's.
return function()
  local UP = vec3(0, 0, 1)

  -- Distance of the walkable curb line from a road edge's centreline (the prototype's rule).
  local function sidewalkOffset(radius)
    return radius * 1.2 + 0.5
  end

  -- calculateTarget(edge, side) from the prototype, with the graph positions and radii passed in and
  -- the point taken `along` metres from the edge's first node (the prototype used its far node).
  -- side 1 is the right of travel from posA to posB, -1 the left.
  local function curbPoint(posA, posB, radiusA, radiusB, side, along)
    local targetVec = posB - posA
    local length = targetVec:length()
    if length < 1e-6 then return nil end
    local targetDir = targetVec / length
    local perpendicularDir = targetDir:perpendicular()
    local t = math.min(math.max((along or length) / length, 0), 1)
    local targetNodeRadius = radiusA + (radiusB - radiusA) * t
    local target = posA + targetVec * t
    target:setAdd(perpendicularDir * (-side * sidewalkOffset(targetNodeRadius)))
    return target, targetDir
  end

  -- The prototype's ground snap (be:getSurfaceHeightBelow), kept to one level: the surface is looked for
  -- from bandM above levelZ downwards and only accepted within bandM of levelZ, so an overpass or a ledge
  -- above and a drop below are ignored; with nothing in the band the point sits at levelZ. Without levelZ
  -- the point's own height is the level.
  -- The ground height at pos within bandM of levelZ, or nil when there is none on that level.
  local function groundAt(pos, levelZ, bandM)
    local level = levelZ or pos.z
    local band = bandM or 1.5
    local height = be:getSurfaceHeightBelow(vec3(pos.x, pos.y, level + band))
    if type(height) == 'number' and height >= level - band and height <= level + band then return height end
    return nil
  end

  local function snapToGround(pos, levelZ, bandM)
    local height = groundAt(pos, levelZ, bandM)
    return vec3(pos.x, pos.y, height or levelZ or pos.z)
  end

  -- Pushes horizontal points apart until no two are closer than minDist (n is at most the pool size).
  local function separate(points, minDist, passes)
    for _ = 1, passes or 6 do
      local moved = false
      for i = 1, #points do
        for j = i + 1, #points do
          local d = points[j] - points[i]
          d.z = 0
          local len = d:length()
          if len < minDist then
            local dir = len > 1e-6 and d / len or vec3(1, 0, 0)
            local push = dir * ((minDist - len) * 0.5)
            points[i] = points[i] - push
            points[j] = points[j] + push
            moved = true
          end
        end
      end
      if not moved then break end
    end
    return points
  end

  -- A polyline with its cumulative lengths; vertices are ground-snapped once here (on levelZ's level),
  -- never per frame.
  local function buildPath(points, snap, levelZ, bandM)
    local path = {points = {}, cum = {0}, length = 0}
    for i, p in ipairs(points) do path.points[i] = snap == false and vec3(p) or snapToGround(p, levelZ, bandM) end
    for i = 2, #path.points do
      local a, b = path.points[i - 1], path.points[i]
      path.length = path.length + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
      path.cum[i] = path.length
    end
    return path
  end

  -- Position and horizontal direction at `dist` along the path (clamped to its ends).
  local function sample(path, dist)
    local pts, cum = path.points, path.cum
    if #pts == 1 then return vec3(pts[1]), nil end
    dist = math.min(math.max(dist, 0), path.length)
    local i = 2
    while i < #pts and cum[i] < dist do i = i + 1 end
    local a, b = pts[i - 1], pts[i]
    local seg = cum[i] - cum[i - 1]
    local t = seg > 1e-6 and (dist - cum[i - 1]) / seg or 1
    local dir = vec3(b.x - a.x, b.y - a.y, 0)
    local len = dir:length()
    return a + (b - a) * t, len > 1e-6 and dir / len or nil
  end

  return {UP = UP, sidewalkOffset = sidewalkOffset, curbPoint = curbPoint, snapToGround = snapToGround, groundAt = groundAt,
    separate = separate, buildPath = buildPath, sample = sample}
end
