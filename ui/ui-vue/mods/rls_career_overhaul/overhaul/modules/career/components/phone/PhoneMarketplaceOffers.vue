<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <div class="offers-inbox" ref="offersRoot">
    <article v-for="row in rows" :key="row.key" class="offer-card" :class="{ unread: row.unread, expired: row.expired }">
      <div class="offer-head">
        <span class="avatar" :style="{ background: row.avatarBg }">{{ row.initials }}</span>
        <div class="offer-who">
          <div class="offer-name-row">
            <span class="buyer-name">{{ row.buyer }}</span>
            <span class="trait">{{ row.trait }}</span>
          </div>
          <div class="offer-vehicle">on {{ row.vehicle }}</div>
        </div>
        <div class="offer-value">
          <div class="offer-amount"><MoneyAmount>{{ row.valueText }}</MoneyAmount></div>
          <div class="offer-delta" :class="row.deltaGood ? 'good' : 'warn'"><template v-if="row.deltaAmountText"><MoneyAmount>{{ row.deltaAmountText }}</MoneyAmount> {{ row.deltaGood ? 'over' : 'under' }} asking</template><template v-else>{{ row.deltaText }}</template></div>
        </div>
      </div>

      <p v-if="row.quote" class="offer-quote">“{{ row.quote }}”</p>

      <div class="offer-foot">
        <span class="offer-timer" :class="{ urgent: row.urgent }">{{ row.timerText }}</span>
        <span class="offer-actions">
          <button type="button" class="btn btn--deny" :data-fk="`${row.key}-deny`" :aria-busy="busy" @click="denyOffer(row)">
            {{ row.expired ? 'Discard' : 'Deny' }}
          </button>
          <button v-if="row.canCounter" type="button" class="btn btn--counter" :data-fk="`${row.key}-counter`" :aria-busy="busy" @click="counterOffer(row)">
            Counter
          </button>
          <button v-if="!row.expired" type="button" class="btn btn--accept" :data-fk="`${row.key}-accept`" :aria-busy="busy" :disabled="row.acceptBlocked" @click="acceptOffer(row)">
            Accept
          </button>
        </span>
      </div>

      <p v-if="row.acceptBlocked" class="offer-blocked">{{ row.acceptBlockedReason }}</p>
    </article>

    <div v-if="!rows.length" class="mkt-empty">
      No live offers.<br>Buyers respond faster when you list near market value.
    </div>
  </div>
</template>

<script setup>
import { returnFocusToOpener } from "../../composables/useScreenEntryFocus.js"
import { useActionFocus } from "../../composables/useActionFocus.js"
import MoneyAmount from "../MoneyAmount.vue"
import { computed, ref } from 'vue'
import { lua } from '@/bridge'
import { usePhoneMarketplaceConfirm } from '../../composables/usePhoneMarketplaceConfirm'
import { usePhoneMarketplaceListings } from '../../composables/usePhoneMarketplaceListings'
import {
  avatarColour,
  avatarInitials,
  countdownText,
  traitLabel,
  usePhoneMarketplaceMoney,
} from '../../composables/usePhoneMarketplaceFormat'

const { money } = usePhoneMarketplaceMoney()
const { askConfirm } = usePhoneMarketplaceConfirm()
const { offers, isUnread, refreshListings } = usePhoneMarketplaceListings()

const offersRoot = ref(null)
const { busy, run } = useActionFocus(offersRoot)

const rows = computed(() => offers.value.map(entry => {
  const { offer, listing, index } = entry
  const buyer = offer.buyerPersonality?.name || offer.customer || 'Anonymous Buyer'
  const asking = Number(listing.value) || 0
  const value = Number(offer.value) || 0
  const delta = value - asking
  const expired = entry.expired
  const acceptBlocked = !!(listing.disabled || offer.disabled || listing.damagedAfterListing)

  return {
    key: entry.key,
    listingId: listing.id,
    offerIndex: index,
    offerId: offer.id,
    buyer,
    initials: avatarInitials(buyer),
    avatarBg: avatarColour(buyer),
    trait: traitLabel(offer.archetype || offer.buyerPersonality?.archetype, offer.buyerPersonality?.isDealership),
    vehicle: listing.niceName,
    quote: offer.quote,
    valueText: money(value),
    deltaText: delta === 0 ? 'Full asking price' : `${money(Math.abs(delta))} ${delta > 0 ? 'over' : 'under'} asking`,
    deltaGood: delta >= 0,
    deltaAmountText: delta === 0 ? '' : money(Math.abs(delta)),
    timerText: expired ? 'Expired' : `${countdownText(offer.secondsLeft)} left`,
    urgent: !expired && Number(offer.secondsLeft) < 90,
    expired,
    unread: !expired && isUnread(entry),
    // full-price offers have nothing to haggle over, so they simply lose the Counter button.
    // Post-list damage blocks accept/counter until the car is repaired.
    canCounter: !expired && offer.negotiationPossible !== false && !acceptBlocked && value < asking,
    acceptBlocked,
    acceptBlockedReason: listing.disableReason
      || offer.disableReason
      || (listing.damagedAfterListing ? 'This vehicle was damaged after listing. Repair it before accepting offers.' : ''),
  }
}))

