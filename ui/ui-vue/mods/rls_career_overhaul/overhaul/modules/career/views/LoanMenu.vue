<template>
  <ComputerWrapper :path="[computerStore.computerData.facilityName]" title="Loans" back @back="close">
    <!-- Controller: the screen's own scope is active on entry so the d-pad works at once (the
             computer's root scope otherwise waits for an A press); B leaves the screen. -->
    <div class="rls-house loan-menu" v-bng-scoped-nav="loansScope">
      <!-- left: take a new loan -->
      <section class="col new-loan">
        <span class="caption">New loan</span>

        <div v-if="offers.length" class="lenders">
          <button
            v-for="o in offers"
            :key="o.id"
            type="button"
            class="lender"
            bng-nav-item
            :bng-scoped-nav-autofocus="selectedOrgId === o.id ? '' : null"
            :class="{ picked: selectedOrgId === o.id }"
            @click="selectOffer(o.id)"
          >
            <strong class="lender-name">{{ o.name }}</strong>
            <span class="lender-meta">
              <span class="lender-rate">{{ (o.rate * 100).toFixed(0) }}%</span>
              <span class="lender-max">up to <BngUnit :money="o.max" /></span>
            </span>
          </button>
        </div>
        <p v-else class="notice">No lenders will offer you a loan right now.</p>

        <template v-if="selectedOffer">
          <div class="block">
            <div class="block-head">
              <span class="caption">Amount</span>
              <span class="hint">Max <BngUnit :money="selectedOffer.max" /></span>
            </div>
            <label class="amount-field" data-focus-field>
              <BngIcon :type="icons.beamCurrency" class="amount-glyph" />
              <input
                class="amount-input"
                type="number"
                :min="0"
                :step="500"
                inputmode="numeric"
                v-bng-text-input
                v-model.number="amount"
                @keydown.stop
                @keypress.stop
                @keyup.stop
                @focus="pauseTicks = true"
                @blur="onAmountBlur"
                @input="onAmountInput"
              />
            </label>
            <!-- d-pad / left stick left-right step the amount by 500 (hold to speed up): a native
                             range ignores the pad, so this is the typing-free way in -->
            <input
              class="slider"
              type="range"
              min="0"
              :max="selectedOffer.max"
              step="500"
              :style="{ '--fill': amountFill + '%' }"
              aria-label="Loan amount"
              bng-nav-item
              v-bng-on-ui-nav-focus.repeat="amountNav"
              v-model.number="amount"
              @input="onAmountSlide"
            />
            <div class="chips amount-chips" role="group" aria-label="Quick amount">
              <button
                v-for="q in amountQuick"
                :key="q.id"
                type="button"
                bng-nav-item
                :class="{ active: amount === q.value }"
                @click="setAmount(q.value)"
              >
                {{ q.label }}
              </button>
            </div>
          </div>

          <div class="block">
            <span class="caption">Term</span>
            <div class="seg bar terms" role="group" aria-label="Loan term">
              <button
                v-for="t in selectedOffer.terms"
                :key="t"
                type="button"
                bng-nav-item
                :class="{ active: term === t }"
                @click="setTerm(t)"
              >
                {{ formatTermDuration(t) }}
              </button>
            </div>
          </div>

          <div class="facts quote">
            <div class="fact"
              ><span class="fact-key">Rate</span><span class="fact-value">{{ adjustedRateDisplay }}</span></div
            >
            <div class="fact money"
              ><span class="fact-key">Per payment</span><span class="fact-value"><BngUnit :money="perPayment" /></span
            ></div>
            <div class="fact money"
              ><span class="fact-key">Total repay</span><span class="fact-value"><BngUnit :money="totalRepay" /></span
            ></div>
          </div>

          <p v-if="loanError" class="notice bad"><template v-if="loanErrorMax != null">Amount must be between 1 and <MoneyAmount>{{ moneyText(units, loanErrorMax) }}</MoneyAmount></template><template v-else>{{ loanError }}</template></p>
          <HouseButton
            class="take-loan"
            variant="primary"
            block
            :disabled="!canTakeLoan || takingLoan"
            @click="takeLoan"
          >
            Take loan
          </HouseButton>
        </template>
      </section>

      <!-- right: what you owe -->
      <section class="col owed scroll" v-bng-ui-nav-scroll.force>
        <template v-if="activeMortgages.length > 0">
          <span class="caption">Mortgages</span>
          <div v-for="m in activeMortgages" :key="m.garageId" class="debt">
            <div class="debt-head">
              <strong>{{ m.garageName }}</strong>
              <span class="pill">{{ m.remainingPayments }} payments left</span>
            </div>
            <div class="progress">
              <div class="bar"><span :style="{ width: paidPct(m.principal, m.remainingBalance) + '%' }"></span></div>
              <div class="legend"
                ><span
                  ><b><BngUnit :money="m.remainingBalance" /></b> of <BngUnit :money="m.principal" /> left</span
                ></div
              >
            </div>
            <div class="facts">
              <div class="fact money"
                ><span class="fact-key">Per payment</span
                ><span class="fact-value"><BngUnit :money="m.monthlyPayment" /></span
              ></div>
              <div class="fact" v-if="m.secondsUntilNextPayment != null"
                ><span class="fact-key">Next due</span
                ><span class="fact-value">{{ formatDue(m.secondsUntilNextPayment) }}</span></div
              >
              <div class="fact"
                ><span class="fact-key">Rate</span
                ><span class="fact-value"
                  >{{ ((m.interestRate || 0) * 100).toFixed(1).replace(/\.0$/, "") }}%</span
                ></div
              >
              <div class="fact bad" v-if="m.missedPayments > 0"
                ><span class="fact-key">Missed</span><span class="fact-value">{{ m.missedPayments }}</span></div
              >
            </div>
          </div>
        </template>

        <span class="caption">Active loans</span>
        <p v-if="activeLoans.length === 0" class="hint none">No active loans.</p>
        <div v-for="l in activeLoans" :key="l.id" class="debt">
          <div class="debt-head">
            <strong>{{ l.orgName || l.orgId }}</strong>
            <span class="pill">{{ l.paymentsRemaining }} payments left</span>
          </div>
          <div class="progress">
            <div class="bar"><span :style="{ width: paidPct(l.principal, l.principalOutstanding) + '%' }"></span></div>
            <div class="legend"
              ><span
                ><b><BngUnit :money="l.principalOutstanding" /></b> of <BngUnit :money="l.principal" /> left</span
              ></div
            >
          </div>
          <div class="facts">
            <div class="fact money"
              ><span class="fact-key">Next payment</span
              ><span class="fact-value"
                ><BngUnit :money="l.nextPaymentDue === 0 || l.nextPaymentDue ? l.nextPaymentDue : l.perPayment" /></span
            ></div>
            <div class="fact"
              ><span class="fact-key">Next due</span
              ><span class="fact-value">{{ formatDue(l.secondsUntilNextPayment) }}</span></div
            >
            <div class="fact"
              ><span class="fact-key">Rate</span
              ><span class="fact-value"
                >{{ (((l.currentRate ?? l.rate) || 0) * 100).toFixed(1).replace(/\.0$/, "") }}%</span
              ></div
            >
            <div class="fact"
              ><span class="fact-key">Interest left</span
              ><span class="fact-value"><BngUnit :money="l.interestRemaining" /></span
            ></div>
          </div>
          <div class="prepay">
            <label class="amount-field small" data-focus-field>
              <BngIcon :type="icons.beamCurrency" class="amount-glyph" />
              <input
                class="amount-input"
                type="number"
                :min="0"
                :max="
                  Math.min(
                    availableFunds,
                    (l.principalOutstanding || 0) +
                      (l.nextPaymentInterest === 0 || l.nextPaymentInterest
                        ? l.nextPaymentInterest
                        : Math.max(0, l.perPayment - (l.basePayment || 0))),
                  )
                "
                step="100"
                inputmode="numeric"
                placeholder="Prepay amount"
                v-bng-text-input
                v-model.number="prepayAmounts[l.id]"
                @keydown.stop
                @keypress.stop
                @keyup.stop
                @focus="pauseTicks = true"
                @blur="onAmountBlur"
              />
            </label>
            <!-- typing-free prepay: a share of the most you can pay off now -->
            <HouseButton compact variant="quiet" @click="setPayShare(l, 0.25)">25%</HouseButton>
            <HouseButton compact variant="quiet" @click="setPayShare(l, 0.5)">50%</HouseButton>
            <HouseButton compact variant="quiet" @click="setPayMax(l)">Max</HouseButton>
            <HouseButton compact :disabled="!(prepayAmounts[l.id] > 0) || prepaying" @click="prepay(l.id)"
              >Prepay</HouseButton
            >
          </div>
        </div>
      </section>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import MoneyAmount from "../components/MoneyAmount.vue";
