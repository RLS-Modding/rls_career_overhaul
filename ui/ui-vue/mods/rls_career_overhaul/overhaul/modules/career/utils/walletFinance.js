// Shared presentation for the wallet history (pause menu Financial History and the phone Wallet).
// The Lua read model (playerAttributes.getFinancialHistoryView) owns grouping, sorting and totals;
// this file only names the choices, asks for a view, and formats what comes back.

const OWNER = "overhaul_career_economy_playerAttributes"

// Phone sorts for a list of groups (Vehicles, Work and Categories): groups sort on their net, the
// figure every group card shows. The pause menu uses SORT_CHOICES below for groups and rows alike.
export const GROUP_SORTS = [
  { id: "recent", label: "Most recent", sortBy: "date", direction: "desc" },
  { id: "highest", label: "Highest net", sortBy: "amount", direction: "desc" },
  { id: "lowest", label: "Lowest net", sortBy: "amount", direction: "asc" },
  { id: "name", label: "Name A to Z", sortBy: "name", direction: "asc" },
]

// Phone sorts for a list of transactions (Activity and a pulled-out card).
export const TRANSACTION_SORTS = [
  { id: "newest", label: "Newest first", sortBy: "date", direction: "desc" },
  { id: "oldest", label: "Oldest first", sortBy: "date", direction: "asc" },
  { id: "earnings", label: "Biggest earnings first", sortBy: "amount", direction: "desc" },
  { id: "costs", label: "Biggest costs first", sortBy: "amount", direction: "asc" },
]

// Grouping choices offered by both screens; ids are the read model's groupBy values.
export const GROUPINGS = [
  { id: "none", label: "None" },
  { id: "vehicle", label: "Vehicle" },
  { id: "source", label: "Work" },
  { id: "category", label: "Category" },
  { id: "period", label: "Month" },
]

// Every sort the read model offers, field and direction together, as one menu of plain words.
// value is "<sortBy>:<direction>".
// Labels stay short: the chosen one is the Sort button's face in a narrow toolbar.
export const SORT_CHOICES = [
  { value: "date:desc", label: "Newest" },
  { value: "date:asc", label: "Oldest" },
  { value: "amount:desc", label: "Largest" },
  { value: "amount:asc", label: "Smallest" },
  { value: "name:asc", label: "A to Z" },
  { value: "name:desc", label: "Z to A" },
]
export function parseSortChoice(value) {
  const [sortBy, direction] = String(value || "").split(":")
  const known = SORT_CHOICES.some(choice => choice.value === `${sortBy}:${direction}`)
  return known ? { sortBy, direction } : { sortBy: "date", direction: "desc" }
}

// Icons for the read model's own category ids (lib/finance/metadata.lua). Unknown ids (add-on
// categories) get the fallback, so a mod can post new categories without touching this file.
const CATEGORY_ICONS = {
  work_income: "banknotes", purchase: "carDealer", sale: "carCoins", repair: "wrench", insurance: "shieldCheckmark",
  fuel: "fuelPump", fine: "octagon", rent: "house", property: "house", service: "carsWrench", business: "garage01",
  transfer: "twoArrowsHorizontal", loan: "banknotes", interest: "banknotes", refund: "arrowsReplace", reward: "giftBoxOutline",
  gambling: "diceD6", cheat: "keys1",
}
export const FALLBACK_ICON = "banknotes"

export function categoryIcon(category) {
  return (category && (category.icon || CATEGORY_ICONS[category.id])) || FALLBACK_ICON
}
// Work types come from any feature or add-on, so they share one icon unless the data names one.
export function sourceIcon(source) {
  return (source && source.icon) || "career"
}

const NEUTRAL_ACCENT = "#8e8e93"
// Mid tones that read both as a swatch on the dark panels (over 4.5:1) and behind a white glyph
// on the phone's tiles (over 3:1).
export const WORK_ACCENT = "#2f9e4f"
export const UNRECORDED_ACCENT = "#8e8e93"
// Vehicles and months have no colour of their own; a stable pick from this set tells them apart.
const IDENTITY_ACCENTS = ["#5e5ce6", "#0a84ff", "#30b0c7", "#bf5af2", "#ff9f0a", "#ff375f"]
export function identityAccent(id) {
  let hash = 0x811c9dc5 // FNV-1a: similar ids (vehicle:...10, vehicle:...16) still spread
  for (const char of String(id)) hash = Math.imul(hash ^ char.charCodeAt(0), 0x01000193) >>> 0
  return IDENTITY_ACCENTS[hash % IDENTITY_ACCENTS.length]
}
export function accentOf(entry) {
  const accent = entry && entry.accent
  return typeof accent === "string" && /^#[0-9a-f]{6}$/i.test(accent) ? accent : NEUTRAL_ACCENT
}

