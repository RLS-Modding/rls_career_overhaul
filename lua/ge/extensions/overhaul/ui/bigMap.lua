-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/freeroam/vueBigMap.lua (BeamNG 0.40).

-- Big map data for Overhaul; the game's freeroam_vueBigMap forwards here while Overhaul runs.
-- Projections are built on enter and rebuilt lazily after an exit, extension reload or mod change.
local M = {}
local ownerGroups = require('overhaul/ui/bigMap/ownerGroups')
-- The game modules it calls are presets reloaded with each level, so they are not dependencies.
M.dependencies = {'overhaul_shell_patches'}

-- Config ------------------------------------------------------------------------------------------

local PATCH_ID = "vueBigMap"
local DEFAULT_POI_LIST_DISPLAY_MODE = "tree"
local POI_LIST_DISPLAY_MODES = {hidden = true, tree = true, simple = true}
local EVERYTHING_SECTION = "everything"
local FREEROAM_POIS_SECTION = "freeroamPois"
local TUTORIAL_SECTION = "tutorialLessonsBySection"

-- State -------------------------------------------------------------------------------------------

-- Projections for the current map visit; every read rebuilds them first when cacheValid is false.
local poiDataCache = {}
local groupStructureCache = {}
local filterStructureCache = {}
local gameStateInfoCache = {}
local cacheValid = false
local ownerGroupsCache

-- Kept across cache rebuilds so the chosen filters stick for the session.
local filterVisibilityState = {}
-- Set by a full-list selection so the details panel shows that one POI instead of its hover group.
local ignoreNextReductionFlag = false

-- Action callbacks are keyed by id, because the Vue side only sends the id back.
M.actionIdCounter = 0
M.actionFunctions = {}

-- Shared helpers ----------------------------------------------------------------------------------

local function invalidateCache()
  poiDataCache = {}
  groupStructureCache = {}
  gameStateInfoCache = {}
  filterStructureCache = {}
  cacheValid = false
  ownerGroupsCache = nil
end

-- The Vue side sends "undefined" and "null" strings for an empty selection.
local function cleanPoiId(poiId)
  if poiId == "undefined" or poiId == "null" then return nil end
  return poiId
end

local function getOwnerGroups()
  if not ownerGroupsCache then ownerGroupsCache = ownerGroups.load() end
  return ownerGroupsCache
end

local function mapMode()
  return overhaul_career_career.isActive() and 'career' or 'freeroam'
end

local function registeredSectionGroups(section, groups)
  return ownerGroups.sectionGroups(getOwnerGroups(), mapMode(), section, groups)
end

local function getFreeActionId()
  M.actionIdCounter = M.actionIdCounter + 1
  return M.actionIdCounter
end

local function clearActionFunctions()
  M.actionFunctions = {}
end

local function addAction(callback, meta)
  local actionId = getFreeActionId()
  M.actionFunctions[actionId] = callback
  meta = meta or {}
  meta.actionId = actionId
  return meta
end

local function executeAction(actionId)
  local callback = M.actionFunctions[actionId]
  if not callback then
    log("E", "", "Action function not found for ID: " .. tostring(actionId))
    return "error"
  end
  callback()
  return "success"
end

-- Filter visibility -------------------------------------------------------------------------------

local function toggleFiltersByIds(filterIds)
  for filterId in pairs(filterVisibilityState) do filterVisibilityState[filterId] = false end
  for _, filterId in ipairs(filterIds) do filterVisibilityState[filterId] = true end
  M.setVisibleIds()
end

local function setSectionGroupsVisible(section, visible)
  for _, group in ipairs(section.groups) do filterVisibilityState[group.key] = visible end
end

local function toggleFilterSectionById(sectionId)
  if sectionId == EVERYTHING_SECTION then
    for _, section in ipairs(groupStructureCache) do setSectionGroupsVisible(section, true) end
  else
    for _, section in ipairs(groupStructureCache) do setSectionGroupsVisible(section, false) end
    for _, section in ipairs(groupStructureCache) do
      if section.key == sectionId then setSectionGroupsVisible(section, true) end
    end
  end
  M.setVisibleIds()
end

-- POI formatting ----------------------------------------------------------------------------------

