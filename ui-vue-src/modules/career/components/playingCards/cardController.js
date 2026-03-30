const SVG_URL = "/ui/entrypoints/main/rls_playingCards.svg"
const SVG_NS = "http://www.w3.org/2000/svg"

let svgCachePromise = null

const RANK_GROUPS = {
  A: "Ace",
  2: "_2", 3: "_3", 4: "_4", 5: "_5", 6: "_6",
  7: "_7", 8: "_8", 9: "_9", 10: "_10",
  J: "Jack", Q: "Queen", K: "King",
}

const ALL_RANK_IDS = Object.values(RANK_GROUPS)

const LARGE_SUITS = {
  spades: "Spade1",
  hearts: "Heart1",
  clubs: "Club1",
  diamonds: "Diamond1",
}

const SMALL_SUITS = {
  spades: "Spade2",
  hearts: "Heart2",
  clubs: "Club2",
  diamonds: "Diamond2",
}

const ACE_SUITS = {
  spades: "Spade",
  hearts: "Heart",
  clubs: "Club",
  diamonds: "Diamond",
}

const LARGE_SPADE_REF = "Spade1"
const SMALL_SPADE_REF = "Spade2"

const NUMBERED_RANKS = new Set(["2", "3", "4", "5", "6", "7", "8", "9", "10"])
const RED_SUITS = new Set(["hearts", "diamonds"])
const RED_FILL = "rgb(235,28,30)"

const COURT_PART_IDS = {
  Jack: ["Crown"],
  Queen: ["Crown1"],
  King: ["Crown2"],
}

// Approximate center of the raw spade path in its local coordinate space.
// Used to keep pips centered when rescaling.
const SPADE_CX = 289.3
const SPADE_CY = 358.0

function fetchSvg() {
  if (!svgCachePromise) {
    svgCachePromise = fetch(SVG_URL).then(r => {
      if (!r.ok) throw new Error(`Failed to load SVG: ${r.status}`)
      return r.text()
    })
  }
  return svgCachePromise
}

function q(root, selector) {
  return root.querySelector(selector)
}

function hide(el) {
  if (el) el.style.display = "none"
}

function show(el) {
  if (el) el.style.display = ""
}

function parseMatrix(el) {
  if (!el) return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }
  const t = el.getAttribute("transform")
  if (!t) return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }
  const m = t.match(/matrix\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)/)
  if (!m) return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }
  return {
    a: parseFloat(m[1]), b: parseFloat(m[2]),
    c: parseFloat(m[3]), d: parseFloat(m[4]),
    e: parseFloat(m[5]), f: parseFloat(m[6]),
  }
}

function relativeTransform(spadeRef, targetRef) {
  const s = parseMatrix(spadeRef)
  const t = parseMatrix(targetRef)
  const invA = 1 / s.a
  const invD = 1 / s.d
  return {
    a: invA * t.a,
    d: invD * t.d,
    e: invA * t.e + (-s.e * invA),
    f: invD * t.f + (-s.f * invD),
  }
}

function setTransform(el, a, d, e, f) {
  el.setAttribute("transform", `matrix(${a},0,0,${d},${e},${f})`)
}

function makeTransformGroup(rel) {
  const g = document.createElementNS(SVG_NS, "g")
  setTransform(g, rel.a, rel.d, rel.e, rel.f)
  return g
}

function setRank(root, rank) {
  for (const id of ALL_RANK_IDS) {
    hide(q(root, `#${id}`))
  }
  hide(q(root, "#Large-Suits"))
  hide(q(root, "#Small-Suits"))

  const targetId = RANK_GROUPS[rank]
  if (targetId) show(q(root, `#${targetId}`))
}