const MINUS = "−"
// Round magnitude first so half-dollar costs and earnings agree with totals.
function roundedMoney(amount) {
  const value = Number(amount)
  return Number.isFinite(value) ? Math.sign(value) * Math.round(Math.abs(value)) : 0
}
function grouped(value) {
  return Math.abs(value).toLocaleString("en-US")
}
// "$1,234", or "−$1,234" below zero; no plus sign. For balances and labelled Earned or Spent totals.
export function formatMoney(amount) {
  const value = roundedMoney(amount)
  return `${value < 0 ? MINUS : ""}$${grouped(value)}`
}
// "+$1,234" or "−$1,234"; for rows and net figures where the sign is the meaning.
export function formatSigned(amount) {
  const value = roundedMoney(amount)
  if (value === 0) return "$0"
  return `${value > 0 ? "+" : MINUS}$${grouped(value)}`
}
// Money moved between the player's own accounts: kept out of Earned and Spent, but part of Net.
export function transferNet(totals) {
  return (Number(totals?.transfersIn) || 0) - (Number(totals?.transfersOut) || 0)
}
export function toneOf(amount) {
  const value = roundedMoney(amount)
  return value > 0 ? "income" : value < 0 ? "expense" : "neutral"
}

// Labelled relative time ("12 min ago", "2 h 5 min ago", "Yesterday", "3 days ago", then a date).
export function relativeTime(timestamp, nowSeconds = Date.now() / 1000) {
  if (!Number.isFinite(timestamp)) return "Time not recorded"
  const seconds = Math.max(0, nowSeconds - timestamp)
  if (seconds < 60) return "Just now"
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} min ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return minutes % 60 && hours < 6 ? `${hours} h ${minutes % 60} min ago` : `${hours} h ago`
  const days = Math.floor(hours / 24)
  if (days === 1) return "Yesterday"
  if (days < 7) return `${days} days ago`
  return new Date(timestamp * 1000).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })
}

export function countLabel(count, singular = "transaction", plural = `${singular}s`) {
  const value = Number(count) || 0
  return `${value.toLocaleString("en-US")} ${value === 1 ? singular : plural}`
}

// Ids the read model uses for "nothing recorded" or "not this kind of money" rather than a real
// vehicle or work type (lib/finance/readModel.lua).
const UNRECORDED_IDS = new Set(["unknown", "not_work", "not_vehicle_related"])
// Built-in English fallbacks and player/add-on names are display text. Only
// explicit game localization keys go through the translator.
export function displayName(name, translate = value => value) {
  return typeof name === "string" && name.startsWith("ui.") ? translate(name) : name
}
// Vehicle names from game data can say the model twice ("Autobello Piccolina Piccolina") and pad
// a trailing tag with spaces ("( Joe's Junk Career )"). Display only: stored labels are untouched.
export function tidyVehicleName(name) {
  if (typeof name !== "string") return name
  const words = name.replace(/\s+/g, " ").replace(/\(\s+/g, "(").replace(/\s+\)/g, ")").trim().split(" ")
  const sameRun = (start, size) => words.slice(start, start + size).join(" ").toLowerCase() === words.slice(start + size, start + 2 * size).join(" ").toLowerCase()
  let changed = true
  while (changed) {
    changed = false
    for (let size = Math.floor(words.length / 2); size >= 1 && !changed; size--) {
      for (let start = 0; start + 2 * size <= words.length; start++) {
        if (sameRun(start, size)) { words.splice(start + size, size); changed = true; break }
      }
    }
  }
  return words.join(" ")
}

// A game localization key such as "insurance.policies.dailyDriver1.name": three or more dotted
// parts and no spaces. Saved labels can hold one where the game would have shown its text.
const LOCALE_KEY = /^[A-Za-z][\w-]*(?:\.[\w-]+){2,}$/
export function localizedText(value, translate, fallback) {
  if (typeof value !== "string" || !LOCALE_KEY.test(value)) return value
  const text = translate(value)
  return typeof text === "string" && text && text !== value ? text : fallback
}
const vehicleName = (name, translate) => tidyVehicleName(displayName(name, translate))
// Group names on the Vehicles tab are vehicle names; every other tab shows its group name as is.
export function groupLabel(group, groupBy, translate) {
  const name = displayName(group?.name, translate)
  return groupBy === "vehicle" ? tidyVehicleName(name) : name
}
const known = entry => !!(entry && entry.id && !UNRECORDED_IDS.has(entry.id))
// Work pay: the row says so (isWork) and names its work type.
export const isWorkRow = row => !!row && Number(row.amount) > 0 && row.isWork !== false && known(row.source)

