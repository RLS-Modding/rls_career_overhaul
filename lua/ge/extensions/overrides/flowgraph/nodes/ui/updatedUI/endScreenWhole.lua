-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local ffi = require('ffi')

local C = {}

C.name = 'EndScreen Whole'
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.description = "Shows the end screen of a scenario with customizable buttons."
C.todo = "Showing two of these at the same time will break everything."
C.behaviour = {singleActive = true}

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '' },
  { dir = 'in', type = 'flow', name = 'reset', description = '', impulse = true },
  { dir = 'out', type = 'flow', name = 'flow', description = ''},
  --{ dir = 'in', type = 'string', name = 'title', description = 'Title of the menu.' },
  { dir = 'in', type = {'string','table'},  name = 'text', description = 'Subtext of the menu.' },
  { dir = 'in', type = 'bool', name = 'failed', hidden = true, description = 'If the player failed.' },
  { dir = 'in', type = 'table', name = 'change', description = 'Change from the attempt. use aggregate attempt node (test only)'},
  { dir = 'in', type = 'string', name = 'progressKey', description = 'Key for the attempt'},
  { dir = 'out', type = 'flow', name = 'build', description = '', chainFlow = true},
  { dir = 'in', type = 'bool', name = 'customBtnsFirst', hidden = true, description = 'If true, the custom buttons will show before the default buttons.' },
  { dir = 'out', type = 'flow', name = 'retry', description = 'When the player pressed "Retry".'},
  { dir = 'out', type = 'flow', name = 'contStart', description = 'When the player pressed "Continue at mission Start". Always available.'},
  { dir = 'out', type = 'flow', name = 'contHere', description = 'When the player pressed "Continue Here". Only available in career if using your own vehicle.'},
}

C.tags = { 'end', 'finish', 'screen', 'outro', 'ui' }

function C:init()
  self.open = false
  self.oldOptions = {}
  self.options = {}
  self.data.includeRetryButton = true
  self.data.autoBuild = true
end

function C:postInit()
  self.options = {}
  self:updateButtons()
end

function C:_executionStarted()
  for _, p in pairs(self.pinOut) do
    p.value = false
  end
  self.open = false
end

