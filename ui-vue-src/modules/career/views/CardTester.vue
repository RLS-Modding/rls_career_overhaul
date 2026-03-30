<template>
  <div class="card-tester">
    <div class="card-display">
      <PlayingCard ref="cardRef" :rank="rank" :suit="suit" :face-up="faceUp" :theme="cardTheme" />
    </div>

    <div class="controls">
      <div class="control-row">
        <span class="label">Actions</span>
        <div class="buttons">
          <button @click="flipCard">Flip</button>
          <button @click="randomize">Random</button>
        </div>
      </div>

      <div class="control-row">
        <span class="label">Theme</span>
        <div class="buttons">
          <button :class="{ active: cardTheme === 'light' }" @click="cardTheme = 'light'">Light</button>
          <button :class="{ active: cardTheme === 'dark' }" @click="cardTheme = 'dark'">Dark</button>
        </div>
      </div>

      <div class="control-row">
        <span class="label">Sounds</span>
        <div class="buttons">
          <button v-for="s in cardSounds" :key="s.id" @click="playCardSound(s.url)">
            {{ s.label }}
          </button>
        </div>
      </div>

      <div class="control-row">
        <span class="label">Suit</span>
        <div class="buttons">
          <button
            v-for="s in suits" :key="s"
            :class="{ active: suit === s }"
            @click="suit = s"
          >{{ suitLabels[s] }}</button>
        </div>
      </div>

      <div class="control-row">
        <span class="label">Rank</span>
        <div class="buttons">
          <button
            v-for="r in ranks" :key="r"
            :class="{ active: rank === r }"
            @click="rank = r"
          >{{ r }}</button>
        </div>
      </div>

      <div class="info">
        {{ rank }} of {{ suitLabels[suit] }} -- {{ faceUp ? "Face Up" : "Face Down" }}
      </div>
    </div>
  </div>
</template>

<script>
const suits = ["spades", "hearts", "clubs", "diamonds"]
const ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
const suitLabels = { spades: "Spades", hearts: "Hearts", clubs: "Clubs", diamonds: "Diamonds" }

const CARD_SOUNDS_BASE = "/ui/entrypoints/main/cardSounds"
const cardSounds = [
  { id: "flip", label: "Flip", url: `${CARD_SOUNDS_BASE}/Flip.mp3` },
  { id: "shuffle", label: "Shuffle", url: `${CARD_SOUNDS_BASE}/Shuffle.mp3` },
  { id: "deal", label: "Deal", url: `${CARD_SOUNDS_BASE}/Deal.mp3` },
  { id: "place", label: "Place", url: `${CARD_SOUNDS_BASE}/Place.mp3` },
  { id: "hit", label: "Hit", url: `${CARD_SOUNDS_BASE}/Hit.mp3` },
]
</script>

<script setup>
import { ref } from "vue"
import PlayingCard from "../components/playingCards/PlayingCard.vue"

const cardRef = ref(null)
const rank = ref("A")
const suit = ref("spades")
const faceUp = ref(true)
const cardTheme = ref("light")

function flipCard() {
  faceUp.value = !faceUp.value
}

function randomize() {
  rank.value = ranks[Math.floor(Math.random() * ranks.length)]
  suit.value = suits[Math.floor(Math.random() * suits.length)]
  faceUp.value = true
}

function playCardSound(url) {
  try {
    const audio = new Audio(url)
    audio.volume = 0.5
    audio.play()
  } catch (_) {}
}
</script>

<style scoped lang="scss">
.card-tester {
  display: flex;
  align-items: flex-start;
  justify-content: center;
  gap: 2rem;
  padding: 2rem;
  min-height: 100vh;
  background: #1a1a2e;
  color: #eee;
  font-family: sans-serif;
}

.card-display {
  width: 300px;
  flex-shrink: 0;
}

.controls {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding-top: 0.5rem;
}

.control-row {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}

.label {
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  opacity: 0.6;
}

.buttons {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
}

button {
  padding: 0.4rem 0.75rem;
  border: 1px solid rgba(239, 198, 109, 0.4);
  border-radius: 4px;
  background: rgba(255, 255, 255, 0.05);
  color: #efc66d;
  font-size: 0.85rem;
  cursor: pointer;
  transition: background 0.15s, border-color 0.15s;

  &:hover {
    background: rgba(239, 198, 109, 0.15);
  }

  &.active {
    background: rgba(239, 198, 109, 0.25);
    border-color: #efc66d;
  }
}

.info {
  margin-top: 0.5rem;
  font-size: 0.9rem;
  opacity: 0.8;
}
</style>
