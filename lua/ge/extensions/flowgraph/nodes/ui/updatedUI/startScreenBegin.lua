-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local C = {}

C.name = 'StartScreen Begin'
C.color = ui_flowgraph_editor.nodeColors.ui
C.description = 'Begins building the start screen. Use the "StartScreen" nodes and the "Screen Finish" nodes with this.'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '' },
  { dir = 'in', type = 'flow', name = 'reset', description = '', impulse = true },
  { dir = 'in', type = 'flow', name = 'triggerStart', description = 'when this is triggered, it will simulate a click on the start button', impulse = true },
  { dir = 'in', type = 'string', name = 'startButtonText', description = 'Text to display on the start button', default = "ui.scenarios.start.start" },
  { dir = 'in', type = 'bool', name = 'simple', description = 'Will remove replays interaction and the panel banner', default = false},
  { dir = 'out', type = 'flow', name = 'flow', description = ''},
  { dir = 'out', type = 'flow', name = 'build', description = '', chainFlow = true},
}

C.tags = { 'start', 'screen', 'intro', 'ui' }

function C:_executionStarted()
  self.started = false
  self.done = false
  self.built = false
  self.startTime = nil
end

function C:workOnce()
end

function C:work()
  if self.pinIn.reset.value then
    self.started = false
    self.done = false
    self.built = false
    self.startTime = nil
  end
  if self.pinIn.flow.value then
    if not self.built then
      self.mgr.modules.ui:startUIBuilding('startScreen', self)
      self.mgr.modules.ui:addHeader({header = self.graph.mgr.name})
      self.mgr.modules.ui:setStartButtonText(self.pinIn.startButtonText.value)
      if self.pinIn.simple.value then
        self.mgr.modules.ui:setStartScreenAsSimple()
      end
    end
    -- todo: this is a fallback to make sure the startscreen does not get stuck, because onUILayoutLoaded is not always called
    --[[
    if self.started and not self.done then
      if not self.startTime then
        self.startTime = os.time()
      elseif os.time() - self.startTime >= 2 then
        self.done = true
      end
    end
    ]]
    self.pinOut.build.value = not self.built
    self.built = true
    self.pinOut.flow.value = self.done
  else
    self.pinOut.flow.value = false
    self.pinOut.build.value = false
  end
  if self.pinIn.triggerStart.value then
    self:startFromUi()
  end
end

function C:startFromUi()
  --self.started = true
  self.done = true
  guihooks.trigger('ChangeState', {state ='play'})
end

--[[
-- disabled for now, because apps now load faster
function C:onUILayoutLoaded()
  if self.started then
    self.done = true -- the layout is finally ready, so now layout apps such as the countdown will work
  end
end
]]


return _flowgraph_createNode(C)
