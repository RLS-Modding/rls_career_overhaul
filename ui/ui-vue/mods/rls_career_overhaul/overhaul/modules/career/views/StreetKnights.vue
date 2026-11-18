<template>
  <div class="knights-screen" v-bng-on-ui-nav:back,menu="onNavClose">
    <NegotiationChatWindow
      v-if="s && s.offer?.kind === 'boss' && view === 'boss'"
      bng-ui-scope="streetKnightsBoss"
      scope-id="streetKnightsBoss"
      :opponent-name="s.opponent?.name || 'Boss'"
      :subject-name="'Pink slips: your ' + (s.car?.name || 'car') + ' for theirs'"
      :thumbnail="s.opponent?.thumbnail"
      :meta="bossMeta"
      :market-value="null"
      :patience="talk.maxPatience ? talk.patience / talk.maxPatience : 0"
      :quote="talk.quote"
      :history="talk.history"
      :status="s.offer.probing ? 'thinking' : talk.chatStatus"
      :their-offer="talk.ask || 0"
      :my-offer="talk.lastOffer ?? null"
      :starting-price="talk.startingPrice || 0"
      :has-visible-their-offer="(talk.ask || 0) > 0"
      :step="talk.step || 100"
      :step-sizes="[100, 1000]"
      :busy="busy"
      accept-label="Race for"
      :patience-label="(s.opponent?.name || 'Boss') + '’s patience'"
      :resolved-title="bossResolved.title"
      :resolved-text="bossResolved.text"
      :resolved-amount="bossResolved.amount"
      :resolved-tone="talk.status === 'agreed' ? 'ok' : 'bad'"
      :resolved-action="talk.status === 'agreed' ? 'Review stake' : 'Back to the meet'"
      @send="amount => call('bossOffer', amount, s.offer.revision)"
      @accept="call('acceptBossAsk', s.offer.revision)"
      @walk-away="cancel"
      @close="cancel"
      @resolve="talk.status === 'agreed' ? (view = 'confirm') : cancel()" />
    <div v-else class="rls-house rls-house-card knights">
      <div v-if="!s" class="empty"><p>Loading meet…</p></div>
      <template v-else>
        <header class="mast">
          <div class="mast-copy">
            <span class="kicker">{{ place }} — After hours</span>
            <h1>{{ s.title }}</h1>
          </div>
          <div class="cluster mast-meta">
            <span class="pill" :class="s.open ? 'ok' : 'soft'">{{ s.open ? "Meet open" : "Entries closed" }}</span>
            <span class="hint">{{ time }}</span>
            <strong class="money">{{ cash(s.balance) }}</strong>
            <HouseButton v-if="!s.handover" variant="quiet" compact :icon="icons.xmark" binding="back" aria-label="Close" @click="call('close')" />
          </div>
        </header>

        <nav v-if="!s.race && !s.warning" class="seg bar tabs" aria-label="Sections">
          <button type="button" bng-nav-item :class="{ active: view === 'meet' || view === 'results' }" @click="view = 'meet'">The meet</button>
          <button type="button" bng-nav-item :class="{ active: view === 'ladder' }" @click="view = 'ladder'">Boss ladder</button>
          <button type="button" bng-nav-item :class="{ active: view === 'cash' }" :disabled="!s.canRace" @click="view = 'cash'">Cash races</button>
        </nav>

        <main class="body scroll" v-bng-ui-nav-scroll>
          <p v-if="error || s.error" class="notice bad">{{ error || s.error }}</p>

          <section v-if="s.handover" class="panel stack focus-card" role="alertdialog" aria-label="Give up keys">
            <h2 class="headline">You lost the pink-slip race</h2>
            <p>Result: {{ s.result?.reason }}</p><p>Venue: {{ s.result?.venue }}</p><p>The keys belong to {{ s.handover.name }}. Give up your entered car{{ s.handover.bossCash > 0 ? ' and the ' + cash(s.handover.bossCash) + ' you added' : '' }} to continue.</p>
            <HouseButton variant="primary" :disabled="busy" @click="call('giveUpCar')">Give up keys</HouseButton>
          </section>
          <section v-else-if="s.warning" class="panel stack focus-card" role="alertdialog" aria-label="Forfeit race">
            <span class="kicker">Forfeit warning</span>
            <h2 class="headline">Leave this race?</h2>
            <p class="muted">If you {{ s.warning.label }}, you lose {{ s.warning.stake }}.</p>
            <div class="actions">
              <HouseButton variant="quiet-danger" @click="call('confirmAction')">Forfeit and continue</HouseButton>
              <HouseButton variant="primary" @click="call('cancelAction')">Cancel — keep racing</HouseButton>
            </div>
          </section>

          <section v-else-if="s.race && !s.result" class="panel stack focus-card">
            <span class="kicker">Stake committed</span>
            <h2 class="headline">{{ s.prizePending ? "Win recorded; vehicle transfer pending." : phaseText }}</h2>
            <p class="muted">{{ s.prizePending ? "Your prize claim is saved. Condition capture will retry." : "Stay in control of your car. Wait for green." }}</p>
            <div class="actions">
              <HouseButton v-if="!s.prizePending" variant="quiet-danger" @click="call('abandon')">Abandon race</HouseButton>
              <HouseButton variant="primary" @click="call('close')">Return to driving</HouseButton>
            </div>
          </section>

          <div v-else-if="s.result && view === 'results'" class="split-grid">
            <section class="panel stack result" :class="s.result.outcome">
              <span class="kicker">Result locked</span>
              <h2 class="headline">{{ outcomeTitle }}</h2>
              <p class="muted">Result: {{ s.result.reason }}</p><p class="muted">Venue: {{ s.result.venue }}</p>
              <div class="stats">
                <div class="stat" :class="{ money: s.result.outcome === 'win' }">
                  <span class="stat-key">{{ carStake(s.result.kind) ? "Pink slips" : "Stake" }}</span>
                  <span class="stat-value">{{ resultAmount }}</span>
                </div>
                <div class="stat"><span class="stat-key">Opponent</span><span class="stat-value">{{ s.result.opponent }}</span></div>
              </div>
              <p v-if="carStake(s.result.kind) && s.result.outcome === 'win'" class="hint">{{ s.result.prizeInWorld ? 'No garage has space. Your vehicle is waiting at the race venue.' : 'Vehicle will be delivered to a garage with space.' }} Your prize is uninsured and retains its race damage.</p>
              <p v-if="s.result.progressCredit === 1" class="notice ok">+1 win — {{ s.progress.defeated === 5 ? "Ladder complete — keep racing." : s.progress.wins >= 5 ? "Boss ready." : progressText }}</p>
              <p v-if="!s.car" class="notice warn">You need to arrive in an owned car to race again.</p>
              <div class="actions"><HouseButton variant="primary" @click="view = 'meet'">Continue</HouseButton></div>
            </section>
            <aside class="panel stack">
              <span class="kicker">Your progress</span>
              <strong class="big-stat">{{ progressText }}</strong>
              <p v-if="s.night < s.progress.nextNight" class="hint">Word is spreading. Your next rival arrives next night.</p>
            </aside>
          </div>

          <div v-else-if="s.offer && view === 'confirm'" class="split-grid">
            <section class="panel stack">
              <span class="kicker">Final confirmation</span>
              <h2 class="headline">{{ s.offer.winBackId ? "Win your car back." : carStake(s.offer.kind) ? "Your car for theirs." : "This is the commitment." }}</h2>
              <h3 class="block-title">{{ s.opponent?.name }}</h3>
              <div class="lines">
                <div class="line"><span>You stake</span><strong>{{ carStake(s.offer.kind) ? s.car?.name : cash(s.offer.amount) }}</strong></div>
                <div v-if="s.offer.bossCash > 0" class="line"><span>Plus cash if you lose</span><strong class="negative">{{ cash(s.offer.bossCash) }}</strong></div>
                <div class="line"><span>You can win</span><strong class="money">{{ s.offer.winBackId ? s.offer.vehicleName : carStake(s.offer.kind) ? "Their actual car" : cash(s.offer.amount) + " net" }}</strong></div>
                <div class="line"><span>Venue</span><strong>{{ spot }}</strong></div><div class="line"><span>Distance</span><strong>{{ distance }}</strong></div><div class="line"><span>Start</span><strong>Equal start</strong></div>
                <div v-if="s.offer.kind === 'pink' && !s.offer.winBackId" class="line"><span>Minimum car value</span><strong>{{ cash(s.offer.minimumValue) }}</strong></div>
              </div>
              <p v-if="carStake(s.offer.kind)" class="notice warn">Prize transfers as raced and uninsured. Losing your only car leaves you with no cars.</p>
              <p v-if="s.offer.titleDefense" class="notice warn">Your car and the top spot are at stake. Your five boss victories stay recorded.</p>
              <p v-if="s.offer.winBackId" class="hint">Your current car against your former car. This rematch does not change the boss ladder.</p>
            </section>
            <aside class="panel stack">
              <span class="kicker">Before you commit</span>
              <p class="muted">Confirming puts your stake on the line, including the drive to the start. Break these rules and you lose it:</p>
              <ul class="rules">
                <li>Don’t quit before finishing. Reloading an unresolved committed race counts as a loss.</li>
                <li>Don’t hit your opponent.</li>
                <li>Wait for green. Don’t leave early.</li>
                <li>Stay in your lane.</li>
                <li>No resets, recovery, switching cars, towing or garage travel.</li>
              </ul>
              <p class="hint">Covered vehicle actions warn before forfeiting.</p>
              <div class="actions">
                <HouseButton variant="quiet" @click="cancel">Cancel without loss</HouseButton>
                <HouseButton variant="primary" :disabled="busy" @click="call('commit', s.offer.revision)">{{ carStake(s.offer.kind) ? "Commit my car" : "Commit " + cash(s.offer.amount) }}</HouseButton>
              </div>
            </aside>
          </div>

          <div v-else-if="s.offer && view === 'wager'" class="split-grid">
            <section class="panel stack">
              <span class="kicker">{{ s.opponent?.name }}</span>
              <h2 class="headline">Settle the stake.</h2>
              <p class="quote">{{ offerMessage }}</p>
              <div class="stake-pair">
                <div class="stat money"><span class="stat-key">Your stake</span><span class="stat-value">{{ cash(s.offer.amount) }}</span></div>
                <div class="stat money"><span class="stat-key">Their stake</span><span class="stat-value">{{ cash(s.offer.amount) }}</span></div>
              </div>
              <div class="actions">
                <HouseButton variant="quiet" @click="cancel">Walk away</HouseButton>
                <HouseButton
                  v-if="!s.offer.countered"
                  :disabled="busy || s.offer.amount + 100 > s.offer.cap || s.offer.amount + 100 > s.balance"
                  @click="call('counter', s.offer.amount + 100, s.offer.revision)">Counter +$100 each</HouseButton>
                <HouseButton variant="primary" :disabled="busy || s.offer.status === 'declined' || s.balance < s.offer.amount" @click="accept">
                  {{ s.offer.status === "final" ? "Accept final offer" : "Accept offer" }}
                </HouseButton>
              </div>
            </section>
            <aside class="panel stack">
              <span class="kicker">What’s on the line</span>
              <div class="lines">
                <div class="line"><span>Your net win</span><strong class="money">+{{ cash(s.offer.amount) }}</strong></div>
                <div class="line"><span>Your possible loss</span><strong class="negative">{{ cash(s.offer.amount) }}</strong></div>
                <div class="line"><span>Combined pot</span><strong>{{ cash(s.offer.amount * 2) }}</strong></div>
                <div class="line"><span>Format</span><strong>{{ distance }}</strong></div>
              </div>
              <p class="hint">Nothing is binding until final confirmation. You may walk away without loss.</p>
            </aside>
          </div>

          <section v-else-if="view === 'pink' && s.pinkOffer" class="stack loose">
            <template v-if="s.pinkOffer.opponent && ['available', 'revealed'].includes(s.pinkOffer.state)">
              <div class="split-grid">
                <article class="panel stack">
                  <img class="car-photo" :src="s.pinkOffer.opponent.thumbnail" :alt="s.pinkOffer.opponent.model" />
                  <h2>{{ s.pinkOffer.opponent.name }}</h2>
                  <p>{{ s.pinkOffer.opponent.description }}</p>
                  <strong>Venue: {{ s.pinkOffer.venue.name }}</strong><span>Distance: {{ distanceOf(s.pinkOffer.venue.length) }}</span>
                  <p v-if="s.pinkOffer.titleDefense" class="notice warn">{{ s.pinkOffer.reclaimTitle ? 'Reclaim your spot.' : 'Defend your spot.' }} Race this challenger before entering another Knights race. Walking away does not cost your car or title; the challenge stays available.</p>
                  <p class="hint">{{ s.pinkOffer.titleDefense ? 'The challenger returns at the next meet if you leave.' : `Offer closes at ${s.closeTime}.` }} Minimum entered car value: {{ cash(s.pinkOffer.minimumValue) }}.</p>
                </article>
                <aside class="panel stack">
                  <h2>Choose one clue.</h2>
                  <p>Choose the information you want. The other two will lock. {{ s.pinkOffer.titleDefense ? 'Your stake is only committed at final confirmation.' : 'You can still decline afterward.' }}</p>
                  <p class="hint">Recorded figures are reference tests, not predictions for tonight. No stake is committed by revealing.</p>
                  <div v-for="clue in s.pinkOffer.clues" :key="clue.id" class="panel stack">
                    <HouseButton block :disabled="busy || !!s.pinkOffer.selectedCategoryId" @click="call('revealPinkClue', s.pinkOffer.id, s.pinkOffer.revision, clue.id)">{{ clue.label }}</HouseButton>
                    <p class="hint">{{ clue.context }}</p>
                    <strong v-if="clue.value" aria-live="polite">{{ clue.value }}</strong>
                    <span v-else-if="s.pinkOffer.selectedCategoryId" class="muted">Locked for this offer</span>
                  </div>
                </aside>
              </div>
              <p v-if="!s.canPink && s.pinkReason" class="notice warn">{{ s.pinkReason }}</p>
              <div class="actions">
                <HouseButton v-if="!s.pinkOffer.titleDefense" variant="quiet" :disabled="busy" @click="declinePink">Decline tonight</HouseButton>
                <HouseButton variant="primary" :disabled="busy || !s.canPink || s.pinkOffer.state !== 'revealed'" @click="acceptPink">Review car stake</HouseButton>
              </div>
            </template>
            <p v-else class="notice">{{ pinkStatus }}</p>
            <HouseButton variant="quiet" @click="view = 'meet'">Back to meet</HouseButton>
          </section>

          <section v-else-if="view === 'cash'" class="stack loose">
            <div>
              <span class="kicker">Tier {{ s.progress.tier }} - {{ tierNames[s.progress.tier] }}</span>
              <h2 class="headline">Who’s lining up?</h2>
              <p class="muted">Three challengers. Your car, your choice.</p>
            </div>
            <div class="cards">
              <article v-for="e in s.opponents" :key="e.id" class="car-card">
                <img class="car-photo" :src="e.thumbnail" alt="" />
                <div class="stack car-copy">
                  <h3 class="block-title">{{ e.name }}</h3>

                  <p class="hint">{{ e.description }}</p>
                  <div class="stat money"><span class="stat-key">{{ e.winBackId ? 'Special rematch' : 'Opening stake each' }}</span><span class="stat-value">{{ e.winBackId ? 'Pink Slip' : cash(e.offer.amount) }}</span></div>
                  <HouseButton variant="primary" block :disabled="!s.canRace || busy" @click="select(e.id)">{{ e.winBackId ? 'Win it back' : 'Discuss wager' }}</HouseButton>
                </div>
              </article>
            </div>
            <p v-if="s.reason" class="notice warn">{{ s.reason }}</p>
          </section>

          <section v-else-if="view === 'ladder'" class="stack loose">
            <div>
              <span class="kicker">Five rivals — Five sets of keys</span>
              <h2 class="headline">Earn the keys.</h2>
              <p class="muted">Every boss races for pink slips. Take one down, and word spreads. The next name won’t make the trip until you’ve given them a reason.</p>
            </div>
            <div class="ladder">
              <article v-for="r in s.rivals" :key="r.tier" class="rung" :class="{ current: r.tier === s.progress.tier && !r.defeated }">
                <img v-if="r.thumbnail" class="car-photo" :src="r.thumbnail" alt="" />
                <div v-else class="car-photo mystery">?</div>
                <div class="rung-copy">
                  <strong>{{ r.name }}</strong>
                  <span class="pill" :class="r.defeated ? 'ok' : r.tier === s.progress.tier ? 'accent' : 'soft'">{{ rungText(r) }}</span>
                </div>
              </article>
            </div>
            <div class="split-grid">
              <section class="panel stack">
                <h3 class="block-title">{{ s.boss?.name }}</h3>
                <p v-if="s.boss?.description" class="muted">{{ s.boss.description }}</p>
                <p v-if="s.night < s.progress.nextNight" class="hint">Give it a night for your next rival to hear.</p>
              </section>
              <aside class="panel stack">
                <p class="hint">Wins: {{ Math.min(s.progress.wins || 0, 5) }} / 5</p><p class="hint">Their car: {{ cash(s.bossValue) }}</p><p class="hint">Your car: {{ cash(s.car?.worth) }}{{ s.car?.spend > s.car?.value ? " (what you’ve spent)" : "" }}</p>
                <p v-if="s.bossReason" class="notice warn">{{ s.bossReason }}</p>
                <HouseButton variant="primary" block :disabled="(!s.canBoss && !s.bossTalkOnly) || busy" @click="challenge">Talk to the boss</HouseButton>
              </aside>
            </div>
          </section>

          <div v-else class="split-grid">
            <section class="stack">
              <div class="panel stack meet-hero">
                <img class="car-photo" src="/ui/modules/whatsnew/2.8.0.1/no-prep-knights.jpg" alt="Two cars lined up at the street drag starting lights" />
                <div class="stack meet-hero-copy">
                  <span class="kicker">{{ spot }} meet</span>
                  <strong class="hero-title">Make tonight count.</strong>
                  <span>Put up a stake. Line up. Earn your next challenge.</span>
                </div>
              </div>
              <div class="actions start">
                <HouseButton variant="primary" :disabled="!s.canRace" @click="view = 'cash'">Find a cash race</HouseButton>
                <HouseButton @click="view = 'ladder'">View boss ladder</HouseButton>
                <HouseButton v-if="s.pinkOffer && ['available', 'revealed'].includes(s.pinkOffer.state)" :disabled="busy" @click="inspectPink">{{ s.pinkOffer.titleDefense ? 'Race title challenger' : 'Pink-slip offer' }}</HouseButton>
              </div>
              <p v-if="s.reason" class="notice warn">{{ s.reason }}</p>
              <p v-if="s.progress.defeated >= 1" class="hint">{{ pinkStatus }}</p>
            </section>
            <aside class="panel stack">
              <span class="kicker">{{ s.progress.defeated === 5 ? "Boss ladder complete" : "Your next challenge" }}</span>
              <h3 class="block-title">{{ s.progress.defeated === 5 ? (s.titleHolderName ? 'Reclaim your spot.' : 'Defend your spot.') : s.boss?.name }}</h3>
              <p v-if="s.progress.defeated === 5" class="hint">{{ s.titleHolderName ? s.titleHolderName + ' holds the top spot.' : 'You hold the top spot.' }} Fast challengers can call you out during a meet. Cash races stay available between challenges.</p>
              <strong class="big-stat">{{ progressText }}</strong>
              <template v-if="s.progress.defeated < 5">
              <div class="meter"><span :style="{ width: Math.min(s.progress.wins, 5) * 20 + '%' }"></span></div>
              <p v-if="s.boss?.description" class="muted">{{ s.boss.description }}</p>
              <HouseButton variant="primary" block :disabled="(!s.canBoss && !s.bossTalkOnly) || busy" @click="challenge">Talk to the boss</HouseButton>
              <p class="hint">Wins: {{ Math.min(s.progress.wins || 0, 5) }} / 5</p><p class="hint">Their car: {{ cash(s.bossValue) }}</p><p class="hint">Your car: {{ cash(s.car?.worth) }}{{ s.car?.spend > s.car?.value ? " (what you’ve spent)" : "" }}</p>
              </template>
            </aside>
          </div>
        </main>

        <footer class="strip">
          <span class="strip-place">Venue: <strong>{{ spot }}</strong></span><span v-if="level">Region: {{ level }}</span>
          <span>Format: Heads-up</span><span>Distance: {{ distance }}</span><span v-if="s.venue?.laneWidth">Lane width: {{ s.venue.laneWidth }} m</span><span>First legal finisher wins</span>
          <span class="hint">{{ s.openTime }}–{{ s.closeTime }}</span>
        </footer>
      </template>
    </div>
  </div>