function confirmOffer(message, action) {
  const opener = document.activeElement
  askConfirm(message, async () => {
    await returnFocusToOpener(() => opener)
    return run(action)
  })
}

function denyOffer(row) {
  if (busy.value) return
  const verb = row.expired ? 'Discard' : 'Decline'
  confirmOffer(`${verb} the ${row.valueText} offer from ${row.buyer}?`, async () => {
      if (row.offerId != null) await lua.overhaul_career_market_marketplace.declineOfferById(row.offerId)
      else await lua.overhaul_career_market_marketplace.declineOffer(row.listingId, row.offerIndex + 1)
      await refreshListings()
  })
}

function acceptOffer(row) {
  if (busy.value || row.acceptBlocked) return
  confirmOffer(`Accept ${row.valueText} from ${row.buyer} for your ${row.vehicle}?`, async () => {
      if (row.offerId != null) await lua.overhaul_career_market_marketplace.acceptOfferById(row.offerId)
      else await lua.overhaul_career_market_marketplace.acceptOffer(row.listingId, row.offerIndex + 1)
      await refreshListings()
  })
}

async function counterOffer(row) {
  if (busy.value || !row.canCounter) return
  return run(async () => {
    if (row.offerId != null) await lua.overhaul_career_market_marketplace.startNegotiateBuyingOfferById(row.offerId, true)
    else await lua.overhaul_career_market_marketplace.startNegotiateBuyingOffer(row.listingId, row.offerIndex + 1, true)
    await lua.extensions.ui_router.navigate('phone-marketplace-negotiate')
  })
}
</script>

<style scoped lang="scss">
@use '@/styles/rls_career_overhaul/modules/career/styles/_phone-marketplace.scss' as *;

.offers-inbox {
  display: flex;
  flex-direction: column;
  gap: 9px;
}

.offer-card {
  flex: none;
  padding: 12px;
  border-radius: 15px;
  background: rgba(23, 28, 37, 0.92);
  border: 1px solid rgba(255, 255, 255, 0.09);

  &.unread {
    border-color: rgba(126, 182, 255, 0.35);
  }

  &.expired {
    opacity: 0.6;
  }
}

.offer-head {
  display: flex;
  align-items: flex-start;
  gap: 10px;
}

.offer-who {
  flex: 1;
  min-width: 0;
}

.offer-name-row {
  display: flex;
  align-items: baseline;
  gap: 7px;
}

.buyer-name {
  font-size: 13px;
  font-weight: 700;
}

.trait {
  padding: 2px 6px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.6);
  font-size: 9.5px;
  font-weight: 600;
  white-space: nowrap;
}

.offer-vehicle {
  margin-top: 2px;
  font-size: 10.5px;
  color: rgba(255, 255, 255, 0.42);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.offer-value {
  flex: none;
  text-align: right;
}

.offer-amount {
  font-size: 17px;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
}

.offer-delta {
  margin-top: 2px;
  font-size: 10.5px;
  font-weight: 700;

  &.good { color: #6fe094; }
  &.warn { color: #ffad66; }
}

.offer-quote {
  margin: 9px 0 0;
  font-size: 11.5px;
  font-style: italic;
  line-height: 1.4;
  color: rgba(255, 255, 255, 0.62);
}

.offer-foot {
  display: flex;
  align-items: center;
  gap: 11px;
  margin-top: 10px;
}

.offer-timer {
  flex: none;
  font-size: 10.5px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 255, 255, 0.4);

  &.urgent { color: #ffad66; }
}

.offer-actions {
  display: flex;
  flex: 1;
  justify-content: flex-end;
  gap: 6px;
}

.btn {
  min-height: 36px;
  border-radius: 9px;
  font: inherit;
  font-size: 11.5px;
  font-weight: 700;
  cursor: pointer;

  &:disabled, &[aria-busy="true"] {
    opacity: 0.4;
    cursor: not-allowed;
  }
}

.btn--deny {
  padding: 7px 11px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: rgba(255, 255, 255, 0.05);
  color: rgba(255, 255, 255, 0.65);
  font-weight: 600;
}

.btn--counter {
  padding: 7px 12px;
  border: 1px solid rgba(126, 182, 255, 0.35);
  background: rgba(126, 182, 255, 0.12);
  color: #9ec8ff;
}

.btn--accept {
  padding: 7px 14px;
  border: none;
  background: #29c15a;
  color: #08130c;
}

.offer-blocked {
  margin: 8px 0 0;
  font-size: 10.5px;
  line-height: 1.35;
  color: #ffad66;
}
</style>