local function poiActions(poi, quickTravelEnabled)
  local actions = {}
  table.insert(actions, addAction(
    function() freeroam_bigMapMode.navigateToMission(poi.id) end,
    {id = "setRoute", label = "bigMap.action.setRoute", icon = "mapPoint", soundClass = 'bng_click_set_route'}
  ))
  -- Quick travel is freeroam-only, and only for POIs whose marker offers a teleport.
  if quickTravelEnabled then
    table.insert(actions, addAction(
      function() freeroam_bigMapMode.teleportToPoi(poi.id) end,
      {id = "quickTravel", label = "bigMap.action.quickTravel", icon = "fastTravel"}
    ))
  end
  return actions
end

local function formatPoiForBigmap(poi)
  local bmi = poi.markerInfo.bigmapMarker
  local quickTravelEnabled = (not overhaul_career_career.isActive()) and bmi.quickTravelPosRotFunction
  local poiType = getOwnerGroups().types[poi.data.type]
  return {
    id = poi.id,
    icon = bmi.cardIcon or (poiType and poiType.icon) or 'info',
    name = bmi.name,
    description = bmi.description,
    thumbnailFile = bmi.thumbnail,
    previewFiles = bmi.previews,
    type = poi.data.type,
    label = '',
    pos = bmi.pos,
    radius = bmi.radius or 0,
    aggregatePrimary = bmi.aggregatePrimary,
    aggregateSecondary = bmi.aggregateSecondary,
    actions = poiActions(poi, quickTravelEnabled),
    order = poi.data.order,
  }
end

-- Group data --------------------------------------------------------------------------------------

local function buildGroupData()
  local groupData = ownerGroups.groupData(getOwnerGroups(), mapMode())
  extensions.hook("onBigmapBuildGroupData", groupData)
  for _, group in pairs(groupData) do group.elements = {} end
  return groupData
end

-- Each tutorial section is its own group; the last lesson read sets the section's order.
local function addTutorialSectionGroup(poi, groupData, filterData)
  local sectionId = poi.data.tutorialSectionId or "tutorial"
  local groupKey = "tutorialSection_" .. tostring(sectionId)
  local sectionIndex = poi.data.tutorialSectionIndex or math.huge
  local isTimeTrialsSection = sectionId == "timeTrials"
  groupData[groupKey] = groupData[groupKey] or {
    label = poi.data.tutorialSectionLabel or "bigMap.group.tutorial",
    elements = {},
  }
  groupData[groupKey].tutorialSectionIndex = sectionIndex
  groupData[groupKey].tutorialIsTimeTrials = isTimeTrialsSection
  filterData.groupTags[groupKey] = true
end

local function typeGroupTags(poi)
  local poiType = getOwnerGroups().types[poi.data.type]
  return poiType and poiType.tags or {'type_other'}
end

local function processNonMissionPoi(poi, groupData)
  local formatted = formatPoiForBigmap(poi)
  local filterData = {groupTags = {}, sortingValues = {id = poi.id}}
  if poi.data.type == "tutorialLesson" then
    addTutorialSectionGroup(poi, groupData, filterData)
  else
    for _, tag in ipairs(typeGroupTags(poi)) do filterData.groupTags[tag] = true end
  end
  for _, tag in ipairs(poi.data.customGroupTags or {}) do filterData.groupTags[tag] = true end
  return formatted, filterData
end

local function addTutorialMarkerData(poi)
  local utils = gameplay_discover_freeroamTutorial_tutorialBigMapUtils
  if utils and utils.addBigmapMarkerDataToPoi then utils.addBigmapMarkerDataToPoi(poi) end
end

local function addPoiToTagGroups(poi, filterData, groupData)
  for tag, include in pairs(filterData.groupTags) do
    if include then
      if not groupData[tag] then
        log("W", "", "Unknown group tag: " .. dumps(tag) .. " for poi " .. dumps(poi.id))
        groupData[tag] = {label = tag, elements = {}}
      end
      table.insert(groupData[tag].elements, poi.id)
    end
  end
end

-- Formatted POIs carry no depth, so they order by id unless a group brings its own sort.
local function byDepthThenId(a, b)
  local aDepth = a.depth or 0
  local bDepth = b.depth or 0
  if aDepth == bDepth then return a.id < b.id end
  return aDepth < bDepth
end

local function sortGroupElements(groupData, poiData)
  for key, group in pairs(groupData) do
    local elementsAsPois = {}
    for i, id in ipairs(group.elements) do elementsAsPois[i] = poiData[id] end
    table.sort(elementsAsPois, group.sortFunction or byDepthThenId)
    for i in ipairs(elementsAsPois) do group.elements[i] = elementsAsPois[i].id end
    group.key = key
  end
