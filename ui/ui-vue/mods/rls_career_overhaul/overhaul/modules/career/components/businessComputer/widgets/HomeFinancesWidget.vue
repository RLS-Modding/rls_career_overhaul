<template>
  <div
    class="rls-house home-widget finances-widget"
    :class="{ 'home-widget--compact': compact, 'home-widget--fill': fillHeight }"
  >
    <div class="widget-header">
      <h3>Finances</h3>
      <div class="balance-badge" :class="{ negative: accountBalance < 0 }">
        {{ moneySign(accountBalance) }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(accountBalance) }}
      </div>
    </div>

    <div class="widget-content">
      <div v-if="loading" class="loading-state">
        Loading...
      </div>
      <template v-else>
        <div class="tx-scroll scroll" bng-nav-item tabindex="0" aria-label="Transactions" v-bng-ui-nav-scroll.force>
          <div v-if="!sortedTransactions.length" class="empty-ledger">
            No transactions yet.
          </div>
          <ul v-else class="tx-list">
            <li
              v-for="(tx, idx) in displayTransactions"
              :key="tx.id != null ? String(tx.id) : `tx-${idx}-${tx.timestamp ?? ''}`"
              class="tx-row"
            >
              <div class="tx-row__info">
                <span class="tx-row__label">{{ getTransactionLabel(tx) }}</span>
                <span class="tx-row__date">{{ formatTxDate(tx.timestamp) }}</span>
              </div>
              <div
                class="tx-row__amount"
                :class="(tx.amount || 0) >= 0 ? 'credit' : 'debit'"
              >
                {{ (tx.amount || 0) >= 0 ? "+" : "−" }}<BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(tx.amount || 0) }}
              </div>
            </li>
          </ul>
        </div>

        <div class="finance-summary">
          <template v-if="sessionStore.hasCapability('fleetVehicles')">
            <div class="summary-item single team-expenses">
              <span class="value cost team-expenses__amount"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.total || 0) }}</span>
              <span class="label team-expenses__label">Team Expenses</span>
              <span v-if="!compact" class="team-expenses__note">FRE's completed in a team vehicle reward the team</span>
            </div>
          </template>
          <template v-else>
            <div class="summary-item single">
              <span class="label">Operating Costs</span>
              <span class="value cost"><BngIcon class="cur" :type="icons.beamCurrency" />{{ formatMoneyCompact(operatingCosts.total || 0) }}</span>
            </div>
          </template>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup>
import { vBngUiNavScroll } from "@/common/directives"
import { computed, ref, onMounted, onUnmounted } from "vue"
import { useBusinessSessionStore } from "../../../stores/businessComputer/businessSessionStore.js"
import { useBridge, lua } from "@/bridge"
import { formatMoneyCompact, moneySign } from "../../../utils/businessUtils"
import { BngIcon, icons } from "@/common/components/base"

const props = defineProps({
  compact: { type: Boolean, default: false },
  fillHeight: { type: Boolean, default: false },
})

const sessionStore = useBusinessSessionStore()
const { events } = useBridge()

const financesData = ref(null)
const loading = ref(true)
const accountBalance = computed(() => financesData.value?.account?.balance || 0)
const transactions = computed(() => financesData.value?.transactions || [])
const operatingCosts = computed(() => financesData.value?.operatingCosts || {})

const sortedTransactions = computed(() => {
  const list = transactions.value
  if (!Array.isArray(list) || !list.length) return []
  return [...list].sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0))
})

const displayTransactions = computed(() => {
  const list = sortedTransactions.value
  if (props.compact && !props.fillHeight) return list.slice(0, 4)
  return list
})

const getTransactionLabel = (tx) => {
  const amount = tx.amount || 0
  if (tx.label) return tx.label
  return amount >= 0 ? "Deposit" : "Withdrawal"
}

const formatTxDate = (timestamp) => {
  if (timestamp == null || timestamp === "") return "—"
  const sec = typeof timestamp === "number" && timestamp > 1e12 ? timestamp / 1000 : Number(timestamp)
  if (!Number.isFinite(sec)) return "—"
  const date = new Date(sec * 1000)
  const now = Date.now()
  const diffMs = now - date.getTime()
  const diffMins = Math.floor(diffMs / 60000)
  const diffHours = Math.floor(diffMs / 3600000)
  const diffDays = Math.floor(diffMs / 86400000)
  if (diffMins < 1) return "Just now"
  if (diffMins < 60) return `${diffMins}m ago`
  if (diffHours < 24) return `${diffHours}h ago`
  if (diffDays < 7) return `${diffDays}d ago`
  return date.toLocaleDateString("en-US", { month: "short", day: "numeric" })
}

const requestFinancesData = async () => {
  if (!sessionStore.businessId || !sessionStore.businessType) return

  loading.value = true
  try {
    await sessionStore.requestFinancesData(sessionStore.businessType, sessionStore.businessId)
  } catch (error) {
    loading.value = false
  }
}