function C:drawCustomProperties()
  local reason = nil
  local remove = nil
  for i, btn in ipairs(self.options) do
    local txt = im.ArrayChar(64, btn)
    if im.InputText("##btn" .. i, txt, nil, im.InputTextFlags_EnterReturnsTrue) then
      if ffi.string(txt) == '' then
        remove = i
      else
        self.options[i] = ffi.string(txt)
        reason = "renamed button to" .. self.options[i]
      end
    end
  end
  if remove then
    for i = remove, #self.options do
      self.options[i] = self.options[i+1]
    end
    reason = "Removed an option."
  end
  if im.Button("add") then
    table.insert(self.options, "btn_"..(#self.options+1))
    reason = "added Button"
  end
  im.SameLine()
  if im.Button("rem") then
    self.options[#self.options] = nil
    reason = "removed Button"
  end
  if reason then
    self:updateButtons()
  end
  return reason
end

function C:updateButtons()
  local flowLinks = {}
  local strLinks = {}
  for _, lnk in pairs(self.graph.links) do
    if lnk.sourceNode == self and tableContains(self.oldOptions, lnk.sourcePin.name) then
      table.insert(flowLinks, lnk)
    end
    if lnk.targetNode == self and tableContains(self.oldOptions, lnk.targetPin.name) then
      table.insert(strLinks, lnk)
    end
  end
  local outPins = {}
  for _, pn in pairs(self.pinOut) do
    if tableContains(self.oldOptions, pn.name) then
      table.insert(outPins, pn)
    end
  end
  for _, pn in pairs(outPins) do
    self:removePin(pn)
  end
  local inPins = {}
  for _, pn in pairs(self.pinInLocal) do
    local contained = false
    for _, op in ipairs(self.oldOptions) do
      if pn.name == op or pn.name == op.."_active" then
        contained = true
      end
    end
    if contained then
      table.insert(inPins, pn)
    end
  end
  for _, pn in pairs(inPins) do
    self:removePin(pn)
  end
  self.oldOptions = {}
  for i, btn in ipairs(self.options) do
    self:createPin("in", "string", btn, btn)
    self:createPin("in", "bool", btn.."_active", true).hidden=true
    self:createPin("out", "flow", btn)
    self.oldOptions[i] = btn
  end

  for _, lnk in ipairs(flowLinks) do
    if lnk.sourcePin.name and self.pinOut[lnk.sourcePin.name] then
      self.graph:createLink(self.pinOut[lnk.sourcePin.name], lnk.targetPin)
    end
  end
  for _, lnk in ipairs(strLinks) do
    if lnk.targetPin.name and self.pinInLocal[lnk.targetPin.name] then
      self.graph:createLink(lnk.sourcePin, self.pinInLocal[lnk.targetPin.name])
    end
  end
end

function C:_onSerialize(res)
  res.options = deepcopy(self.options)
end

function C:_onDeserialized(nodeData)
  self.options = nodeData.options or {}
  self:updateButtons()
end

function C:_executionStopped()
  self:closeDialogue()
end

function C:_afterTrigger()
  --if self.pinIn.flow.value == false and self.open then
  --  self:closeDialogue()
  --end
end

function C:buttonPushed(action)
  for nm, pn in pairs(self.pinOut) do
    if nm == action then
      self.pinOut[nm].value = true
    end
  end

  self:closeDialogue()
end

function C:getCmd(action)
  return 'local n = core_flowgraphManager.getManagerGraphNode('..self.mgr.id..', '..self.graph.id..', '..self.id..') if n then n:buttonPushed("'..action..'") end'
end

function C:onResetGameplay()
  if self.open and self.data.includeRetryButton then
    log("I","","Closing End Screen because of reset!")
    self.pinOut.retry.value = true
    self:closeDialogue()
  end
end

function C:closeDialogue()
  if self.open then
    --core_gamestate.setGameState('freeroam', 'freeroam', 'freeroam')
    --guihooks.trigger('MenuHide')
    --guihooks.trigger('ChangeState', 'menu')
    self.open = false
  end
end

function C:onClientEndMission()
  self:closeDialogue()
end

function C:openDialogue()
  self.open = true




  -- BUTTONS --
  local customBtns, defaultBtns = {},{}
  -- WIP mission Button Stuff
  if self.mgr.activity and self.mgr.activity.nextMissions then
    for _, mid in ipairs(self.mgr.activity.nextMissions or {}) do
      local mission = gameplay_missions_missions.getMissionById(mid)
      if mission then
        table.insert(defaultBtns, self.mgr.modules.ui:addButton(
          function()
            gameplay_missions_missionManager.startFromWithinMission(gameplay_missions_missions.getMissionById(mid))
          end, {
          label = "Start Next Mission '" .. translateLanguage(mission.name, mission.name).."'",
          disabled = not mission.unlocks.startable
        }))
      end
    end
  end

  if self.data.includeRetryButton then
    local entryFee = {}
    local canPayFee = true
    local entryFeeAsList = nil
    if self.mgr.activity and career_career.isActive() then
      -- entry fee
      entryFee = self.mgr.activity:getEntryFee(userSettings) or {}
      local hasEntryFee = false
      canPayFee = true
      for key, value in pairs(entryFee) do
        hasEntryFee = hasEntryFee or value > 0
        if career_modules_playerAttributes.getAttributeValue(key) < value then
          canPayFee = false
        end
      end
      -- as list for the UI
      entryFeeAsList = {}
      local attributesSorted = tableKeys(entryFee)
      table.sort(attributesSorted, career_branches.sortAttributes)
      for _, key in ipairs(attributesSorted) do
        if entryFee[key] > 0 then
          table.insert(entryFeeAsList, {rewardAmount = entryFee[key], icon = career_branches.getBranchIcon(key), attributeKey = key})
        end
      end
      if not next(entryFeeAsList) then
        entryFeeAsList = nil
      end
    end


    table.insert(defaultBtns, self.mgr.modules.ui:addButton(
      function()
        if next(entryFee) and career_career.isActive() then
          print("(EndScreenWhole) Adding entry fee: " .. -math.abs(entryFee))
          career_modules_playerAttributes.addAttributes(-math.abs(entryFee), {label = "Entry Fee for Challenge"})
        end
        extensions.hook("onResetGameplay")
      end,
      {
        fee = entryFeeAsList,
        enabled = canPayFee,
        label = "ui.common.retry",
        disableReason = (not canPayFee) and "Can't pay entry fee.",
      }))
  end

  --only allow cont. here if:
  -- the user uses their own vehicle and career is active.
  -- career is not active
  local canContinueHere = (not career_career) or (not career_career.isActive()) or (self.mgr.activity.setupModules.vehicles.usePlayerVehicle and career_career and career_career.isActive())

  -- Temp fix: continue here only outside of career
  --local canContinueHere = (not career_career) or (not career_career.isActive())

  if not self.mgr.startedAsScenario then
    table.insert(defaultBtns, self.mgr.modules.ui:addButton(
        function()
          self:buttonPushed("contStart")
        end, {
        label = canContinueHere and "missions.missions.general.end.continueAtStart" or "ui.common.continue",
      }))
  else
    table.insert(defaultBtns, self.mgr.modules.ui:addButton(
        function()
          guihooks.trigger('ChangeState', {state = 'menu.scenarios'})
        end, {
        label = "ui.dashboard.scenarios",
      }))
  end

  if canContinueHere then
    table.insert(defaultBtns, self.mgr.modules.ui:addButton(
        function()
          self:buttonPushed("contHere")
        end, {
        label = "missions.missions.general.end.continueHere",
      }))
  end

  -- in the tutorial, restrict buttons manually.
  local isTutorial = career_modules_linearTutorial and (not career_modules_linearTutorial.getTutorialFlag('completedTutorialMission'))
  if isTutorial then
    defaultBtns = {
      self.mgr.modules.ui:addButton(
        function()
          self:buttonPushed("contHere")
        end, {
        label = "missions.missions.general.end.continueHere",
      })
    }
  end

  for _, btn in ipairs(self.options) do
    if self.pinIn[btn..'_active'].value and self.pinIn[btn].value and self.pinIn[btn].value ~= "" then
      table.insert(defaultBtns, self.mgr.modules.ui:addButton(
        function()
          self:buttonPushed(btn)
        end, {
        label = self.pinIn[btn].value,
      }))
    end
  end

  local buttonsTable = {}
  if self.pinIn.customBtnsFirst.value then
    for _, btn in ipairs(customBtns)  do table.insert(buttonsTable, btn) end
    for _, btn in ipairs(defaultBtns) do table.insert(buttonsTable, btn) end
  else
    for _, btn in ipairs(defaultBtns) do table.insert(buttonsTable, btn) end
    for _, btn in ipairs(customBtns)  do table.insert(buttonsTable, btn) end
  end

  arrayReverse(buttonsTable)

  if buttonsTable[1] then
    buttonsTable[1].focus = true
    buttonsTable[1].main = true
  end

  self.mgr.modules.ui.uiLayout.buttons = buttonsTable

  if self.data.autoBuild then
    self.mgr.modules.ui:addHeader({header = self.graph.mgr.name})
    self.mgr.modules.ui:addUIElement({type = 'textPanel', header = "Results", text = self.pinIn.text.value, attempt = self.pinIn.change.value.formattedAttempt, pages = {
      main = true,
    }})
    self.mgr.modules.ui:addObjectives(self.pinIn.change.value)
    self.mgr.modules.ui:addRatings(self.pinIn.change.value)
    self.mgr.modules.ui:finishUIBuilding()
  end
end

function C:onNodeReset()
  self:closeDialogue()
  for _,pn in pairs(self.pinOut) do
    pn.value = false
  end
  self.built = false
end

function C:work()
  if self.pinIn.reset.value then
    self:onNodeReset()
  end
  if self.pinIn.flow.value then
    if not self.built then
      if self.data.autoBuild then
        self.mgr.modules.ui:startUIBuilding('endScreen', self)
      end
      self:openDialogue()
    end
    self.pinOut.build.value = not self.built
    self.built = true
  else
    self.pinOut.flow.value = false
    self.pinOut.build.value = false
  end
  self.pinOut.flow.value = false

end

return _flowgraph_createNode(C)