import { reportUiFailure } from "../utils/safeLua"

import { ref, computed, onMounted, onBeforeUnmount } from "vue";
import { BngUnit, BngIcon, icons } from "@/common/components/base";
import { HouseButton } from "../components/house/index.js";
import { vBngTextInput, vBngScopedNav, vBngOnUiNavFocus, vBngUiNavScroll } from "@/common/directives";
import ComputerWrapper from "./ComputerWrapper.vue";
import { useComputerStore } from "../stores/computerStore";
import { lua, useBridge } from "@/bridge";
import { installLuaBridgeFallbacks } from "../utils/installLuaBridgeFallbacks";
import { moneyText } from "../utils/units";

installLuaBridgeFallbacks();

const computerStore = useComputerStore();
const { events, units } = useBridge();

const offers = ref([]);
const selectedOrgId = ref(null);
const selectedOffer = computed(() => offers.value.find((o) => o.id === selectedOrgId.value));
const amount = ref(0);
const term = ref(null);
const perPayment = ref(0);
const totalRepay = ref(0);
const activeLoans = ref([]);
const activeMortgages = ref([]);
const prepayAmounts = ref({});
const takingLoan = ref(false);
const prepaying = ref(false);
const pauseTicks = ref(false);
const availableFunds = ref(0);
const loanError = ref("");
const loanErrorMax = ref(null);
let loansUpdatedHandler;
let offersTickHandler;
let creditUpdatedHandler;
let loansCompletedHandler;
let loansFundsHandler;