function locationSuffix(row, translate) {
  return row?.location?.id ? ` at ${displayName(row.location.name, translate)}` : ""
}

// "Uncategorized" says nothing about a row, so it is never shown as one.
const UNCATEGORIZED_ID = "unknown"

// One plain sentence under a row: what it was and what it was for, without separators.
// "Delivery in Gavril D15", "Fuel for Gavril D15", "Fines at Belasco", "Repair".
// Inside a group (groupBy) the part every row shares with the group is left out: a vehicle's rows
// don't repeat the vehicle, a category's rows don't repeat the category, work rows don't repeat
// the work type. Names from game data can be translation keys; pass the screen's translator.
export function rowSubtitle(row, translate = name => name, withLocation = true, groupBy = "none") {
  if (!row) return ""
  const work = isWorkRow(row)
  const sharedNoun = work ? groupBy === "source" : groupBy === "category" || row.category?.id === UNCATEGORIZED_ID
  const noun = sharedNoun ? "" : displayName((work ? row.source.name : row.category?.name) || "Transaction", translate)
  const vehicle = known(row.vehicle) && groupBy !== "vehicle" ? vehicleName(row.vehicle.name, translate) : ""
  // Work is done in a vehicle; purchases, sales and costs are for one.
  if (vehicle) return noun ? `${noun} ${work ? "in" : "for"} ${vehicle}` : vehicle
  const location = withLocation ? locationSuffix(row, translate) : ""
  if (noun) return noun + location
  return location ? displayName(row.location.name, translate) : ""
}

