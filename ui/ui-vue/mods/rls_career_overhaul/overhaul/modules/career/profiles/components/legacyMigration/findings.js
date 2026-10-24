// Pure findings seam for LegacyMigrationModal: turns the report's compatibility issues into severity buckets of grouped
// rows. No Vue and no bridge calls. The shell computes the buckets; the Review step only renders them.

const SEVERITY_ORDER = { blocker: 0, action: 1, warning: 2 }

const SEVERITY_BUCKETS = [
  { severity: "blocker", label: "Blocking", glyph: "✕" },
  { severity: "action", label: "Needs attention", glyph: "!" },
  { severity: "warning", label: "Warnings", glyph: "i" },
]

/** Repeated codes get one honest headline instead of N copies of the same sentence. */
const GROUP_TITLES = {
  "vehicle.contentMissing": n => `${n} vehicles cannot currently be spawned`,
  "vehicle.unreadable": n => `${n} vehicle records cannot be migrated safely`,
  "garage.contentMissing": n => `${n} garages cannot currently be found`,
}

/**
 * Longest phrase every title ends with, snapped to a word boundary so shared
 * trailing letters in names ("Bastion"/"Legran") are never eaten. Lets the expanded
 * rows drop "… cannot currently be spawned" once the headline has already said it.
 */
function sharedTitleSuffix(titles) {
  if (titles.length < 2) return ""
  let suffix = titles[0]
  for (let i = 1; i < titles.length && suffix; i++) {
    const other = titles[i]
    let n = 0
    while (n < suffix.length && n < other.length && suffix[suffix.length - 1 - n] === other[other.length - 1 - n]) n++
    suffix = suffix.slice(suffix.length - n)
  }
  const boundary = suffix.indexOf(" ")
  return boundary >= 0 ? suffix.slice(boundary) : ""
}

/** One group per severity and code, most severe first. Each group keeps only what its headline does not already say. */
export function buildIssueGroups(issues) {
  const byKey = new Map()
  for (const issue of issues) {
    const key = `${issue.severity}|${issue.code}`
    let group = byKey.get(key)
    if (!group) {
      group = { key, severity: issue.severity, code: issue.code, items: [] }
      byKey.set(key, group)
    }
    group.items.push(issue)
  }

  return [...byKey.values()]
    .map(group => {
      const count = group.items.length
      const sharedDetail = group.items.every(item => item.detail === group.items[0].detail)
        ? group.items[0].detail
        : null
      const suffix = sharedTitleSuffix(group.items.map(item => item.title))

      return {
        ...group,
        title: count === 1 ? group.items[0].title : GROUP_TITLES[group.code]?.(count) || `${group.items[0].title} + ${count - 1} more`,
        detail: count === 1 ? group.items[0].detail : sharedDetail,
        items: group.items.map(item => ({
          label: (suffix && item.title.endsWith(suffix) ? item.title.slice(0, -suffix.length).trim() : item.title) || item.title,
          extra: item.detail === sharedDetail ? "" : item.detail,
        })),
      }
    })
    .sort((a, b) => (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9))
}

/** Severity is a heading over its rows, so no row has to repeat it. Empty severities are left out. */
export function buildIssueBuckets(issues) {
  const groups = buildIssueGroups(issues)
  return SEVERITY_BUCKETS.map(bucket => {
    const bucketGroups = groups.filter(group => group.severity === bucket.severity)
    return { ...bucket, groups: bucketGroups, total: bucketGroups.reduce((sum, group) => sum + group.items.length, 0) }
  }).filter(bucket => bucket.groups.length > 0)
}