const canTakeLoan = computed(() => selectedOffer.value && amount.value > 0 && term.value);

const formatCurrency = (v) => moneyText(units, Math.round(Number(v) || 0), { decimals: 0 });

const formatDue = (secondsUntilNextPayment) => {
  if (secondsUntilNextPayment == null) return "soon";
  const d = Math.max(0, Math.floor(secondsUntilNextPayment));
  const m = Math.floor(d / 60);
  const s = d % 60;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
};

const computePayment = async () => {
  if (!selectedOffer.value || !term.value || amount.value <= 0) {
    perPayment.value = 0;
    totalRepay.value = 0;
    return;
  }
  try {
    const result = await lua.overhaul_career_economy_loans.calculatePayment(
      amount.value,
      adjustedRate.value,
      term.value,
    );
    // calculatePayment returns nothing typed; assume [perPayment, total]? Lua bridge will return array-like or object; handle common cases
    if (Array.isArray(result)) {
      perPayment.value = result[0] || 0;
      totalRepay.value = result[1] || 0;
    } else if (result && typeof result === "object") {
      perPayment.value = result.perPayment || 0;
      totalRepay.value = result.total || result.totalRepay || 0;
    } else {
      // fallback compute in JS
      const total = amount.value * (1 + adjustedRate.value);
      perPayment.value = total / term.value;
      totalRepay.value = total;
    }
  } catch (e) {
    const total = amount.value * (1 + adjustedRate.value);
    perPayment.value = total / term.value;
    totalRepay.value = total;
  }
};

