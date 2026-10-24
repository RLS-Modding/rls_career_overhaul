// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Chat bubbles for NegotiationChatWindow, built from the offer history. Vehicle negotiations get the other
// party's words from Lua on each of their turns (entry.line = { text, pre, post }, chosen per seller type);
// hosts that send no lines (real estate) keep the default wording below.

// Varied wording so the thread reads like a conversation; [before, after] around the price.
const THEIR_COUNTER = [["How about ", "?"], ["Best I can do is ", "."], ["I could do ", "."], ["Meet me at ", "."], ["", " and we have a deal."]]
const THEIR_HOLD = [["I'm staying at ", "."], ["Still ", ". I'm not moving."], ["", " is where I'm at."]]
const MY_OFFER_BUY = [["I can do ", "."], ["How about ", "?"], ["My offer is ", "."], ["Would you take ", "?"], ["", " is as high as I'll go."]]
const MY_OFFER_SELL = [["I'd want ", "."], ["How about ", "?"], ["I can let it go for ", "."], ["", " and it's yours."]]
const TONE_BY_STATUS = { failed: "failed", counterOfferLastChance: "final", accepted: "deal" }
const pick = (list, i) => list[i % list.length]

// One of their turns in the words Lua chose; a walk-away carries no price.
function spokenTurn(key, line, status, amount) {
  const priced = status !== "failed" && (line.pre != null || line.post != null)
  return {
    key,
    from: "them",
    text: line.text || null,
    pre: priced ? line.pre || "" : undefined,
    amount: priced ? amount : null,
    post: priced ? line.post || "" : undefined,
    tone: TONE_BY_STATUS[status],
  }
}

export function buildConversation({ history, quote, awaitingOpening, amISelling, status }) {
  const entries = Array.isArray(history) ? history : []
  const out = []
  let quoteUsed = false
  let sawTheirs = false

  if (!entries.length || entries[0]?.theirOffer == null) {
    out.push({ key: "opening", from: "them", text: quote || (awaitingOpening ? "Make me an offer." : "Let's talk numbers."), amount: null })
    quoteUsed = true
  }

  let myCount = 0
  let theirCount = 0
  entries.forEach((h, i) => {
    const mine = h?.myOffer != null
    const amount = mine ? Number(h.myOffer) : Number(h?.theirOffer)
    const entryStatus = String(h?.negotiationStatus || "")
    if (mine) {
      if (entryStatus === "accepted") {
        out.push({ key: `m${i}`, from: "me", pre: "Deal at ", amount, post: ".", tone: "deal" })
      } else {
        const [pre, post] = pick(amISelling ? MY_OFFER_SELL : MY_OFFER_BUY, myCount++)
        out.push({ key: `m${i}`, from: "me", pre, amount, post })
      }
      if (entryStatus === "refused") out.push({ key: `r${i}`, from: "them", text: "No. That's too far off.", tone: "refused" })
      return
    }
    if (h?.theirOffer == null) return
    if (h.line) {
      sawTheirs = true
      quoteUsed = true
      out.push(spokenTurn(`t${i}`, h.line, entryStatus, amount))
      return
    }
    if (!sawTheirs) {
      sawTheirs = true
      quoteUsed = true
      const [pre, post] = amISelling ? ["I can pay ", "."] : ["I'm asking ", "."]
      out.push({ key: `t${i}`, from: "them", text: quote || null, pre, amount, post })
      return
    }
    if (entryStatus === "failed") {
      out.push({ key: `t${i}`, from: "them", text: "I'm done here. No deal.", tone: "failed" })
      return
    }
    if (entryStatus === "counterOfferLastChance") {
      out.push({ key: `t${i}`, from: "them", text: "That's it! Take it or leave it.", pre: "Final offer: ", amount, post: ".", tone: "final" })
      return
    }
    if (entryStatus === "accepted") {
      out.push({ key: `t${i}`, from: "them", pre: "Deal at ", amount, post: ".", tone: "deal" })
      return
    }
    const [pre, post] = entryStatus === "refused" ? pick(THEIR_HOLD, theirCount++) : pick(THEIR_COUNTER, theirCount++)
    out.push({ key: `t${i}`, from: "them", pre, amount, post })
  })

  // latest quote from Lua (e.g. a happy quote on acceptance) when it isn't already shown
  if (quote && !quoteUsed && out.length) {
    const last = out[out.length - 1]
    if (last.from === "them" && !last.text) last.text = quote
  }
  if (status === "failed" && !out.some(m => m.tone === "failed")) {
    out.push({ key: "failed", from: "them", text: "I'm done here. No deal.", tone: "failed" })
  }
  return out
}
