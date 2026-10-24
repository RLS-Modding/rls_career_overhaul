-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/logbook.lua (BeamNG 0.40).
-- Logbook: unlock entries and tips the player can read, with read marking and popups, saved per career.
-- Keeps the stock layout on purpose so it still diffs against stock.

local M = {}
-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "progression.logbook", owner = "overhaul_career_progression_logbook", files = {"career/logbook.json"}, phase = "profile", required = true},
})

local fileName = "logbook.json"
local logbook = {}
local registry = require("overhaul/lib/progression/logbookRegistry")
local active = false
local historyLimit = 250
local function trimActivity()
  local count = 0
  for i = #logbook, 1, -1 do
    if logbook[i].overhaulEntryType then count = count + 1 end
  end
  for i = #logbook, 1, -1 do
    if count <= historyLimit then break end
    if logbook[i].overhaulEntryType then
      table.remove(logbook, i)
      count = count - 1
    end
  end
end
local idCounter =  0
local function sortByTimeAndId(a,b)
  if a.time == b.time and a.entryId and b.entryId then
    if type(a.entryId) == "number" and type(b.entryId) == "number" then
      return a.entryId > b.entryId
    else
      return tostring(a.entryId) > tostring(b.entryId)
    end
  else
    return a.time > b.time
  end
end

local function getLogbook()
  local ret = { }
  for _, e in ipairs(logbook) do
    table.insert(ret, e)
  end

  extensions.hook("onOverhaulLogbookGetEntries", ret)

  table.sort(ret, sortByTimeAndId)
  return ret
end

local function getPopups()
  local ret = {}
  for _, e in ipairs(logbook) do
    if not e.read and e.isPopup then
      table.insert(ret, e)
    end
  end
  return ret
end
M.getPopups = getPopups

local function getLogbookMostRecentUnread(limit)
  limit = limit or 3
  local ret = {}
  local byRead = {}
  byRead[true] = {}
  byRead[false] = {}
  for _, entry in ipairs(getLogbook()) do
    if not entry.hideInRecent then
      table.insert(byRead[entry.read or false], entry)
    end
  end
  for i = 1, limit do
    if next(byRead[false]) then
      table.insert(ret, byRead[false][1])
      table.remove(byRead[false],1)
    elseif next(byRead[true]) then
      table.insert(ret, byRead[true][1])
      table.remove(byRead[true],1)
    else
      return ret
    end
  end
  return ret
end
M.getLogbookMostRecentUnread = getLogbookMostRecentUnread

local function setLogbookEntryRead(entryId, read)
  if entryId == -1 then return end
  --print("Setting Logbook entry to read" .. entryId .. " ->  " ..dumps(read))
  for _, e in ipairs(logbook) do
    if e.entryId == entryId then
      e.isNew = not read
      return
    end
  end
end

-- this function is used by other functions to create the actual entry.
local function addNewLogbookEntry(entry, skipSave)
  entry = entry or {}
  entry.time = os.time()
  entry.entryId = idCounter
  entry.isNew = true
  idCounter = idCounter + 1
  if not skipSave then
    table.insert(logbook,1, entry)
    --log("I","","New Unlock Event: " ..dumps(entry))
    if entry.showMessage then
      local helper = {}
      helper.ttl = 15
      helper.msg = {txt="ui.career.logbook.newEntry", context={title=entry.title}}
      helper.category = entry.entryId
      helper.icon = "library_books"
      guihooks.trigger('Message',helper)
    end
  end
  return entry
end

-- called whenever a facility is unlocked
local function deliveryFacilityUnlocked(id)
  local fac = overhaul_career_logistics_generator.getFacilityById(id)
  if not id or not fac then return end
  addNewLogbookEntry({
    type = "progress",
    cardTypeLabel = "ui.career.poiCard.deliveryFacilityUnlocked",
    --missionId = id, -- ID needs to be for poi not mission...
    title = fac.name,
    text = {txt = 'ui.career.logbook.deliveryFacilityUnlockedNamed', context = {facilityName = fac.name}},
    cover = fac.preview,
  })
end

