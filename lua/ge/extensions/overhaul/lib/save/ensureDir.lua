-- Creates a save folder through the save writer when it does not exist yet.
-- Owns the shared directory and parent-directory helpers that every save part uses.
local M = {}

-- Returns `directory` so a caller can build file paths from it.
function M.directory(writer, directory)
  if not writer.exists(directory) then
    writer.mkdir(directory)
  end
  return directory
end

-- The folder that holds `filePath`.
function M.parentOf(writer, filePath)
  return M.directory(writer, filePath:match("^(.*)/[^/]+$"))
end

return M
