// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Shared by the expanded auction and its mini card. Lua validates again on bid.
export const auctionBidIncrement = (lot, amount = 250) => Math.max(Number(lot?.minStep) || 250, amount)
// The bid sizes both screens offer; a larger minimum step folds smaller ones together.
export const AUCTION_BID_CHOICES = [250, 500, 1000, 5000]
export const auctionBidAmounts = lot => [...new Set(AUCTION_BID_CHOICES.map(amount => auctionBidIncrement(lot, amount)))]
export const auctionCanBid =(state, lot) => !!lot && lot.state === 'active' &&
  state.phase === 'bidding' && lot.highestBidder !== 'player' &&
  !lot.isPlayerListing && state.hasFreeGarageSlot !== false
export const auctionCanAffordBid = (state, lot, amount) => state.hasFreeGarageSlot !== false &&
  (Number(state.playerBalance) || 0) >= (Number(lot?.currentBid) || 0) + auctionBidIncrement(lot, amount)
export function auctionBidReason(state, lot, amount = 250) {
  if (!lot || lot.state !== 'active' || state.phase !== 'bidding') return 'Waiting for bidding'
  if (lot.isPlayerListing) return 'Your consignment'
  if (state.hasFreeGarageSlot === false) return 'No free garage slot'
  if (lot.highestBidder === 'player') return 'You are leading'
  if (!auctionCanAffordBid(state, lot, amount)) return 'Not enough money'
  return ''
}
