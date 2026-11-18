<template>
  <div class="knights-club rls-house rls-house-phone">
    <div v-if="!state" class="card muted">Loading…</div>

    <template v-else-if="!state.member">
      <section class="card hero">
        <small>STREET DRAG CLUB</small>
        <h1>No Prep Knights</h1>
        <p>Members only. Join from Car Meet → Clubs to get the location each night.</p>
      </section>
      <button class="action" @click="goBack">Back to Car Meet</button>
    </template>

      <template v-else>
        <section class="card hero">
          <small>STREET DRAG CLUB</small>
          <h1>No Prep Knights</h1>
          <p class="status" :class="{ live: state.open }">{{ state.open ? "Meet is live" : "Quiet for now" }}</p><p>Time: {{ clock(state.hour) }}</p>
        </section>

        <section class="card">
          <small>{{ state.open ? "TONIGHT'S SPOT" : "NEXT MEET" }}</small>
          <h2>{{ state.spot || "No spot announced" }}</h2>
          <p v-if="state.racing">Race in progress.</p>
          <p v-else>{{ state.open ? `Lights are on until ${state.closeTime}.` : `Lights at ${state.openTime}.` }}</p>
          <button class="action" :disabled="!state.spot || routed" @click="setRoute">{{ routed ? "Route set" : "Set route" }}</button>
        </section>

        <section v-if="state.progress?.defeated >= 1" class="card panel stack">
          <h2>{{ state.progress.defeated === 5 ? 'Top spot' : 'Pink-slip offers' }}</h2>
          <p v-if="state.progress.defeated === 5">{{ state.titleHolderName ? state.titleHolderName + ' holds the top spot. Beat them to reclaim it.' : 'You hold the top spot. Expect title challenges during the meet.' }}</p>
          <p v-if="state.pinkOffer && ['available', 'revealed'].includes(state.pinkOffer.state)">{{ state.pinkOffer.opponent.name }} {{ state.pinkOffer.titleDefense ? 'is your title challenger. Other Knights races wait until you race them.' : 'has an offer. Visit the signup spot to choose one clue and decide.' }}</p>
          <p v-else>{{ state.pinkOffer?.reason || (state.progress.defeated === 5 ? 'Cash races are available between title challenges. Visit the meet to face the next challenger.' : 'One chance per scheduled meet. Cash races and reopening the app do not refresh offers.') }}</p>
          <HouseButton :disabled="!state.spot || routed" @click="setRoute">{{ routed ? 'Route set' : 'Route to meet' }}</HouseButton>
        </section>

        <section v-if="state.last" class="card result" :class="state.last.outcome">
          <small>LAST RACE</small><p v-if="state.last.spot">Venue: {{ state.last.spot }}</p>
          <h2>{{ outcomeTitle }}</h2>
          <p class="quote">“{{ state.last.line }}”</p>
          <div class="row"><span>Opponent</span><strong>{{ state.last.opponent }}</strong></div>
          <div class="row"><span>Result</span><strong>{{ state.last.reason }}</strong></div>
          <div class="row"><span>{{ ["boss", "pink"].includes(state.last.kind) ? "Stake" : "Money" }}</span><strong>{{ moneyText }}</strong></div>
        </section>

        <section class="card">
          <small>BOSS LADDER</small>
          <div v-for="r in rivals" :key="r.tier" class="rung" :class="{ current: r.tier === state.progress.tier && !r.defeated, done: r.defeated }">
            <em>{{ r.tier }}</em>
            <span>{{ r.name }}</span>
            <strong>{{ rungText(r) }}</strong>
          </div>
          <p v-if="!state.nextRivalReady" class="muted">Word is spreading. Your next rival arrives next night.</p>
        </section>
      </template>
    </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from "vue"
import { HouseButton } from "../components/house/index.js"
import { lua } from "@/bridge"
import { run } from "@/bridge/libs/Lua"
import { usePhoneScreen } from "../composables/usePhoneScreen"

usePhoneScreen({ title: "No Prep Knights", onBack: goBack })

