-- Racing team sponsors: offers in league 2, the sponsors the team has signed, and their bonus caps.
-- Offers are generated on a timer; accepting, declining or dropping one saves the team and the career.
local M = {}

local rtState = require('overhaul/career/business/racingTeam/racingTeam/runtimeState')

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

local function randomName()
  local pre = rtState.K.sponsorNamePrefixes[math.random(#rtState.K.sponsorNamePrefixes)]
  local suf = rtState.K.sponsorNameSuffixes[math.random(#rtState.K.sponsorNameSuffixes)]
  return tostring(pre or "Apex") .. " " .. tostring(suf or "Motors")
end

local function generateOffer()
  local now = rtState.parts.board.getCareerSimTime()
  local id = "rtspo-"
    .. tostring(math.floor((now % 1e7) * 1000))
    .. "-"
    .. tostring(math.random(1000, 9999))
  local bm = math.floor(5 + math.random() * 11)
  local bx = math.floor(5 + math.random() * 11)
  local lvInf = rtState.parts.board.getRacingTeamLevelInfo(rtState.parts.board.getRacingTeamLevelId())
  return {
    id = id,
    name = randomName(),
    bonusMoneyPercent = bm / 100,
    bonusXpPercent = bx / 100,
    focusLabel = lvInf.sponsorFocusLabel or (lvInf.league2InviteAcronym .. " team racing"),
    expiresAt = now + 2880,
  }
end

-- Position and index of the first entry whose id matches, or nil.
local function offerIndex(list, offerId)
  local want = tostring(offerId)
  for i, o in ipairs(list or {}) do
    if o and tostring(o.id) == want then
      return i, o
    end
  end
end

-- Writes the team's own file first, then the career save picks the change up.
local function persistAndSave(businessId)
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.parts.persist.saveRacingTeamPersistedState(businessId, savePath)
  end
  overhaul_career_saveSystem.saveCurrent()
end

local function removeOffer(businessId, list, offerId)
  local index = offerIndex(list, offerId)
  if not index then
    return false
  end
  table.remove(list, index)
  persistAndSave(businessId)
  return true
end

function M.getState(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  if not rtState.rtInternal.sponsors[id] then
    rtState.rtInternal.sponsors[id] = {
      available = {},
      active = {},
      nextOfferAt = 0,
    }
  end
  return rtState.rtInternal.sponsors[id]
end

function M.bonusTotals(businessId)
  local st = M.getState(businessId)
  local money = 0
  local xp = 0
  for _, s in ipairs(st.active or {}) do
    money = money + (tonumber(s.bonusMoneyPercent) or 0)
    xp = xp + (tonumber(s.bonusXpPercent) or 0)
  end
  money = math.min(rtState.K.RACING_TEAM_SPONSOR_BONUS_CAP, math.max(0, money))
  xp = math.min(rtState.K.RACING_TEAM_SPONSOR_BONUS_CAP, math.max(0, xp))
  return money, xp
end

function M.tickOffers(businessId)
  if rtState.rtInternal.getCurrentLeague(businessId) ~= "league2" then
    return
  end
  rtState.parts.helpers.getOfferState(businessId)
  local st = M.getState(businessId)
  local now = rtState.parts.board.getCareerSimTime()
  for i = #st.available, 1, -1 do
    local o = st.available[i]
    local ex = tonumber(o and o.expiresAt)
    if ex and now > ex then
      table.remove(st.available, i)
    end
  end
  if st.nextOfferAt <= 0 then
    st.nextOfferAt = now + 30
  end
  while #st.available < rtState.K.RACING_TEAM_SPONSOR_MAX_AVAILABLE do
    if st.nextOfferAt > now then
      break
    end
    table.insert(st.available, generateOffer())
    st.nextOfferAt = now + rtState.K.RACING_TEAM_SPONSOR_OFFER_INTERVAL_MIN + math.random(30, 90)
  end
end

function M.acceptOffer(businessId, offerId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not offerId then
    return false
  end
  if rtState.rtInternal.getCurrentLeague(businessId) ~= "league2" then
    return false
  end
  rtState.parts.helpers.getOfferState(businessId)
  local st = M.getState(businessId)
  local idx, picked = offerIndex(st.available, offerId)
  if not idx then
    return false
  end
  if #st.active >= rtState.K.RACING_TEAM_SPONSOR_MAX_ACTIVE then
    return false
  end
  table.remove(st.available, idx)
  table.insert(st.active, picked)
  persistAndSave(businessId)
  return true
end

function M.declineOffer(businessId, offerId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not offerId then
    return false
  end
  rtState.parts.helpers.getOfferState(businessId)
  return removeOffer(businessId, M.getState(businessId).available, offerId)
end

function M.dropActive(businessId, offerId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not offerId then
    return false
  end
  rtState.parts.helpers.getOfferState(businessId)
  return removeOffer(businessId, M.getState(businessId).active, offerId)
end

return M