const onOrgChange = () => {
  amount.value = 0;
  term.value = selectedOffer.value?.terms?.[0] || null;
  computePayment();
};

const setTerm = (t) => {
  term.value = t;
  computePayment();
};

const formatTermDuration = (numPayments) => {
  const totalMinutes = numPayments * 10;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  const hm = `${hours > 0 ? hours + "h " : ""}${minutes > 0 ? minutes + "m" : ""}`;
  return `${hm}`;
};

const onAmountSlide = () => computePayment();

// Controller amount entry. The binding object must stay the same between renders (the directive
// restarts its hold-repeat when it changes), so it only rebuilds when the lender's max changes.
const maxLoan = computed(() => Number(selectedOffer.value?.max) || 0);
const amountNav = computed(() => ({
  min: 0,
  max: maxLoan.value,
  step: 500,
  value: () => Number(amount.value) || 0,
  callback: (dir, val) => {
    if (val == null) return;
    amount.value = val;
    computePayment();
  },
}));
const setAmount = (value) => {
  amount.value = Math.min(maxLoan.value, Math.max(0, Math.floor(Number(value) || 0)));
  computePayment();
};
// quick amounts as shares of the lender's max, on the slider's 500 grid (Max is the exact max)
const amountQuick = computed(() => {
  const max = maxLoan.value;
  const share = (f) => Math.floor((max * f) / 500) * 500;
  return [
    { id: "25", label: "25%", value: share(0.25) },
    { id: "50", label: "50%", value: share(0.5) },
    { id: "75", label: "75%", value: share(0.75) },
    { id: "max", label: "Max", value: max },
  ];
});

// The screen's scope: active on entry (focus lands on the picked lender), and B leaves the screen
// instead of only deactivating the scope.
const loansScope = {
  scopeId: "career-loans",
  activateOnMount: true,
  canDeactivate: () => {
    close();
    return false;
  },
};
// Typing: only cap at the offer's max (snapping to 500 on every keystroke turned "1" back into 0).
// Leaving the field settles it to a whole amount; the slider keeps its 500 steps.
const onAmountInput = () => {
  if (!selectedOffer.value) return;
  if (amount.value > selectedOffer.value.max) amount.value = selectedOffer.value.max;
  computePayment();
};
const settleAmount = () => {
  const max = selectedOffer.value ? selectedOffer.value.max : Infinity;
  amount.value = Math.min(max, Math.max(0, Math.floor(Number(amount.value) || 0)));
};
const onAmountBlur = () => {
  pauseTicks.value = false;
  settleAmount();
  computePayment();
};

const selectOffer = (id) => {
  selectedOrgId.value = id;
  onOrgChange();
};

const takeLoan = async () => {
  if (!canTakeLoan.value || takingLoan.value) return;
  takingLoan.value = true;
  loanError.value = "";
  loanErrorMax.value = null;
  try {
    // takeLoan applies economy and credit modifiers; send only the base rate and term surcharge.
    const termMultiplier = 1 + 0.1 * Math.max(0, term.value / 12 - 1);
    const baseRate = (selectedOffer.value.baseRate || 0) * termMultiplier;
    const result = await lua.overhaul_career_economy_loans.takeLoan(
      selectedOrgId.value,
      Math.floor(amount.value),
      term.value,
      baseRate,
      false,
      null,
    );
    if (result && result.error) {
      if (result.error === "invalid_amount") {
        const maxVal = result.max ?? selectedOffer.value?.max ?? 0;
        loanErrorMax.value = maxVal;
        loanError.value = `Amount must be between 1 and ${moneyText(units, maxVal)}`;
      } else if (result.error === "term_not_available") loanError.value = "This term is not available for your credit";
      else if (result.error === "no_offer") loanError.value = "Loan offer no longer available";
      else loanError.value = "Loan failed: " + (result.error || "unknown");
      return;
    }
    await refreshActiveLoans();
    await refreshOffers();
  } catch (e) {
    loanError.value = "Failed to take loan";
  } finally {
    takingLoan.value = false;
  }
};

