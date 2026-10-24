/** Normalize Lua bridge tables that may arrive as objects instead of arrays. */
export function asLuaArray(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object") return Object.values(value)
  return []
}
