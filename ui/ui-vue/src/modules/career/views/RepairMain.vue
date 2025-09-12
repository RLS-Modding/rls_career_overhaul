<template>
  <ComputerWrapper :path="[computerStore.computerData.facilityName]" :title="`Repair ${repairStore.vehicle.niceName}`" back @back="close">
    <BngCard v-if="repairStore.vehicle.niceName" class="repairMain">
      <div class="card-scroll">
        <div class="insurance-vehicle-card" v-if="repairStore.vehicle.thumbnail">
          <img :src="repairStore.vehicle.thumbnail" alt="" />
          <div class="overlay">
            <div class="line">
              <span class="name">{{ repairStore.vehicle.niceName }}</span>
            </div>
            <div class="line">
              <span>Policy:</span>
              <span class="value">{{ repairStore.policyInfo?.name || 'n/a' }}</span>
            </div>
            <div class="line">
              <span>Deductible:</span>
              <span class="value">{{ repairStore.baseDeductible?.money?.amount }} %</span>
            </div>
          </div>
        </div>
        <div>
          <h2 style="padding-left: 1em;">Repair options :</h2>
          <div class="repairOptions" bng-nav-scroll-force>
            <div v-for="(repairOptions, key) in repairStore.repairOptions" :key="key" class="repairOption">
              <h3>{{ repairOptions.repairName }}</h3>
              <div v-if="key !== 'insuranceTotalLoss'">
                <div v-if="repairOptions.repairTime == 0">
                  <p>Repair time : Instant</p>
                </div>

                <div v-else>
                  <p>
                    Repair time :
                    {{
                      (repairOptions.repairTime.toFixed(0) < 60 && repairOptions.repairTime.toFixed(0) + " second(s)") ||
                      (repairOptions.repairTime / 60).toFixed(0) + " minute(s)"
                    }}
                  </p>
                </div>
              </div>

              <div v-if="repairOptions.isPolicyRepair">
                <p v-if="repairStore.policyInfo.hasFreeRepair">Repairing won't raise your policy score. You have an accident forgiveness</p>
                <p v-else-if="key === 'insuranceTotalLoss'">Totaling your vehicle will raise your policy score by {{ repairStore.policyScoreInfluence }} %</p>
                <p v-else>Repairing will raise your policy score by {{ repairStore.policyScoreInfluence }} %</p>
              </div>
              <div v-else>Repairing on your own won't raise your policy score and will not be counted as a claim</div>

              <h4>Payment options :</h4>
              <div v-for="(option, t) in repairOptions.priceOptions" :key="t">
                <div class="priceOption">
                  <div>
                    <div v-for="(price, l) in option.prices" :key="l">
                      <div v-if="price.price.money">
                        <div class="career-status-value">
                          <BngUnit :money="(key === 'insuranceTotalLoss' && price.price.money.amount < 0) ? Math.abs(price.price.money.amount) : price.price.money.amount" />
                          {{ key === 'insuranceTotalLoss' ? 'Payout' : price.text }}
                        </div>
                      </div>
                      <div v-else-if="price.price.vouchers">
                        <div class="career-status-value">
                          <BngUnit :vouchers="price.price.vouchers.amount" /> Vouchers{{ price.price.vouchers.amount != 1 ? "s" : " " }}
                        </div>
                      </div>
                    </div>
                  </div>

                  <BngButton
                    show-hold
                    v-bng-focus-if="key === 'quickRepair' && t == 0"
                    :disabled="!option.canPay"
                    v-bng-on-ui-nav:ok.asMouse.focusRequired
                    v-bng-click="{
                      holdCallback: () => startRepair(key, t),
                      holdDelay: 1000,
                      repeatInterval: 0,
                    }">
                    {{ option.canPay ? getOptionActionLabel(key, option) : "Can't pay" }}
                  </BngButton>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </BngCard>
  </ComputerWrapper>
</template>