function swapSuit(root, rank, suit) {
  if (rank === "A") {
    for (const aceId of Object.values(ACE_SUITS)) {
      hide(q(root, `#${aceId}`))
    }
    const activeId = ACE_SUITS[suit]
    if (activeId) show(q(root, `#${activeId}`))
    return
  }

  if (NUMBERED_RANKS.has(String(rank))) {
    const groupId = RANK_GROUPS[rank]
    const group = q(root, `#${groupId}`)
    if (!group) return

    const spadeRef = q(root, `#${LARGE_SPADE_REF}`)
    const targetId = LARGE_SUITS[suit]
    const targetRef = q(root, `#${targetId}`)
    const largeSuitsGroup = q(root, "#Large-Suits")
    if (!spadeRef || !targetRef || !largeSuitsGroup) return

    const parentM = parseMatrix(largeSuitsGroup)
    const parentScale = parentM.a

    const rel = relativeTransform(spadeRef, targetRef)
    const templatePath = q(targetRef, "path")
    if (!templatePath) return

    const pipSlots = Array.from(group.children).filter(
      child => child.tagName === "g" && child.getAttribute("serif:id") === "Spade"
    )

    for (const slot of pipSlots) {
      if (!slot.hasAttribute("data-orig-transform")) {
        slot.setAttribute("data-orig-transform", slot.getAttribute("transform") || "")
      }
      const orig = slot.getAttribute("data-orig-transform")
      slot.setAttribute("transform", orig)
      const m = parseMatrix(slot)

      const newA = m.a * parentScale
      const newD = m.d * parentScale
      const newE = SPADE_CX * (m.a - newA) + m.e
      const newF = SPADE_CY * (m.d - newD) + m.f

      setTransform(slot, newA, newD, newE, newF)

      while (slot.firstChild) slot.removeChild(slot.firstChild)
      const wrapper = makeTransformGroup(rel)
      wrapper.appendChild(templatePath.cloneNode(true))
      slot.appendChild(wrapper)
    }
  }
}

function setSuitColor(root, rank, suit) {
  const isRed = RED_SUITS.has(suit)

  const v1Text = q(root, "#Value1 text")
  const v2Text = q(root, "#Value2 text")
  for (const textEl of [v1Text, v2Text]) {
    if (!textEl) continue
    textEl.style.fill = isRed ? RED_FILL : ""
  }

  for (const courtRank of Object.keys(COURT_PART_IDS)) {
    const parts = COURT_PART_IDS[courtRank]
    for (const partId of parts) {
      const group = q(root, `#${partId}`)
      if (!group) continue
      for (const p of group.querySelectorAll("path")) {
        const attr = p.getAttribute("style") || ""
        const hasGoldFill = attr.includes("fill:rgb(239,198,109)")
        if (hasGoldFill) continue
        p.style.fill = isRed ? RED_FILL : ""
      }
    }
  }
}

function setCorners(root, rank, suit) {
  const rankLabel = String(rank)

  const v1Text = q(root, "#Value1 text")
  const v2Text = q(root, "#Value2 text")
  if (v1Text) v1Text.textContent = rankLabel
  if (v2Text) v2Text.textContent = rankLabel

  const spadeRef = q(root, `#${SMALL_SPADE_REF}`)
  const targetId = SMALL_SUITS[suit]
  const targetRef = q(root, `#${targetId}`)
  if (!spadeRef || !targetRef) return

  const rel = relativeTransform(spadeRef, targetRef)
  const templatePath = q(targetRef, "path")
  if (!templatePath) return

  for (const suitId of ["Suit1", "Suit2"]) {
    const suitGroup = q(root, `#${suitId}`)
    if (!suitGroup) continue
    while (suitGroup.firstChild) suitGroup.removeChild(suitGroup.firstChild)
    const wrapper = makeTransformGroup(rel)
    wrapper.appendChild(templatePath.cloneNode(true))
    suitGroup.appendChild(wrapper)
  }

  setSuitColor(root, rank, suit)
}

function toggleSide(root) {
  const back = q(root, "#Back")
  const face = q(root, "#Face")
  if (!back || !face) return

  if (back.style.display === "none") {
    show(back)
    hide(face)
  } else {
    hide(back)
    show(face)
  }
}

function showSide(root, faceUp) {
  const back = q(root, "#Back")
  const face = q(root, "#Face")
  if (!back || !face) return

  if (faceUp) {
    hide(back)
    show(face)
  } else {
    show(back)
    hide(face)
  }
}

const CARD_RADIUS = 26

function roundRects(root) {
  for (const rect of root.querySelectorAll("rect")) {
    rect.setAttribute("rx", CARD_RADIUS)
    rect.setAttribute("ry", CARD_RADIUS)
  }
}

function initCard(root, rank, suit, faceUp) {
  roundRects(root)

  const face = q(root, "#Face")
  if (face) {
    const groups = [
      "Corner", "Ace", "Large-Suits", "Small-Suits",
      ...ALL_RANK_IDS.filter(id => id !== "Ace"),
    ]
    for (const id of groups) {
      hide(q(root, `#${id}`))
    }
  }

  showSide(root, faceUp)
  show(q(root, "#Corner"))
  setRank(root, rank)
  swapSuit(root, rank, suit)
  setCorners(root, rank, suit)
}

export { fetchSvg, initCard, setRank, swapSuit, setCorners, toggleSide, showSide }
