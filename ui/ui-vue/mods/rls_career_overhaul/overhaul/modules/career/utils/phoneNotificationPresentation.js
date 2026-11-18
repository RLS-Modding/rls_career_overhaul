// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// How a normalized phone notification is laid out on the banners (phone open or closed) and in the
// Notification Center. Text is shown as sent; this only decides which field goes where, which parts get
// colour, and how notifications group per app.

// Per kind: the title tone (only warnings and errors are tinted; the app icon carries identity), the
// glyph for senders without an app icon (bngIcons name) and the word screen readers hear first.
export const NOTIFICATION_STATUS = {
  success: { tone: '', icon: 'checkmark', label: 'Success' },
  rep: { tone: '', icon: 'star', label: 'Reputation' },
  warning: { tone: 'warn', icon: 'caution', label: 'Warning' },
  error: { tone: 'bad', icon: 'danger', label: 'Problem' },
  invite: { tone: '', icon: 'envelope', label: 'Offer' },
  racing: { tone: '', icon: 'raceFlag', label: 'Race' },
  dakar: { tone: '', icon: 'flag', label: 'Rally' },
  info: { tone: '', icon: 'info', label: 'Info' },
}

// With "Hide content" on, a banner on the closed phone shows only its app: the kind (tone and spoken
// word) is part of what is hidden.
const HIDDEN_CONTENT_STATUS = { tone: '', icon: 'info', label: '' }

export function notificationStatus(item) {
  if (item?.presentationSimple) return HIDDEN_CONTENT_STATUS
  return NOTIFICATION_STATUS[item?.kind] || NOTIFICATION_STATUS.info
}

// The normalizer fills a missing title with this word, which says nothing on its own.
const PLACEHOLDER_TITLES = new Set(['notification'])

function cleanText(value) {
  return value == null ? '' : String(value).trim()
}

// A message that opens with the title ("Shift ended" / "Shift ended. Today's wages: ...") already
// says it; the title would only repeat its first words.
function messageRepeatsTitle(title, message) {
  if (!title || !message) return false
  if (title === message) return true
  if (!message.toLowerCase().startsWith(title.toLowerCase())) return false
  return /^[.:!?,;\-–—]/.test(message.slice(title.length).trimStart())
}

// Title, body and footer for one notification. A missing, placeholder or repeated title gives its place
// to the message (promoted: shown lighter than a real title), so no line repeats another. Racing
// notifications carry their body as subline. Hidden content shows none of it: the card shows only its
// app (see PhoneNotificationContent).
export function notificationLines(item) {
  if (!item || item.presentationSimple) return { title: '', message: '', footer: '', promoted: false }
  const rawTitle = cleanText(item.title)
  const message = cleanText(item.kind === 'racing' ? item.subline : item.message)
  const meta = item.kind === 'racing' ? '' : cleanText(item.meta)
  const titleSaysNothing = !rawTitle || PLACEHOLDER_TITLES.has(rawTitle.toLowerCase()) || messageRepeatsTitle(rawTitle, message)
  // The normalizer drops notifications without a message, so a title that says nothing always has one
  // to give its place to.
  return titleSaysNothing && message
    ? { title: message, message: '', footer: meta, promoted: true }
    : { title: rawTitle, message, footer: meta, promoted: false }
}

// Senders join footer values with "·", "•" or "|" ("$18.40 · 3.2 km"). The footer shows them as
// separate values with space between, so no separator dot is drawn.
const VALUE_JOINER = /\s+[·•|]\s+|\s*[·•]\s*/

// Line breaks and runs of spaces inside a value become single spaces, so the footer stays on one line.
export function footerValues(footer) {
  return cleanText(footer).split(VALUE_JOINER).map(value => cleanText(value).replace(/\s+/g, ' ')).filter(Boolean)
}

// Money ("$500", "$1,250.00", "+$80", "-$12.50", "$2.4M", "$500k") and signed percentages ("+18%").
// A sign only counts when it touches the amount and starts a word, so "Shop - $500" stays a plain
// amount and a range like "10-20%" is not read as a loss.
const MONEY_OR_DELTA = /(?<!\w)[+\-−]?\$\s?-?\d+(?:,\d{3})*(?:\.\d+)?[KMBTkmbt]?(?!\w)|(?<!\w)[+\-−]\d+(?:\.\d+)?%/g

function moneyDirection(token) {
  const sign = token.trim()[0]
  if (sign === '+') return 'gain'
  if (sign === '-' || sign === '−' || /\$\s?-/.test(token)) return 'loss'
  return token.includes('$') ? 'amount' : null
}

// Splits text into plain runs and money runs. Each money run says whether it reads as a gain, a
// loss or a plain amount, so the view can colour it.
export function moneySegments(text) {
  const source = cleanText(text)
  const segments = []
  let cursor = 0
  for (const match of source.matchAll(MONEY_OR_DELTA)) {
    const direction = moneyDirection(match[0])
    if (!direction) continue
    if (match.index > cursor) segments.push({ text: source.slice(cursor, match.index), money: null })
    segments.push({ text: match[0], money: direction })
    cursor = match.index + match[0].length
  }
  if (cursor < source.length) segments.push({ text: source.slice(cursor), money: null })
  return segments
}

// Groups notifications per app, keeping their order (newest first): each group lists its items newest
// first, and groups are ordered by their newest item. appKeyOf(item) names the app.
export function groupByApp(items, appKeyOf) {
  const groups = []
  const byKey = new Map()
  for (const item of items) {
    const key = appKeyOf(item)
    let group = byKey.get(key)
    if (!group) {
      group = { key, items: [] }
      byKey.set(key, group)
      groups.push(group)
    }
    group.items.push(item)
  }
  return groups
}

// Opened groups that are no longer stacks (cleared or opened down to one card, or gone) close, so the
// app's next notification arrives as a stack again. Changes `expanded` (a Set of group keys) in place.
export function closeFinishedGroups(expanded, groups) {
  const stacks = new Set(groups.filter(group => group.items.length > 1).map(group => group.key))
  for (const key of [...expanded]) {
    if (!stacks.has(key)) expanded.delete(key)
  }
}

// "now", "4m ago", "2h ago" from a receive time (ms) for the Notification Center.
export function receivedAgo(receivedAt, now = Date.now()) {
  const minutes = Math.floor(Math.max(0, now - (Number(receivedAt) || now)) / 60000)
  if (minutes < 1) return 'now'
  if (minutes < 60) return `${minutes}m ago`
  return `${Math.floor(minutes / 60)}h ago`
}