const syncCurrentOfferLimits = () => {
  if (!selectedOffer.value) {
    amount.value = 0;
    term.value = null;
    computePayment();
    return;
  }
  if (selectedOffer.value.terms && !selectedOffer.value.terms.includes(term.value)) {
    term.value = selectedOffer.value.terms[0] || null;
  }
  if (amount.value > selectedOffer.value.max) {
    amount.value = selectedOffer.value.max;
  }
  computePayment();
};

const refreshActiveLoans = async () => {
  try {
    const loans = await lua.overhaul_career_economy_loans.getActiveLoans();
    activeLoans.value = Array.isArray(loans) ? loans : [];
    // reset prepay inputs for any new/removed loans
    const map = {};
    for (const l of activeLoans.value) map[l.id] = prepayAmounts.value[l.id] || 0;
    prepayAmounts.value = map;
  } catch (e) {
    activeLoans.value = [];
  }
};

const refreshMortgages = async () => {
  try {
    const data = await lua.overhaul_career_garage_property_propertyMortgage.getAllMortgages();
    if (data && typeof data === "object" && !Array.isArray(data)) {
      activeMortgages.value = Object.entries(data).map(([gId, m]) => ({
        garageId: gId,
        garageName: m.garageName || gId,
        monthlyPayment: m.monthlyPayment || 0,
        remainingBalance: m.remainingBalance || 0,
        remainingPayments: m.remainingPayments || 0,
        interestRate: m.interestRate || 0,
        missedPayments: m.missedPayments || 0,
        secondsUntilNextPayment: m.secondsUntilNextPayment || null,
        principal: m.principal || 0,
      }));
    } else {
      activeMortgages.value = [];
    }
  } catch {
    activeMortgages.value = [];
  }
};

const refreshOffers = async () => {
  try {
    const res = await lua.overhaul_career_economy_loans.getLoanOffers();
    const prev = selectedOrgId.value;
    offers.value = Array.isArray(res) ? res : [];
    if (!offers.value.find((o) => o.id === prev)) {
      selectedOrgId.value = offers.value[0]?.id || null;
      onOrgChange();
      return;
    }
    syncCurrentOfferLimits();
  } catch (e) { reportUiFailure(e, "refresh offers (LoanMenu)") }
};

onMounted(async () => {
  await refreshOffers();
  await computePayment();
  await refreshActiveLoans();
  await refreshMortgages();
  // subscribe to live loan events
  loansUpdatedHandler = async () => {
    await refreshActiveLoans();
    await refreshMortgages();
    await refreshOffers();
  };
  offersTickHandler = (data) => {
    if (pauseTicks.value) return;
    if (!Array.isArray(data)) return;
    activeLoans.value = data;
    void refreshOffers();
  };
  loansCompletedHandler = async () => {
    await refreshActiveLoans();
    await refreshOffers();
  };
  creditUpdatedHandler = () => {
    void refreshOffers();
  };
  events.on("loans:activeUpdated", loansUpdatedHandler);
  events.on("loans:tick", offersTickHandler);
  loansFundsHandler = (money) => {
    if (typeof money === "number") availableFunds.value = money;
  };
  events.on("loans:funds", loansFundsHandler);
  events.on("loans:completed", loansCompletedHandler);
  events.on("credit:updated", creditUpdatedHandler);
  // fetch funds initially
  try {
    availableFunds.value = await lua.overhaul_career_economy_loans.getAvailableFunds();
  } catch (error) { reportUiFailure(error, "optional action (LoanMenu)") }
});

