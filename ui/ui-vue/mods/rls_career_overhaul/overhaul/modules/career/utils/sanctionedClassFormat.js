const CLASS_BRANCHES = ["stock", "modified", "super", "open"]

function normalizeClassTier(text) {
  const t = String(text || "").toLowerCase()
  if (t.includes("entry") || t.includes("low") || t.includes("lower")) return "entry"
  if (t.includes("upper") || t.includes("high")) return "upper"
  if (t.includes("mid") || t.includes("medium")) return "mid"
  return ""
}

function sanitizeBracketLabel(label) {
  const BRACKET_TIER_SUFFIX = /\s*\((?:low|lower|med|medium|mid|high|entry|upper)\s*hp\/kg\)\s*$/i
  const BRACKET_TIER_SUFFIX_PLAIN = /\s*\((?:low|lower|med|medium|mid|high|entry|upper)\)\s*$/i
  let s = String(label || "").replace(BRACKET_TIER_SUFFIX, "").replace(BRACKET_TIER_SUFFIX_PLAIN, "").trim()
  s = s.replace(/\s*\([^)]*hp\/kg[^)]*\)\s*$/i, "").trim()
  return s
}

export function pwBucketX1000(pw) {
  const n = Number(pw)
  if (!Number.isFinite(n) || n <= 0) return null
  return Math.floor((n * 1000) / 50) * 50
}

export function formatSanctionedClassCompact(label, branch) {
  const src = sanitizeBracketLabel(label).toLowerCase()
  const fromBranch = String(branch || "").toLowerCase()
  const b = CLASS_BRANCHES.find(v => src.includes(v)) || CLASS_BRANCHES.find(v => fromBranch.includes(v)) || ""
  const tier = normalizeClassTier(src)
  if (b && tier) return `${b}-${tier}`
  return b || ""
}

export function formatSanctionedClassWithBucket(label, classPwOrBucketSource, branch) {
  const compact = formatSanctionedClassCompact(label, branch)
  // Keep class display ordering stable across UI: Stock (100) ... Open (500+).
  // Open offers may carry very high classPwMax (unbounded top bracket), so use fixed 500+.
  if (compact === "open") return "open (500+)"
  const bucket = pwBucketX1000(classPwOrBucketSource)
  if (compact && bucket != null) return `${compact} (${bucket})`
  if (compact) return compact
  if (bucket != null) return `pw (${bucket})`
  return ""
}