end

local function buildPoiDataCache(level)
  gameplay_rawPois.clear()
  local poiData = {}
  local groupData = buildGroupData()
  for _, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(level)) do
    if poi.data and poi.data.type == "tutorialLesson" then addTutorialMarkerData(poi) end

    -- Mission POIs are excluded before formatting because Overhaul does not run missions.
    if poi.markerInfo.bigmapMarker and not (poi.data and poi.data.type == 'mission') then
      local formatted, filterData = processNonMissionPoi(poi, groupData)
      formatted.spriteIcon = poi.markerInfo.bigmapMarker.icon
      poiData[poi.id] = formatted
      poiData[poi.id].filterData = filterData
      addPoiToTagGroups(poi, filterData, groupData)
    end
  end
  sortGroupElements(groupData, poiData)
  return poiData, groupData
end

-- Tutorial groups ---------------------------------------------------------------------------------

local function tutorialGroupOrder(a, b)
  local aIsTimeTrials = a.tutorialIsTimeTrials == true
  local bIsTimeTrials = b.tutorialIsTimeTrials == true
  if aIsTimeTrials ~= bIsTimeTrials then return not aIsTimeTrials end

  local aSectionIndex = a.tutorialSectionIndex or math.huge
  local bSectionIndex = b.tutorialSectionIndex or math.huge
  if aSectionIndex == bSectionIndex then return tostring(a.key) < tostring(b.key) end
  return aSectionIndex > bSectionIndex
end

local function getTutorialGroupsSorted(groupsById)
  local tutorialGroups = {}
  for _, groupId in ipairs(tableKeysSorted(groupsById)) do
    local group = groupsById[groupId]
    if group and group.tutorialSectionIndex then table.insert(tutorialGroups, group) end
  end
  table.sort(tutorialGroups, tutorialGroupOrder)
  return tutorialGroups
end

local function isIncompleteTutorialLesson(poi)
  local utils = gameplay_discover_freeroamTutorial_tutorialBigMapUtils
  if utils and utils.isPoiIncompleteTutorialLessonForBigMapGroup then
    return utils.isPoiIncompleteTutorialLessonForBigMapGroup({data = poi})
  end
  if poi and poi.type == "tutorialLesson" and poi.lessonId and poi.lessonId ~= "" then
    return not gameplay_discover_freeroamTutorial_tutorial.isLessonCompleted(poi.lessonId)
  end
  return false
end

local function incompleteElementsOf(group, poisById)
  local incompleteElements = {}
  for _, poiId in ipairs(group.elements or {}) do
    if isIncompleteTutorialLesson(poisById[poiId]) then table.insert(incompleteElements, poiId) end
  end
  return incompleteElements
end

local function getIncompleteTutorialGroupsSorted(groupsById, poisById)
  local incompleteTutorialGroups = {}
  for _, group in ipairs(getTutorialGroupsSorted(groupsById)) do
    local incompleteElements = incompleteElementsOf(group, poisById)
    if #incompleteElements > 0 then
      table.insert(incompleteTutorialGroups, {
        key = group.key,
        label = group.label,
        icon = group.icon,
        elements = incompleteElements,
        tutorialSectionIndex = group.tutorialSectionIndex,
        tutorialIsTimeTrials = group.tutorialIsTimeTrials,
      })
    end
  end
  return incompleteTutorialGroups
end

-- The "everything" view lists each tutorial section with all its lessons, complete or not.
local function getAllTutorialGroupsForEverything(groupsById)
  local allTutorialGroups = {}
  for _, group in ipairs(getTutorialGroupsSorted(groupsById)) do
    table.insert(allTutorialGroups, {
      key = tostring(group.key) .. "_everything",
      label = group.label,
      icon = group.icon,
      elements = group.elements,
      tutorialSectionIndex = group.tutorialSectionIndex,
      tutorialIsTimeTrials = group.tutorialIsTimeTrials,
    })
  end
  return allTutorialGroups
end

-- Group structure ---------------------------------------------------------------------------------

local function tutorialLessonsSection(groupsById, poisById)
  local tutorialGroups = getIncompleteTutorialGroupsSorted(groupsById, poisById)
  if #tutorialGroups == 0 then return nil end
  return {
    key = TUTORIAL_SECTION,
    icon = 'bookOpened',
    title = 'bigMap.section.tutorialLessons',
    groups = tutorialGroups,
  }
