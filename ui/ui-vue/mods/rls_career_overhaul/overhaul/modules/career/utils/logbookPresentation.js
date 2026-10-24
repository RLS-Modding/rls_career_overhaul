export const moneyValue = entry => typeof entry.money === "number" && Number.isFinite(entry.money) ? entry.money : undefined
export const formatMoney = value => `${value > 0 ? "+" : value < 0 ? "-" : ""}$${Math.abs(value).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
export const publicFacts = entry => Array.isArray(entry.facts) ? entry.facts.filter(f => f && typeof f.label === "string" && typeof f.value === "string").map(f => ({ ...f, kind: f.kind === "money" && f.value.trim() && Number.isFinite(Number(f.value)) ? "money" : undefined })).slice(0, 12) : []
export const relatedScreen = entry => entry.related === "journal" ? { route: "travel-journal", label: "Open travel journal" } : undefined