const handleFinancesData = (data) => {
  if (!data || !data.success) {
    loading.value = false
    return
  }
  if (String(data.businessId) !== String(sessionStore.businessId)) return

  financesData.value = data.finances
  loading.value = false
}

const handleAccountUpdate = (data) => {
  if (!data || !sessionStore.businessType || !sessionStore.businessId) return
  const accountId = "business_" + sessionStore.businessType + "_" + sessionStore.businessId
  if (data.accountId === accountId) {
    requestFinancesData()
  }
}

onMounted(() => {
  events.on("businessComputer:onFinancesData", handleFinancesData)
  events.on("bank:onOverhaulAccountUpdate", handleAccountUpdate)
  if (sessionStore.businessId && sessionStore.businessType) {
    requestFinancesData()
  }
})

onUnmounted(() => {
  events.off("businessComputer:onFinancesData", handleFinancesData)
  events.off("bank:onOverhaulAccountUpdate", handleAccountUpdate)
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Finances: balance and every amount in gold; only money going out reads --bad. */
.home-widget {
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
  border-radius: var(--radius-panel);
  background: var(--panel);
}

.widget-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-2);
  padding: 0.8em var(--inset) 0.55em;
  flex-shrink: 0;

  h3 {
    margin: 0;
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }
}

.balance-badge {
  font-size: 1.1em;
  font-weight: 800;
  color: var(--money);
  font-variant-numeric: tabular-nums;

  &.negative {
    color: var(--bad);
  }
}

.widget-content {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
  padding: 0;
}

.loading-state {
  padding: 2em;
  text-align: center;
  color: var(--faint);
  font-weight: 600;
}

.tx-scroll {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

.empty-ledger {
  padding: 2em var(--inset);
  text-align: center;
  color: var(--faint);
  font-size: 0.92em;
  font-weight: 600;
}

.tx-list {
  list-style: none;
  margin: 0;
  padding: 0 var(--inset);
}

.tx-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.75em;
  padding: 0.55em 0.1em 0.45em;
  border-bottom: 1px solid var(--line);

  &:last-child {
    border-bottom: none;
  }
}

.tx-row__info {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}

.tx-row__label {
  font-size: 0.92em;
  font-weight: 600;
  color: #fff;
  line-height: 1.3;
  overflow-wrap: anywhere;
}

.tx-row__date {
  font-size: 0.75em;
  font-weight: 600;
  color: var(--faint);
}

.tx-row__amount {
  flex-shrink: 0;
  font-size: 0.92em;
  font-weight: 700;
  font-variant-numeric: tabular-nums;

  &.credit {
    color: var(--money);
  }

  &.debit {
    color: var(--bad);
  }
}

.finance-summary {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 0.5em;
  padding: 0.65em var(--inset) 0.75em;
  border-top: 1px solid var(--line);
  flex-shrink: 0;
}

.summary-item {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.75em;

  &.single {
    flex: 1;
  }

  .label {
    font-size: 0.78em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: var(--faint);
  }

  .value {
    font-weight: 700;
    color: #fff;
    font-variant-numeric: tabular-nums;

    &.cost {
      color: var(--money);
    }
  }
}

/* racing team: one big gold figure with its caption and a faint note under it */
.summary-item.team-expenses {
  flex-direction: column;
  align-items: flex-start;
  gap: 0.15em;

  .team-expenses__amount {
    order: 1;
    font-size: 1.6em;
    font-weight: 800;
    line-height: 1.1;
  }

  .team-expenses__label {
    order: 0;
  }

  .team-expenses__note {
    order: 2;
    margin-top: 0.35em;
    font-size: 0.8em;
    font-weight: 600;
    color: var(--faint);
    line-height: 1.35;
  }
}

.home-widget--compact {
  min-height: 0;
  height: auto;
  flex-shrink: 0;

  .widget-header {
    padding: 0.42em 0.55em;
  }

  .balance-badge {
    font-size: 0.85em;
  }

  .tx-scroll {
    max-height: 6.5em;
  }

  .tx-list {
    padding: 0 0.55em;
  }

  .tx-row {
    padding: 0.35em 0 0.3em;
  }

  .tx-row__label {
    font-size: 0.8em;
  }

  .tx-row__date,
  .tx-row__amount {
    font-size: 0.75em;
  }

  .finance-summary {
    padding: 0.35em 0.55em;
  }

  .summary-item.team-expenses .team-expenses__amount {
    font-size: 1.05em;
  }

  .summary-item.team-expenses .team-expenses__label {
    font-size: 0.65em;
  }
}

.home-widget--compact.home-widget--fill {
  flex: 1;
  min-height: 0;
  height: auto;
  flex-shrink: 1;

  .tx-scroll {
    max-height: none;
    flex: 1;
    min-height: 0;
    overflow-y: auto;
  }

  .finance-summary {
    padding-bottom: 0.5em;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