</template>

<script setup>
import { ref, watch, computed, onMounted, onUnmounted } from "vue"
import { icons } from "@/common/components/base"
import { vBngOnUiNav, vBngUiNavScroll } from "@/common/directives"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { useBridge } from "@/bridge"
import { run } from "@/bridge/libs/Lua"
import { HouseButton } from "../components/house/index.js"
import NegotiationChatWindow from "../components/negotiation/NegotiationChatWindow.vue"

const { events } = useBridge()
const s = ref(null), view = ref("meet"), busy = ref(false), error = ref("")
const navBlocker = useUINavBlocker()
watch(() => !!s.value?.handover, active => active ? navBlocker.allowNavigationOnly() : navBlocker.clear())
const cash = n => "$" + Math.round(n || 0).toLocaleString("en-US")
const time = computed(() => String(Math.floor(s.value?.hour || 0)).padStart(2, "0") + ":00")
const carStake = kind => kind === "boss" || kind === "pink"
const distanceOf = m => (Math.abs(m - 201.168) < 1 ? "⅛ mile" : Math.abs(m - 402.336) < 1 ? "¼ mile" : Math.abs(m - 804.672) < 1 ? "½ mile" : Math.round(m) + " m")
const distance = computed(() => distanceOf(s.value?.venue?.length || s.value?.distance || 0))
const spot = computed(() => s.value?.venue?.name || "Street Knights")
const level = computed(() => s.value?.venue?.level || "")
const place = computed(() => level.value || spot.value)
const progressText = computed(() => (s.value?.progress.defeated === 5 ? "5 / 5 bosses" : Math.min(s.value?.progress.wins || 0, 5) + " / 5 wins"))
const outcomeTitle = computed(() => {
  const result = s.value?.result
  if (result?.titleDefense) return result.outcome === 'win' ? (result.reclaimTitle ? 'Top spot reclaimed.' : 'Title defended.') : result.outcome === 'void' ? 'Challenge called off.' : 'Top spot lost.'
  return ({ win: "You won.", void: "Stake returned." }[result?.outcome] || "You lost.")
})
const phaseText = computed(() => ({ approach: "Drive to the white starting line", prestage: "Roll front wheels onto the white line and stop", staged: "Wait for green", green: "Race in progress", cooldown: "Keep control. Slow down." }[s.value?.race?.phase] || "Race committed"))
const offerMessage = computed(() => ({ opening: "Same start. First across. Your call.", agreed: "You have a deal.", declined: "No deal. I’m keeping my money tonight.", final: "That is my final offer." }[s.value?.offer?.status] || "Terms agreed."))
const resultAmount = computed(() => {
  const r = s.value?.result
  if (!r) return ""
  if (carStake(r.kind)) return r.outcome === "win" ? "Opponent car acquired" : r.outcome === "void" ? "Your car is retained" : r.bossCash > 0 ? "Entered car and " + cash(r.bossCash) + " lost" : "Entered car lost"
  return (r.outcome === "win" ? "+" : r.outcome === "loss" ? "−" : "") + cash(r.amount)
})
// Boss negotiation in the shared chat window; the boss's real price stays in Lua.
const talk = computed(() => s.value?.offer?.negotiation || { history: [], step: 100, maxPatience: 3 })
const bossMeta = computed(() => {
  const t = talk.value, car = s.value?.car
  const counted = car && car.spend > car.value ? `spent ${cash(car.spend)}` : "market value"
  return [{ icon: icons.car, text: `Your car ${cash(t.carValue)} (${counted})` }, { text: `Their car ${cash(t.bossValue)}` }]
})
const bossResolved = computed(() => {
  const t = talk.value, name = s.value?.opponent?.name || "The boss"
  if (t.status === "agreed") return t.cash > 0
    ? { title: "Pink slips are on.", text: "Lose and you also pay", amount: t.cash }
    : { title: "Pink slips are on.", text: "Keys for keys. No cash on top.", amount: null }
  if (t.status === "walked") return { title: "No race tonight.", text: `${name} walked away. Come back next meet.`, amount: null }
  return { title: "Not worth their time.", text: "Bring a car worth at least", amount: s.value?.minimumValue || 0 }
})
const tierNames = { 1: "Street", 2: "Modified", 3: "Super Street", 4: "Pro", 5: "Elite" }
const rungText = r => (r.defeated ? "Keys claimed" : r.tier === s.value.progress.tier ? `${Math.min(s.value.progress.wins, 5)} / 5 wins` : "Word hasn’t reached them yet.")