onBeforeUnmount(() => {
  if (loansUpdatedHandler) events.off("loans:activeUpdated", loansUpdatedHandler);
  if (offersTickHandler) events.off("loans:tick", offersTickHandler);
  if (loansCompletedHandler) events.off("loans:completed", loansCompletedHandler);
  if (loansFundsHandler) events.off("loans:funds", loansFundsHandler);
  if (creditUpdatedHandler) events.off("credit:updated", creditUpdatedHandler);
});

const close = () => {
  lua.overhaul_career_economy_loans.closeMenu();
};

const adjustedRate = computed(() => {
  if (!selectedOffer.value || !term.value) return selectedOffer.value?.rate || 0;
  const base = selectedOffer.value.rate || 0;
  const step = term.value / 12 - 1;
  const mul = step > 0 ? 1 + 0.1 * step : 1;
  return base * mul;
});

const adjustedRateDisplay = computed(() => (adjustedRate.value * 100).toFixed(1).replace(/\.0$/, "") + "%");

const prepay = async (loanId) => {
  const amount = Math.max(0, Math.floor(prepayAmounts.value[loanId] || 0));
  if (!amount || prepaying.value) return;
  prepaying.value = true;
  try {
    await lua.overhaul_career_economy_loans.prepayLoan(loanId, amount);
    prepayAmounts.value[loanId] = 0;
    await refreshActiveLoans();
    await refreshOffers();
  } catch (e) { reportUiFailure(e, "prepay (LoanMenu)") } finally {
    prepaying.value = false;
  }
};

const onPrepayInput = (e) => {
  const el = e?.target;
  if (!el) return;
  let val = parseInt(el.value || 0, 10);
  if (isNaN(val)) val = 0;
  el.value = String(val);
};

const setPayMax = (loan) => {
  const nextInterest = Math.max(0, loan.nextPaymentInterest ?? Math.max(0, loan.perPayment - (loan.basePayment || 0)));
  const rawMax = (loan.principalOutstanding || 0) + nextInterest;
  const roundedUp = Math.ceil(rawMax + 1e-6);
  const amount = Math.min(availableFunds.value, roundedUp);
  prepayAmounts.value[loan.id] = amount;
};
const setPayShare = (loan, share) => {
  setPayMax(loan);
  prepayAmounts.value[loan.id] = Math.floor((prepayAmounts.value[loan.id] || 0) * share);
};

// slider fill and paid-off bars
const amountFill = computed(() => {
  const max = selectedOffer.value?.max || 0;
  return max > 0 ? Math.min(100, Math.max(0, (amount.value / max) * 100)) : 0;
});
const paidPct = (principal, outstanding) => {
  const p = Number(principal) || 0;
  if (p <= 0) return 0;
  return Math.min(100, Math.max(0, (1 - (Number(outstanding) || 0) / p) * 100));
};
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* House loans. em off a resolution-scaled font so it keeps its share of the screen at 720p..4K. */
.loan-menu {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  width: min(96vw, 72em);
  max-height: 100%;
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 1.1em;
  padding: 1.1em;
  border-radius: var(--radius-control);
  background: rgba(var(--bng-off-black-rgb), 0.9);
  box-shadow:
    0 0 0 1px rgba(255, 255, 255, 0.06),
    0 14px 40px rgba(0, 0, 0, 0.45);
  overflow: hidden;
}
.col {
  display: flex;
  flex-direction: column;
  gap: 0.75em;
  min-width: 0;
  min-height: 0;
}
.owed {
  padding-right: 0.4em;
}
.block {
  display: grid;
  gap: 0.45em;
}
.block-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}