// Shorten only known built-in label shapes. The original text remains in the
// expandable transaction details along with vehicle and location context.
// Saved labels and custom/add-on titles are untouched. groupBy: see rowSubtitle.
export function transactionText(row, translate = value => value, groupBy = "none") {
  const name = displayName(row?.name, translate)
  let raw = typeof name === "string" && name ? name : "Transaction"
  let title = raw
  let subtitle = rowSubtitle(row, translate, true, groupBy)
  // A bought car names its seller as a labelled value in the details, not at the end of a sentence.
  const seller = row?.category?.id === "purchase" && row?.location?.id ? displayName(row.location.name, translate) : ""
  const insurance = row?.category?.id === "insurance" && raw.match(/^Insurance of '(.+)' changed to '(.+)'$/)
  if (insurance) {
    const car = tidyVehicleName(insurance[1])
    const policy = localizedText(insurance[2], translate, "")
    title = "Insurance changed"
    subtitle = `${car} with ${policy || "a new policy"}`
    raw = `Insurance of '${car}' changed to ${policy ? `'${policy}'` : "a new policy"}`
  } else if (row?.category?.id === "purchase" && raw.startsWith("Bought a vehicle: ")) {
    title = "Vehicle purchased"
    const car = tidyVehicleName(raw.slice("Bought a vehicle: ".length))
    subtitle = groupBy === "vehicle" ? "" : car
    raw = `Bought a vehicle: ${car}`
  } else if (row?.category?.id === "sale" && raw.startsWith("Sold a vehicle: ")) {
    title = "Vehicle sold"
    const car = tidyVehicleName(raw.slice("Sold a vehicle: ".length))
    subtitle = groupBy === "vehicle" ? "" : car
    raw = `Sold a vehicle: ${car}`
  } else if (isWorkRow(row) && row.source?.id === "delivery" && raw.startsWith("Rewards for ")) {
    title = "Delivery payment"
    subtitle = raw.slice("Rewards for ".length)
  }
  const context = rowSubtitle(row, translate, !seller)
  const location = known(row?.vehicle) && !seller ? locationSuffix(row, translate) : ""
  // The details only repeat the label when the title shortened it.
  return { title, subtitle, raw: raw === title ? "" : raw, context: context + location, seller }
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
// Period groups arrive as "2026-10" (a UTC month); show "October 2026". Screens say the months are UTC.
export function groupTitle(group, groupBy) {
  const match = groupBy === "period" && typeof group?.id === "string" && group.id.match(/^(\d{4})-(\d{2})$/)
  if (match) return `${MONTHS[Number(match[2]) - 1]} ${match[1]}`
  return group?.name || "Other"
}

// A real vehicle or work type, as opposed to "Unknown vehicle", "Not vehicle-related",
// "Unspecified work type" or the "Other money: ..." groups that sit beside work types.
export function isKnownGroup(group) {
  if (!known(group) || String(group.id).startsWith("other:")) return false
  return true
}

// One colour per group for every screen: categories bring their own, work is green, real vehicles
// and months get a stable colour, and groups with nothing recorded stay grey.
export function groupAccent(group, groupBy) {
  if (groupBy === "category") return accentOf(group?.category || group?.rows?.[0]?.category)
  if (groupBy === "period") return identityAccent(group?.id)
  if (!isKnownGroup(group)) return UNRECORDED_ACCENT
  return groupBy === "source" ? WORK_ACCENT : identityAccent(group.id)
}

// The read model returns Lua tables; empty Lua tables arrive as {} instead of [].
export function list(value) {
  if (Array.isArray(value)) return value
  return value && typeof value === "object" ? Object.values(value) : []
}

const EMPTY_TOTALS = { count: 0, incoming: 0, outgoing: 0, income: 0, expenses: 0, transfersIn: 0, transfersOut: 0, net: 0, operatingNet: 0 }

// One normalised view whatever the bridge returns (nothing, an error string, partial tables).
export function normalizeView(raw) {
  const view = raw && typeof raw === "object" ? raw : {}
  const rows = list(view.rows)
  const byId = new Map(rows.map(row => [row.id, row]))
  const groups = list(view.groups).map(group => ({
    ...group,
    rows: group.rowIds ? list(group.rowIds).map(id => byId.get(id)).filter(Boolean) : list(group.rows),
    totals: { ...EMPTY_TOTALS, ...(group.totals || {}) },
  }))
  return { balance: Number(view.balance) || 0, rows, groups, totals: { ...EMPTY_TOTALS, ...(view.totals || {}) }, options: view.options || {}, paging: view.paging }
}

// Ask the read model for a view. Resolves to a normalised view; a failed call resolves to null so
// the screen can keep what it shows and say the history could not load.
export async function requestFinanceView(lua, options) {
  const owner = lua && lua[OWNER]
  if (!owner || typeof owner.getFinancialHistoryView !== "function") return null
  try {
    const raw = await owner.getFinancialHistoryView(options)
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
    return normalizeView(raw)
  } catch (error) {
    console.warn("[Overhaul] Wallet history failed to load", error)
    return null
  }
}

// Largest spending first: the top categories that make up a group's or the wallet's spending.
export function spendingShares(groups, totalExpenses) {
  const spending = groups.filter(group => group.totals.expenses > 0)
  const total = totalExpenses ?? spending.reduce((sum, group) => sum + group.totals.expenses, 0)
  return spending
    .map(group => ({ id: group.id, name: group.name, accent: accentOf(group.category || group.rows[0]?.category), amount: group.totals.expenses, share: total ? group.totals.expenses / total : 0 }))
    .sort((a, b) => b.amount - a.amount)
}

// Where a pull-down menu opens: just under its trigger, in the screen's own (unscaled) pixels,
// since the phone can be drawn scaled.
export function menuTopBelow(trigger, root, gap = 6) {
  if (typeof trigger?.getBoundingClientRect !== "function" || typeof root?.getBoundingClientRect !== "function") return 0
  const triggerBox = trigger.getBoundingClientRect()
  const rootBox = root.getBoundingClientRect()
  const scale = rootBox.height / (root.offsetHeight || rootBox.height || 1)
  return Math.round((triggerBox.bottom - rootBox.top) / scale + gap)
}

// Where a small tooltip sits: centred over its target and just above it, in the screen's own
// (unscaled) pixels, kept this far from the root's left and right edges.
export function tooltipAbove(target, root, edge = 70, gap = 6) {
  if (typeof target?.getBoundingClientRect !== "function" || typeof root?.getBoundingClientRect !== "function") return { left: edge, top: 0 }
  const box = target.getBoundingClientRect()
  const rootBox = root.getBoundingClientRect()
  const scale = (rootBox.width || 1) / (root.offsetWidth || rootBox.width || 1)
  const width = root.offsetWidth || (rootBox.width || 0) / scale
  const centre = ((box.left || 0) + (box.width || 0) / 2 - (rootBox.left || 0)) / scale
  return { left: Math.round(Math.min(Math.max(centre, edge), Math.max(edge, width - edge))), top: Math.round(((box.top || 0) - (rootBox.top || 0)) / scale - gap) }
}

// One category's share of spending as a whole percent; a sliver reads "Under 1%", not "0%".
export function percentLabel(share) {
  const percent = (Number(share) || 0) * 100
  return percent > 0 && percent < 1 ? "Under 1%" : `${Math.round(percent)}%`
}

export function prefersReducedMotion() {
  return !!(globalThis.matchMedia && globalThis.matchMedia("(prefers-reduced-motion: reduce)").matches)
}
