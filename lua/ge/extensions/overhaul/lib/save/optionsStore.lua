-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Per-save option files under <slot>/career/rls_career/.
-- Options retain their defaults, pending-value precedence, broadcasts and original read/write boundaries.

local M = {}

M.RELATIVE_DIR = "career/rls_career"

-- The slot path of the active profile, or nil.
function M.currentSavePath()
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  return savePath
end

function M.dirPath(savePath)
  return savePath .. "/" .. M.RELATIVE_DIR
end

-- A store for one option file: fileName is relative to the option directory.
function M.new(fileName)
  local store = {fileName = fileName}

  store.currentSavePath = M.currentSavePath

  function store.path(savePath)
    return savePath .. "/" .. M.RELATIVE_DIR .. "/" .. fileName
  end

  -- Creates the directory through the running capture's writer (or the direct one).
  function store.ensureDir(savePath, writer)
    local dirPath = M.dirPath(savePath)
    writer = writer or overhaul_career_saveSystem.getSaveWriter()
    if not writer.exists(dirPath) then
      writer.mkdir(dirPath)
    end
    return dirPath
  end

  -- Creates the directory on disk at once, bypassing any capture writer.
  function store.ensureDirNow(savePath)
    local dirPath = M.dirPath(savePath)
    if not FS:directoryExists(dirPath) then
      FS:directoryCreate(dirPath)
    end
    return dirPath
  end

  function store.read(savePath)
    return jsonReadFile(store.path(savePath))
  end

  -- jsonWriteFileSafe joins a running save's capture; otherwise it writes at once.
  function store.write(savePath, payload)
    return overhaul_career_saveSystem.jsonWriteFileSafe(store.path(savePath), payload, true)
  end

  return store
end

return M
