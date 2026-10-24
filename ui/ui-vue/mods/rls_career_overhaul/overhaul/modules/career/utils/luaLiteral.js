// Decimal escapes have a fixed width so a following digit cannot become part of the escape.
function quoteString(value) {
  return `"${value.replace(/[\\"\x00-\x1f\x7f]/g, character => {
    if (character === "\\" || character === '"') return `\\${character}`
    return `\\${character.charCodeAt(0).toString().padStart(3, "0")}`
  })}"`
}

export function luaLiteral(value) {
  const ancestors = new Set()
  function encode(item) {
    if (item == null) return "nil"
    if (typeof item === "string") return quoteString(item)
    if (typeof item === "boolean") return String(item)
    if (typeof item === "number" && Number.isFinite(item)) return String(item)
    if (typeof item !== "object") throw new TypeError("Lua literals require finite numbers or serializable values")
    if (ancestors.has(item)) throw new TypeError("Lua literals cannot contain cycles")
    const prototype = Object.getPrototypeOf(item)
    if (!Array.isArray(item) && prototype !== null
      && (Object.getPrototypeOf(prototype) !== null || prototype.constructor?.name !== "Object")) {
      throw new TypeError("Lua literals require plain objects")
    }
    ancestors.add(item)
    const entries = Array.isArray(item)
      ? Array.from(item, encode)
      : Object.entries(item).map(([key, entry]) => `[${quoteString(key)}]=${encode(entry)}`)
    ancestors.delete(item)
    return `{${entries.join(",")}}`
  }
  return encode(value)
}