<script setup>
import { lua } from "@/bridge"
import { BngButton, BngCard } from "@/common/components/base"
import ComputerWrapper from "./ComputerWrapper.vue"
import { useRepairStore } from "../stores/repairStore"
import { onMounted, onUnmounted } from "vue"
import { BngUnit } from "@/common/components/base"
import { useComputerStore } from "../stores/computerStore"
import { vBngOnUiNav, vBngClick,vBngFocusIf } from "@/common/directives"

const computerStore = useComputerStore()

const repairStore = useRepairStore()

const close = () => {
  lua.career_modules_insurance.closeMenu()
}

const startRepair = (repairOptionName, repairPriceOption) => {
  lua.career_modules_insurance.startRepairInGarage(repairStore.vehicle, { name: repairOptionName, priceOption: repairPriceOption + 1 })
}

const start = () => {
  repairStore.getRepairData()
}
const kill = () => {
  repairStore.$dispose()
}

// Show a clearer action label when the option represents a payout (negative money)
const getOptionActionLabel = (key, option) => {
  try {
    if (key === 'insuranceTotalLoss') return 'Sell'
    for (const p of option.prices || []) {
      const money = p?.price?.money?.amount
      if (typeof money === 'number' && money < 0) return 'Collect'
    }
  } catch (e) {}
  return 'Pay'
}
onMounted(start)
onUnmounted(kill)
</script>

<style scoped lang="scss">
.icon {
  width: 1em;
  height: 1em;
}

.repairOptions {
  height: 100%;
}

.priceOption {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 5px;
  margin: 2.5% 0px;
}

/* FIXME: There is a CSS conflict with AngularJS CSS with this class name */
.career-status-value {
  display: flex;
  justify-content: left;
  flex-flow: row nowrap;
  align-items: baseline;
  & > :first-child {
    margin-right: 0.125em;
  }
}

.veh-part-caption {
  display: flex;
  flex-flow: row nowrap;
  justify-content: stretch;
  align-items: center;
  overflow: hidden;
  width: 100%;
  height: 5em;
  $preview: 10em; // thumbnail width
  .veh-preview {
    width: $preview;
    align-self: stretch;
    background-size: auto 110%;
    background-position: 50% 50%;
    background-repeat: no-repeat;
  }
}

.repairMain {
  width: 60%;
  height: 97.5%;
  color: white;
  overflow: hidden;
  background-color: rgba(0, 0, 0, 0.8);
  & :deep(.card-cnt) {
    background-color: rgba(0, 0, 0, 0);
    display: block;
    height: 100%;
  }
}

.card-scroll {
  height: 100%;
  overflow-y: auto;
  overflow-x: hidden;
}

.insurance-vehicle-card {
  position: relative;
  width: 95%;
  height: 16em;
  margin: 2.5%;
  border-radius: var(--bng-corners-2);
  overflow: hidden;
  background: #000;
  img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }
  .overlay {
    position: absolute;
    left: 0;
    right: 0;
    bottom: 0;
    padding: 0.5em 0.75em;
    display: flex;
    flex-direction: column;
    gap: 0.25em;
    background: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.65) 40%, rgba(0,0,0,0.85) 100%);
    color: #fff;
    .line {
      display: flex;
      align-items: baseline;
      gap: 0.35em;
    }
    .name {
      font-weight: 700;
      font-size: 1.25em;
    }
    .value {
      margin-left: auto;
    }
  }
}

.repairOptions {
  display: flex;
  flex-direction: column;
  gap: 1em;
  padding: 0 0.5em 0.5em 0.5em;
}

.repairOption {
  position: relative;
  padding: 1em 1.25em;
  background: rgba(40, 40, 40, 0.7);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-left: 4px solid #f60;
  border-radius: var(--bng-corners-2);
  margin: 0;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
}

.repairOption h3 { margin: 0 0 0.25em 0; }

.repairOption h4 {
  margin: 0.75em 0 0.25em 0;
  opacity: 0.9;
}

.repairOption p { margin: 0.1em 0; }

.priceOption {
  background: rgba(0, 0, 0, 0.25);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: var(--bng-corners-2);
  padding: 0.5em 0.75em;
  margin: 0.5em 0;
}
</style>