end

local function customGroupSections(groupsById)
  local sections = {}
  local customGroupStructures = {}
  extensions.hook("onBigmapBuildCustomGroupStructures", customGroupStructures)
  for _, customGroupStructure in ipairs(customGroupStructures) do
    local customSection = {
      key = customGroupStructure.key,
      icon = customGroupStructure.icon,
      title = customGroupStructure.title,
      groups = {},
    }
    for _, group in ipairs(customGroupStructure.groupIds) do
      table.insert(customSection.groups, groupsById[group])
    end
    table.insert(sections, customSection)
  end
  return sections
end

local function freeroamSections(groupsById, allTutorialGroups)
  local sections = {
    {key = EVERYTHING_SECTION, icon = 'infinity', title = 'bigMap.sideMenu.pois', groups = allTutorialGroups},
    {
      key = FREEROAM_POIS_SECTION,
      icon = 'mapPoint',
      title = 'bigMap.section.otherPois',
      groups = registeredSectionGroups(FREEROAM_POIS_SECTION, groupsById),
    },
  }
  for _, section in ipairs(customGroupSections(groupsById)) do table.insert(sections, section) end
  return sections
end

local function careerSections(groupsById)
  local sections = {{
    key = FREEROAM_POIS_SECTION,
    icon = 'mapPoint',
    title = 'bigMap.sideMenu.pois',
    groups = registeredSectionGroups(FREEROAM_POIS_SECTION, groupsById),
  }}
  local branchOrdered = overhaul_career_progression_skills.orderBranchNamesKeysByBranchOrder()
  for _, domainId in ipairs(branchOrdered) do
    local domain = overhaul_career_progression_skills.getBranchById(domainId)
    if domain.isDomain then
      table.insert(sections, {
        key = 'domain_' .. domainId,
        icon = domain.icon,
        title = core_locales.translateWithOrWithoutContext(domain.name),
        groups = registeredSectionGroups('domain_' .. domainId, groupsById),
      })
    end
  end
  return sections
end

local function hasContent(structure)
  if structure.key == EVERYTHING_SECTION then return true end
  for _, group in ipairs(structure.groups) do
    if next(group.elements) then return true end
  end
  return false
end

local function buildGroupStructure(poisById, groupsById)
  local groupStructure = {}
  local tutorialSection = tutorialLessonsSection(groupsById, poisById)
  if tutorialSection then table.insert(groupStructure, tutorialSection) end

  local modeSections
  if overhaul_career_career.isActive() then
    modeSections = careerSections(groupsById)
  else
    modeSections = freeroamSections(groupsById, getAllTutorialGroupsForEverything(groupsById))
  end
  for _, section in ipairs(modeSections) do table.insert(groupStructure, section) end
  for _, section in ipairs(ownerGroups.extraSections(getOwnerGroups(), mapMode(), groupsById)) do
    table.insert(groupStructure, section)
  end

  local nonEmptyGroupStructure = {}
  for _, structure in ipairs(groupStructure) do
    if hasContent(structure) then table.insert(nonEmptyGroupStructure, structure) end
  end
  return nonEmptyGroupStructure
end

local function buildFilters(groupStructure)
  local filters = {}
  for _, section in ipairs(groupStructure) do
    local filterSection = {key = section.key, icon = section.icon, title = section.title, groups = {}}
    for _, group in ipairs(section.groups) do
      if filterVisibilityState[group.key] == nil then filterVisibilityState[group.key] = true end
      table.insert(filterSection.groups, {
        key = group.key,
        label = core_locales.translateWithOrWithoutContext(group.label),
        icon = group.icon,
        elementCount = #group.elements,
        visible = filterVisibilityState[group.key],
      })
    end
    table.insert(filters, filterSection)
  end
  return filters
end

-- Game state --------------------------------------------------------------------------------------

local function gameModeName()
  if overhaul_integration_services_missions_missionManager.getForegroundMissionId() then return "mission" end
  if overhaul_career_career.isActive() then return "career" end
  return "freeroam"
end

local function buildGameStateInfo(level)
  local info = {rules = {canSetRoute = true}}
  for _, lvl in ipairs(core_levels.getList()) do
    if string.lower(lvl.levelName) == level then
      info.levelData = deepcopy(lvl)
      info.levelData.titleMap = core_locales.contextTranslate('bigmap.titleMap', {level = _tr(lvl.title)})
    end
    systemYield()
  end
  info.gameMode = gameModeName()
  if overhaul_career_career.isActive() then
    info.rules.canSetRoute = not overhaul_career_market_testDrive.isActive()
  end
  return info