-- Plays the logbook sound at most once per frame. The reset is armed only when a sound plays: one update
-- clears the guard and unregisters itself, so the logbook keeps no per-frame hook while idle.
local playedLogbookSoundThisFrame = false
local function resetSoundGuard()
  playedLogbookSoundThisFrame = false
  M.onUpdate = nil
  extensions.hookUpdate("onUpdate")
end
local function playLogbookSound()
  if playedLogbookSoundThisFrame then return end
  Engine.Audio.playOnce('AudioGui', 'event:UI_Checkpoint')
  playedLogbookSoundThisFrame = true
  M.onUpdate = resetSoundGuard
  extensions.hookUpdate("onUpdate")
end
-- this is the "normal" logbook entry. a useful piece of info/tutorial/helps. also plays sound.
local function genericInfoUnlocked(title, text, cover, ratio, flavour, type)
  -- TODO: add name, description, cover etc
  local entry = addNewLogbookEntry({
    type = type or "info",
    cardTypeLabel = "ui.career.poiCard.generic",
    title = title,
    text = text,
    cover = cover,
    ratio = ratio or "16x9",
    showMessage = true,
  })

  playLogbookSound()
  return entry
end


-- this is a generic entry that can be anything, but nothing special.
local function genericLogbookEntry(title, text, cover, coverText)
  return addNewLogbookEntry({
    type = "info",
    cardTypeLabel = "ui.career.poiCard.generic",
    title = title,
    text = text,
    cover = cover,
    coverText = coverText,
    showMessage = true
  })
end


local logbookEntries = {
  'welcome',
  'logbook',
  'walkingMode',
  'cameras',
  'driving',
  'crashRecover',
  'bigmap',
  'refueling',
  'dealership',
  'testdrive',
  'computer',
  'partShopping',
  'tuning',
  'milestones',
  'delivery',
}

-- this creates a new logbook entry from an ID. it reads content and header from the folder in ui/modules/careerLogbook/pages/ID/ . Title is ui.introPopup.ID.title
M.logbookEntry = function(id)
  M.genericInfoUnlocked("ui.introPopup."..id..".title", readFile("/ui/modules/careerLogbook/pages/"..id.."/content.html"):gsub("\r\n",""), "/ui/modules/careerLogbook/pages/"..id.."/header.jpg")
end


local function loadDataFromFile()
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot then return end
  local data = (savePath and jsonReadFile(savePath .. "/career/"..fileName)) or {}
  logbook = data.logbook or {}
  idCounter = 0
  for _, e in ipairs(logbook) do
    if e.entryId and e.entryId >= idCounter then
      idCounter = e.entryId + 1
    end
  end
end

local function onOverhaulActive(value)
  active = value == true
  if not active then logbook = {}; return end
  loadDataFromFile()
  table.sort(logbook, sortByTimeAndId)
  trimActivity()
  if not next(logbook) then
    for _, key in ipairs(arrayReverse(logbookEntries)) do
      M.logbookEntry(key)
    end
  end
end

-- Registration is process-wide; records are profile-local and accepted only while active.
function M.onOverhaulLogbookEvent(id, payload)
  if not active then return end
  local entry = registry.build(id, payload)
  if not entry then return end
  if entry.receipt and entry.receipt ~= "" then
    for _, existing in ipairs(logbook) do
      if existing.overhaulEntryType == id and existing.receipt == entry.receipt then return end
    end
  end
  addNewLogbookEntry(entry)
  trimActivity()
end

-- this should only be loaded when the career is active
local function onOverhaulSaveCurrentProfile(currentSavePath)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/"..fileName,
    {
      logbook = logbook
    }, true)
end

local function onExtensionLoaded()
  if overhaul_career_career and overhaul_career_career.isActive then
    onOverhaulActive(overhaul_career_career.isActive() == true)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

M.getLogbook = getLogbook
M.setLogbookEntryRead = setLogbookEntryRead
M.addNewLogbookEntry = addNewLogbookEntry

M.deliveryFacilityUnlocked = deliveryFacilityUnlocked
M.genericInfoUnlocked = genericInfoUnlocked
M.genericLogbookEntry = genericLogbookEntry

return M
