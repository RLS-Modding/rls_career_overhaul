-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Activity resource: parking spot reservations. A per-activity wrapper over the reservation provider, with one owner token.
-- Remembers the spots it holds so releaseAll releases exactly those; the token is made on first use, drawing no random number.
local M = {}

-- The reservation provider, looked up on each call: opts.provider, else the running mode's service.
local function providerOf(state)
  return state.opts.provider or require('overhaul/lib/parking/reservation').service
end

local function ownerTokenOf(state)
  if not state.token then state.token = providerOf(state).makeReservationToken(state.owner) end
  return state.token
end

-- Remembers a held spot once, in reservation order.
local function remember(state, spot)
  if spot and not state.held[spot] then
    state.held[spot] = true
    state.order[#state.order + 1] = spot
  end
end

local function reserve(state, spot)
  local ok = providerOf(state).reserveSpot(spot, ownerTokenOf(state))
  if ok then remember(state, spot) end
  return ok
end

local function findAndReserve(state, candidates, options)
  local spot = providerOf(state).findReservableSpot(candidates, ownerTokenOf(state), options)
  if spot then remember(state, spot) end
  return spot
end

local function release(state, spot)
  if not spot then return false end
  local ok = providerOf(state).releaseSpot(spot, ownerTokenOf(state))
  if state.held[spot] then
    state.held[spot] = nil
    for i = #state.order, 1, -1 do
      if state.order[i] == spot then table.remove(state.order, i) end
    end
  end
  return ok
end

-- Release only this activity's claims, even if another owner replaced a reservation.
local function releaseAll(state)
  local released = 0
  for _, spot in ipairs(state.order) do
    if state.held[spot] then
      if providerOf(state).releaseSpot(spot, ownerTokenOf(state)) then released = released + 1 end
      state.held[spot] = nil
    end
  end
  state.order = {}
  return released
end

local function heldCount(state)
  local count = 0
  for _ in pairs(state.held) do count = count + 1 end
  return count
end

-- opts: provider (the reservation provider, tests), token (an existing owner token to reuse).
function M.create(owner, opts)
  opts = opts or {}
  local state = {owner = owner, opts = opts, token = opts.token, held = {}, order = {}}
  local parking = {}

  function parking.getOwner() return owner end
  function parking.getToken() return ownerTokenOf(state) end
  function parking.reserve(spot) return reserve(state, spot) end
  function parking.findAndReserve(candidates, options) return findAndReserve(state, candidates, options) end
  function parking.release(spot) return release(state, spot) end
  function parking.releaseAll() return releaseAll(state) end
  function parking.heldCount() return heldCount(state) end

  return parking
end

return M