end

local function generateCacheData()
  log("I", "", "Generating cache data for bigmap...")
  local level = getCurrentLevelIdentifier()
  M.clearActionFunctions()

  local poisById, groupsById = buildPoiDataCache(level)
  local groupStructure = buildGroupStructure(poisById, groupsById)
  local filters = buildFilters(groupStructure)

  poiDataCache = poisById
  groupStructureCache = groupStructure
  filterStructureCache = filters
  gameStateInfoCache = buildGameStateInfo(level)
  cacheValid = true
end

-- Group and POI queries ---------------------------------------------------------------------------

local function setVisibleIds()
  local visibleIds = {}
  for _, groupSection in ipairs(groupStructureCache) do
    for _, group in ipairs(groupSection.groups) do
      if filterVisibilityState[group.key] and not group.hideFromMap then
        for _, poiId in ipairs(group.elements) do visibleIds[poiId] = true end
      end
    end
  end
  if freeroam_bigMapMode then freeroam_bigMapMode.setOnlyIdsVisible(tableKeys(visibleIds)) end
end

local function groupEntry(group)
  if not (filterVisibilityState[group.key] and group.elements and #group.elements > 0) then return nil end
  local elementIds = {}
  for _, poiId in ipairs(group.elements) do table.insert(elementIds, poiId) end
  return {
    key = group.key,
    label = core_locales.translateWithOrWithoutContext(group.label),
    icon = group.icon,
    elementIds = elementIds,
    visible = true,
    openByDefault = group.openByDefault,
  }
end

local function getPoiData()
  if not cacheValid then generateCacheData() end
  return poiDataCache
end

local function getFilters()
  if not cacheValid then generateCacheData() end
  for _, section in ipairs(filterStructureCache) do
    for _, group in ipairs(section.groups) do
      group.visible = filterVisibilityState[group.key]
    end
  end
  return filterStructureCache
end

local function getGroups()
  if not cacheValid then generateCacheData() end
  local groups = {}
  for _, section in ipairs(groupStructureCache) do
    local groupSection = {key = section.key, icon = section.icon, title = section.title, groups = {}}
    for _, group in ipairs(section.groups) do
      local entry = groupEntry(group)
      if entry then table.insert(groupSection.groups, entry) end
    end
    if #groupSection.groups > 0 then table.insert(groups, groupSection) end
  end
  return groups
end

local function getGameStateInfo()
  if not cacheValid then generateCacheData() end
  gameStateInfoCache.poiListDisplayMode = settings.getValue("poiListDisplayMode") or DEFAULT_POI_LIST_DISPLAY_MODE
  return gameStateInfoCache
end

-- Selection, actions and navigation ---------------------------------------------------------------

local function selectPoiFromList(poiId, isCollapsedMode)
  poiId = cleanPoiId(poiId)
  if freeroam_bigMapMode then
    if poiId then
      if not isCollapsedMode then ignoreNextReductionFlag = true end
      freeroam_bigMapMode.selectPoi(poiId)
    else
      freeroam_bigMapMode.deselect()
    end
  end
  return "success"
end

local function navigateToPoi(poiId)
  poiId = cleanPoiId(poiId)
  if poiId and freeroam_bigMapMode then freeroam_bigMapMode.navigateToMission(poiId) end
  return "success"
end

local function panToPoi(poiId)
  poiId = cleanPoiId(poiId)
  if poiId and freeroam_bigMapMode then freeroam_bigMapMode.panToPoi(poiId) end
  return "success"
end

local function onPoiSelectedFromBigmap(poiId)
  local selectedId = cleanPoiId(poiId)
  if not selectedId then
    guihooks.trigger("showPoiDetails", {})
    return
  end
  local poiIds = freeroam_bigMapMarkers.getIdsFromHoveredPoiId(selectedId)
  if ignoreNextReductionFlag then
    poiIds = {selectedId}
    ignoreNextReductionFlag = false
  end
  if tableIsEmpty(poiIds) then
    guihooks.trigger("showPoiDetails", {})
    return
  end
  guihooks.trigger("showPoiDetails", {poiIds = poiIds, ignoreReduction = ignoreNextReductionFlag})
end
M.poiSelectedFromBigmap = onPoiSelectedFromBigmap

local function hoverPoiFromList(poiId, active)
  if freeroam_bigMapMode then freeroam_bigMapMode.poiHovered(poiId, active) end
  return "success", active
end

local function executePoiAction(actionId)
  executeAction(actionId)
end

local function getAndClearPendingAutoSelectPoiId()
  if freeroam_bigMapMode and freeroam_bigMapMode.getAndClearPendingAutoSelectPoiId then
    return freeroam_bigMapMode.getAndClearPendingAutoSelectPoiId()
  end
end

-- Display mode ------------------------------------------------------------------------------------

local function setPoiListDisplayMode(mode)
  if not POI_LIST_DISPLAY_MODES[mode] then return "invalid_mode" end
  settings.setValue("poiListDisplayMode", mode)
  gameStateInfoCache.poiListDisplayMode = mode
  return "success"
end

-- Public API: map visit ---------------------------------------------------------------------------

-- Stock enter and exit only run while the stock bigmap mode exists, which is per level.
local function enterStockMap(options)
  local ignoreActionMaps = options.controllerUsed and options.isMenuBigmap
  local ignoreUiStateChange = options.ignoreUiStateChange
  if ignoreUiStateChange == nil then ignoreUiStateChange = options.isMenuBigmap end
  freeroam_bigMapMode.enterBigMap({
    instant = true,
    ignoreUiStateChange = ignoreUiStateChange,
    ignoreActionMaps = ignoreActionMaps,
  })
end

local function enterBigMap(options)
  options = options or {}
  if freeroam_bigMapMode then enterStockMap(options) end
  generateCacheData()
  M.setVisibleIds()
end

local function exitBigMap()
  if freeroam_bigMapMode then freeroam_bigMapMode.exitBigMap(true) end
  invalidateCache()
  clearActionFunctions()
end

-- Public API --------------------------------------------------------------------------------------

-- Vue reaches this map through the stock freeroam_vueBigMap names, which onExtensionLoaded forwards here.
M.enterBigMap = enterBigMap
M.exitBigMap = exitBigMap
M.getPoiData = getPoiData
M.getFilters = getFilters
M.getGroups = getGroups
M.toggleFiltersByIds = toggleFiltersByIds
M.toggleFilterSectionById = toggleFilterSectionById
M.getGameStateInfo = getGameStateInfo
M.selectPoiFromList = selectPoiFromList
M.getAndClearPendingAutoSelectPoiId = getAndClearPendingAutoSelectPoiId
M.navigateToPoi = navigateToPoi
M.panToPoi = panToPoi
M.hoverPoiFromList = hoverPoiFromList
M.executePoiAction = executePoiAction
M.setPoiListDisplayMode = setPoiListDisplayMode
M.setVisibleIds = setVisibleIds

M.getFreeActionId = getFreeActionId
M.clearActionFunctions = clearActionFunctions
M.addAction = addAction
M.executeAction = executeAction

-- Game hooks --------------------------------------------------------------------------------------

local FORWARDED_KEYS = {
  "enterBigMap", "exitBigMap", "getPoiData", "getFilters", "getGroups", "toggleFiltersByIds",
  "toggleFilterSectionById", "getGameStateInfo", "selectPoiFromList", "getAndClearPendingAutoSelectPoiId",
  "navigateToPoi", "panToPoi", "hoverPoiFromList", "executePoiAction", "setPoiListDisplayMode",
  "setVisibleIds", "getFreeActionId", "clearActionFunctions", "addAction", "executeAction",
}

-- A wrapper calls the map's current handler, and the stock function only when the map lacks one.
local function forwardTo(key)
  return function(original)
    return function(...)
      local handler = M[key]
      if type(handler) == "function" then return handler(...) end
      if type(original) == "function" then return original(...) end
    end
  end
end

M.onExtensionLoaded = function()
  invalidateCache()
  local wrappers = {onPoiSelectedFromBigmap = forwardTo("poiSelectedFromBigmap")}
  for _, key in ipairs(FORWARDED_KEYS) do wrappers[key] = forwardTo(key) end
  overhaul_shell_patches.registerFields(PATCH_ID, function() return freeroam_vueBigMap end, wrappers)
end

M.onExtensionUnloaded = function()
  invalidateCache()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

M.onModActivated = invalidateCache
M.onModDeactivated = invalidateCache

return M
