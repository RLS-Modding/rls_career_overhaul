-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/log.lua (BeamNG 0.40).
-- Career log: keeps lines in memory and appends them to career.log in the profile on every save.
-- Read state, append helpers, the public log API and the save hook in order.

-- SaveStore keys for the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "ui.careerLog", owner = "overhaul_career_ui_log", files = {"career.log"}, phase = "profile", required = false, root = "profile"},
})

local M = {}

local LOG_FILE_NAME = "career.log"

local logLines = {}

local function addLog(message, origin, severity)
  table.insert(logLines, string.format("%d|%s|%s|%s", os.time(), severity or "I", origin or "", message))
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  local saveRoot = overhaul_career_saveSystem.getSaveRootDirectory()
  local saveSlot = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  addLog(string.format("Save game to %s", currentSavePath), "log")

  local file = io.open(saveRoot .. saveSlot .. "/" .. LOG_FILE_NAME, "a")
  if not file then return end

  file:write(table.concat(logLines, "\n") .. "\n")
  file:close()
  logLines = {}
end

local function onOverhaulActive(active)
  if not active then return end
  logLines = {}
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  addLog(string.format("Loaded game %s", savePath), "log")
end

M.addLog = addLog

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulActive = onOverhaulActive

return M