function update(data) {
  const previous = s.value?.result
  s.value = data
  if (data.result && (!previous || previous.reason !== data.result.reason || previous.opponent !== data.result.opponent || previous.outcome !== data.result.outcome)) view.value = "results"
}
function showError(text) { error.value = text }
async function call(method, ...args) {
  if (busy.value) return false
  busy.value = true
  error.value = ""
  try { return await run("overhaul_career_economy_streetKnights." + method, args, {}) }
  catch (e) { error.value = "Request failed. Your committed race remains active."; return false }
  finally { busy.value = false }
}
async function select(id) { if (await call("selectOpponent", id)) view.value = s.value?.offer?.winBackId ? "confirm" : "wager" }
async function accept() { if (await call("acceptOffer", s.value.offer.revision)) view.value = "confirm" }
async function challenge() { if (await call("challengeBoss")) view.value = "boss" }
async function inspectPink() { if (await call("inspectPinkOffer", s.value.pinkOffer.id)) view.value = "pink" }
async function acceptPink() { if (await call("acceptPinkOffer", s.value.pinkOffer.id, s.value.pinkOffer.revision)) view.value = "confirm" }
async function declinePink() { if (await call("declinePinkOffer", s.value.pinkOffer.id, s.value.pinkOffer.revision)) view.value = "meet" }
async function cancel() { const offer = s.value?.offer; await call("cancelOffer"); view.value = offer?.winBackId ? "cash" : offer?.kind === "pink" ? "pink" : "meet" }
const pinkStatus = computed(() => {
  const state = s.value, offer = state?.pinkOffer
  if (offer?.reason) return offer.reason
  if (state?.progress?.defeated === 5) {
    if (offer?.titleDefense && ['available', 'revealed'].includes(offer.state)) return 'Your title challenger is waiting. Race them before entering another Knights race.'
    if (offer?.state === 'committed') return 'Title race committed.'
    return 'Cash races are available between title challenges. Your five boss victories stay recorded.'
  }
  return ({available:"A pink-slip challenger is waiting.",revealed:"Your revealed pink-slip offer is still available.",declined:"Pink-slip offer declined for tonight.",expired:"Tonight's pink-slip offer expired.",committed:"Pink-slip stake committed.",settled:"Tonight's pink-slip race is complete.",invalidated:"Build changed; offer withdrawn."}[offer?.state] || "No pink-slip offer tonight. One chance per scheduled meet; cash races do not refresh it.")
})
const onNavClose = event => {
  event?.stopPropagation?.()
  if (s.value?.handover) return
  if (view.value === "boss") cancel()
  else if (s.value?.warning) call("cancelAction")
  else call("close")
}
onMounted(() => { events.on("StreetKnightsState", update); events.on("StreetKnightsError", showError); call("requestState") })
onUnmounted(() => {
  navBlocker.clear(); events.off("StreetKnightsState", update); events.off("StreetKnightsError", showError)
  // Direct run, not call(): call()'s busy guard would drop this if a request is still in flight.
  run("overhaul_career_economy_streetKnights.screenClosed", [], {}).catch(() => {})
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.knights-screen {
  width: 100%;
  height: 100%;
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2em;
  background: rgba(0, 0, 0, 0.35);
}
.knights {
  display: flex;
  flex-direction: column;
  width: min(80em, 96vw);
  max-height: 92vh;
  overflow: hidden;
  border-radius: var(--radius-control);
  background: rgba(21, 21, 23, 0.96);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
  color: #fff;
}
.mast {
  flex: 0 0 auto;
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: var(--space-4);
  padding: 1.2em 1.4em 0.9em;
  border-bottom: 1px solid var(--line);
}
.mast h1 {
  margin: 0.1em 0 0;
  font-size: 2em;
  font-weight: 800;
  font-style: italic;
  letter-spacing: -0.02em;
  line-height: 1;
  text-transform: uppercase;
}
.mast-meta { gap: var(--space-3); }
.tabs { flex: 0 0 auto; margin: var(--space-3) 1.4em 0; }
.body {
  flex: 1 1 auto;
  min-height: 0;
  overflow: auto;
  display: grid;
  align-content: start;
  gap: var(--space-4);
  padding: 1.1em 1.4em 1.3em;
}
.headline {
  margin: 0;
  font-size: 2em;
  font-weight: 800;
  letter-spacing: -0.02em;
  line-height: 1.05;
}
.big-stat {
  font-size: 1.8em;
  font-weight: 800;
  color: var(--accent-soft);
  font-variant-numeric: tabular-nums;
}
.quote { margin: 0; font-size: 1.25em; font-style: italic; color: var(--muted); }
.split-grid {
  display: grid;
  grid-template-columns: minmax(0, 1.4fr) minmax(16em, 1fr);
  gap: var(--space-4);
  align-items: start;
}
.focus-card { width: min(36em, 100%); justify-self: center; }
.result.win { box-shadow: inset 3px 0 0 var(--ok); }
.result.loss { box-shadow: inset 3px 0 0 var(--bad); }
.stake-pair {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-2);
  .stat { padding: 0.8em; border-radius: var(--radius-panel); background: var(--panel); text-align: center; }
}
.rules {
  margin: 0;
  padding-left: 1.2em;
  display: grid;
  gap: 0.25em;
  color: var(--muted);
  font-weight: 600;
}
.actions.start { justify-content: flex-start; }
.cards {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: var(--space-4);
}
.car-card {
  overflow: hidden;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.car-copy { padding: var(--inset); }
.car-photo {
  display: block;
  width: 100%;
  aspect-ratio: 16 / 9;
  object-fit: cover;
  background: var(--photo);
}
.mystery {
  display: grid;
  place-items: center;
  font-size: 3em;
  font-weight: 800;
  color: var(--faint);
  background: linear-gradient(120deg, rgba(255, 255, 255, 0.08), rgba(0, 0, 0, 0.4));
}
.ladder {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: var(--space-3);
}
.rung {
  overflow: hidden;
  border-radius: var(--radius-panel);
  background: var(--panel);
  &.current { box-shadow: inset 0 0 0 2px var(--accent); }
}
.rung-copy {
  display: grid;
  gap: var(--space-1);
  padding: 0.65em 0.75em 0.75em;
  strong { font-size: 1.02em; }
  .pill { justify-self: start; }
}
.meet-hero { padding: 0; gap: 0; overflow: hidden; }
.meet-hero-copy { padding: var(--inset); }
.hero-title { font-size: 2em !important; font-weight: 800; }
.strip {
  flex: 0 0 auto;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--space-2) 1.4em;
  padding: 0.75em 1.4em;
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 0.85em;
  font-weight: 600;
  .hint { margin-left: auto; }
}
.strip-place strong { color: #fff; }

@media (max-width: 1000px) {
  .split-grid { grid-template-columns: minmax(0, 1fr); }
  .ladder { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}
@media (max-width: 700px) {
  .cards, .ladder { grid-template-columns: minmax(0, 1fr); }
  .mast { flex-wrap: wrap; }
}
</style>