const state = ref(null)
const routed = ref(false)
let timer = null

const asArray = value => (Array.isArray(value) ? value : value && typeof value === "object" ? Object.values(value) : [])
const cash = n => "$" + Math.round(Number(n || 0)).toLocaleString("en-US")
const clock = hour => {
  const minutes = Math.floor((Number(hour || 0) % 24) * 60)
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`
}

const rivals = computed(() => asArray(state.value?.rivals))
const outcomeTitle = computed(() => ({ win: "You won", loss: "You lost", void: "Stake returned" })[state.value?.last?.outcome] || "Race over")
const moneyText = computed(() => {
  const last = state.value?.last
  if (!last) return ""
  if (["boss", "pink"].includes(last.kind)) return last.outcome === "win" ? "Their car" : last.outcome === "loss" ? "Your car" : "Car kept"
  return last.outcome === "win" ? `+${cash(last.amount)}` : last.outcome === "loss" ? `−${cash(last.amount)}` : `${cash(last.amount)} returned`
})

function rungText(r) {
  if (r.defeated) return "Keys claimed"
  if (r.tier === state.value.progress.tier) return `${Math.min(state.value.progress.wins, 5)} / 5 wins`
  return "Locked"
}

async function refresh() {
  state.value = await run("overhaul_career_economy_streetKnights.getClubState", [], {})
}

async function setRoute() {
  routed.value = !!(await run("overhaul_career_economy_streetKnights.routeToMeet", [], {}))
}

async function goBack() {
  await lua.extensions.ui_router.navigate("car-meets-phone")
  return true
}

onMounted(() => {
  refresh()
  timer = setInterval(refresh, 5000)
})
onUnmounted(() => clearInterval(timer))
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;
.knights-club {
  height: 100%;
  overflow-y: auto;
  padding: calc(2.45rem + env(safe-area-inset-top, 0px)) 0.58rem 0.8rem;
  display: flex;
  flex-direction: column;
  gap: 0.55rem;
  background: linear-gradient(180deg, #101318 0%, #171e28 100%);
  color: #f1f3f5;
}

.card {
  padding: 0.7rem;
  border: 1px solid #46515e;
  border-radius: 0.5rem;
  background: #232b36;
}

.hero {
  border-left: 3px solid #ff853c;
}

small {
  color: #ff853c;
  font-size: 0.5rem;
  font-weight: 800;
  letter-spacing: 0.1em;
}

h1 {
  margin: 0.2rem 0;
  font-size: 1.2rem;
  font-style: italic;
  text-transform: uppercase;
}

h2 {
  margin: 0.2rem 0;
  font-size: 0.95rem;
}

p {
  margin: 0.3rem 0;
  font-size: 0.62rem;
  color: #c7ced8;
}

.status.live {
  color: #8fe388;
}

.quote {
  font-style: italic;
  color: #f1f3f5;
}

.muted {
  color: #93a0ad;
}

.action {
  width: 100%;
  margin-top: 0.4rem;
  padding: 0.42rem;
  border: 1px solid #ff853c;
  border-radius: 0.35rem;
  background: #ff853c;
  color: #191613;
  font-size: 0.65rem;
  font-weight: 800;
  cursor: pointer;
}

.action:disabled {
  opacity: 0.45;
  cursor: default;
}

.result.win {
  border-left: 3px solid #8fe388;
}

.result.loss {
  border-left: 3px solid #e3786b;
}

.row {
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0.25rem 0;
  border-top: 1px solid #39434f;
  font-size: 0.6rem;

  span {
    color: #93a0ad;
  }
}

.rung {
  display: grid;
  grid-template-columns: 1.1rem minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.4rem;
  padding: 0.35rem 0;
  border-top: 1px solid #39434f;
  font-size: 0.62rem;

  em {
    font-style: normal;
    font-weight: 800;
    color: #93a0ad;
  }

  strong {
    font-size: 0.55rem;
    color: #93a0ad;
  }

  &.current {
    em,
    strong {
      color: #ff853c;
    }
  }

  &.done strong {
    color: #8fe388;
  }
}
</style>