/* ---- lenders: pick one */
.lenders {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.45em;
}
.lender {
  appearance: none;
  display: grid;
  gap: 0.3em;
  margin: 0;
  padding: 0.7em 0.8em 0.6em;
  border: 0;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  font: inherit;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.12s;
  &:hover {
    background: var(--panel-2);
  }
  @include house-focus;
  &.picked {
    background: var(--panel-2);
    .lender-name {
      color: var(--accent-soft);
    }
  }
}
.lender-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 800;
}
.lender-meta {
  display: flex;
  justify-content: space-between;
  gap: 0.6em;
  font-size: 0.85em;
  font-weight: 600;
  color: var(--muted);
}
.lender-rate {
  color: #fff;
  font-weight: 800;
}
.lender-max {
  color: var(--faint);
  :deep(.bng-unit),
  :deep(.unit) {
    color: var(--money);
  }
}

/* ---- amount: big gold editable value over a house slider */
.amount-field {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding: 0.35em 0.7em 0.2em;
  border: 1px solid var(--line);
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.3);
  color: var(--money);
  cursor: text;
  &:focus-within {
    box-shadow: var(--focus);
  }
  .amount-glyph {
    flex: 0 0 auto;
    font-size: 1.4em;
  }
  .amount-input {
    flex: 1 1 auto;
    min-width: 0;
    margin: 0;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--money);
    font: inherit;
    font-size: 1.7em;
    font-weight: 800;
    font-variant-numeric: tabular-nums;
    line-height: 1.2;
    -moz-appearance: textfield;
    &:focus {
      outline: none;
    }
    &::-webkit-inner-spin-button,
    &::-webkit-outer-spin-button {
      -webkit-appearance: none;
      margin: 0;
    }
    &::placeholder {
      color: var(--faint);
      font-weight: 600;
    }
  }
  &.small {
    flex: 1 1 auto;
    padding: 0.2em 0.55em 0.1em;
    .amount-glyph {
      font-size: 1.05em;
    }
    .amount-input {
      font-size: 1em;
    }
  }
}

.terms button {
  font-variant-numeric: tabular-nums;
}
// the amount slider takes controller focus (left/right step it): only its thumb lights up, like every
// house slider (a ring around the whole track read as too much); the game's frame stays hidden
.new-loan .slider {
  position: relative;
  &.focus-visible {
    outline: none;
    box-shadow: none;
  }
  &.focus-visible::before {
    display: none !important;
  }
  &.focus-visible::-webkit-slider-thumb {
    box-shadow:
      0 0 0 0.22em rgba(255, 102, 0, 0.55),
      0 0.05em 0.3em rgba(0, 0, 0, 0.35);
  }
}
.amount-chips > button {
  flex: 1 1 0;
  font-size: 0.9em;
  font-variant-numeric: tabular-nums;
}

.quote {
  padding: 0.8em 0.9em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  .fact-value {
    font-variant-numeric: tabular-nums;
  }
}
.take-loan {
  margin-top: auto;
  min-height: 2.8em;
}

/* ---- what you owe */
.debt {
  display: grid;
  gap: 0.65em;
  padding: 0.85em 0.9em 0.8em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.debt-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 0.8em;
  strong {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-size: 1.1em;
    font-weight: 800;
  }
  .pill {
    flex: 0 0 auto;
    font-variant-numeric: tabular-nums;
  }
}
.progress .legend {
  font-variant-numeric: tabular-nums;
  b :deep(.unit),
  b :deep(.bng-unit) {
    color: #fff;
  }
}
.debt .facts {
  grid-template-columns: repeat(4, minmax(0, 1fr));
  column-gap: 0.8em;
  .fact-value {
    font-size: 0.95em;
    font-variant-numeric: tabular-nums;
  }
}
.prepay {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding-top: 0.6em;
  border-top: 1px solid var(--line);
}
.none {
  padding: 0.4em 0.1em;
}

@media (max-width: 75rem) {
  .loan-menu {
    grid-template-columns: 1fr;
    overflow: auto;
  }
}
</style>
