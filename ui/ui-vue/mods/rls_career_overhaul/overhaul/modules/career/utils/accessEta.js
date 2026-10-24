// Shared h:mm:ss display for every vehicle access delay.
export function formatAccessEta(seconds) {
  const value = Number(seconds)
  const total = Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const pad = value => String(value).padStart(2, "0")
  return `${hours}:${pad(minutes)}:${pad(total % 60)}`
}
