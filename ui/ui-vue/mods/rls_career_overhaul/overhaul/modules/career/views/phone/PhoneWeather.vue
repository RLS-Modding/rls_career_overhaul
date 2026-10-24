<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <main class="weather-app" v-bng-ui-nav-scroll.force :class="`weather-app--${state.condition || 'clear'}`">
    <div v-if="!state.ready" class="loading">Loading forecast...</div>

    <template v-else>
      <section v-if="state.externalOverride" class="external-lock">
        <div class="external-lock__flag">!</div>
        <h1>External weather active</h1>
        <p>JayBeam Dynamic Weather is loaded and has priority. RLS weather controls are locked to prevent conflicts.</p>
        <div class="external-lock__status">RLS weather effects paused</div>
      </section>

      <template v-else>
        <div v-if="!state.weatherEnabled" class="weather-off">
          <strong>Dynamic weather is off</strong>
          <p>{{ state.careerActive ? 'The map environment is restored. The day/night cycle is controlled separately.' : 'BeamNG controls the environment. Enable dynamic weather below to use the forecast.' }}</p>
        </div>
        <template v-if="state.weatherEnabled">
        <header class="hero">
          <div>
            <p class="location">{{ state.location }}</p>
            <p class="condition">{{ state.conditionLabel }}</p>
          </div>
          <div class="hero-icon" aria-hidden="true">
            <span class="weather-glyph weather-glyph--hero" :class="weatherIconClass(state.condition)">
              <i class="weather-glyph__sun"></i><i class="weather-glyph__cloud"></i><i class="weather-glyph__rain"></i><i class="weather-glyph__bolt"></i>
            </span>
          </div>
          <div class="temperature">{{ formatTemp(state.temperatureC) }}</div>
          <p class="clock">{{ formatTime(state.minuteOfDay) }}<span v-if="state.missionFrozen">, frozen for event</span></p>
        </header>

        <section class="metrics">
          <div><strong>{{ state.precipitationChance }}%</strong><span>Precipitation</span></div>
          <div><strong>{{ state.humidity }}%</strong><span>Humidity</span></div>
          <div><strong>{{ state.windMph }} mph</strong><span>Wind</span></div>
          <div><strong>{{ state.wetness }}%</strong><span>Road wetness</span></div>
        </section>

        <section class="section">
          <div class="section-title"><span>Hourly</span><span>Surface {{ formatTemp(state.surfaceTemperatureC) }}</span></div>
          <div class="hourly-strip">
            <article v-for="(hour, index) in hourly.slice(0, 5)" :key="index" class="hour-card">
              <span class="hour-time">{{ index === 0 ? 'Now' : formatTime(hour.minute, true) }}</span>
              <span class="hour-icon" aria-hidden="true">
                <span class="weather-glyph weather-glyph--hour" :class="weatherIconClass(hour.condition)">
                  <i class="weather-glyph__sun"></i><i class="weather-glyph__cloud"></i><i class="weather-glyph__rain"></i><i class="weather-glyph__bolt"></i>
                </span>
              </span>
              <strong>{{ formatTemp(hour.temperatureC) }}</strong>
              <small>{{ hour.precipitationChance }}%</small>
            </article>
          </div>
        </section>

        <section class="section daily-section">
          <div class="section-title"><span>Seven-day outlook</span></div>
          <article v-for="(day, index) in daily" :key="day.dayIndex" class="day-row">
            <span class="day-label">{{ dayLabel(index) }}</span>
            <span class="day-icon" aria-hidden="true">
              <span class="weather-glyph weather-glyph--day" :class="weatherIconClass(day.condition)">
                <i class="weather-glyph__sun"></i><i class="weather-glyph__cloud"></i><i class="weather-glyph__rain"></i><i class="weather-glyph__bolt"></i>
              </span>
            </span>
            <span class="day-condition">{{ day.fog ? `${day.label}, AM fog` : day.label }}</span>
            <span class="day-temps"><strong>{{ formatTemp(day.highC) }}</strong> {{ formatTemp(day.lowC) }}</span>
          </article>
        </section>

        </template>
        <section class="settings-card">
          <button class="settings-toggle" type="button" :aria-expanded="settingsOpen" @click="settingsOpen = !settingsOpen">
            <span>Weather settings</span><span class="settings-toggle__chevron" :class="{ 'settings-toggle__chevron--open': settingsOpen }">›</span>
          </button>
          <div v-show="settingsOpen" class="settings-body">
            <div class="setting-row">
              <span><strong>Dynamic weather</strong><small>{{ state.careerActive ? 'Weather effects for this career or Freeroam+ save' : 'Enable weather effects in ordinary Freeroam' }}</small></span>
              <input type="checkbox" :checked="state.settings.dynamicWeather" @change="setSetting('dynamicWeather', $event.target.checked)" />
            </div>
            <div class="setting-row">
              <span><strong>Morning fog</strong><small>Allow scheduled fog on eligible mornings</small></span>
              <input type="checkbox" :checked="state.settings.morningFog" @change="setSetting('morningFog', $event.target.checked)" />
            </div>
            <div class="setting-row">
              <span><strong>Day/night cycle</strong><small>Allow time of day to advance</small></span>
              <input type="checkbox" :checked="state.playCycle" @change="setSetting('playCycle', $event.target.checked)" />
            </div>
            <div class="setting-row">
              <span><strong>Rainy days</strong><small>Allow drizzle, rain, and storms</small></span>
              <input type="checkbox" :checked="state.settings.allowRainyDays" @change="setSetting('allowRainyDays', $event.target.checked)" />
            </div>
            <div class="setting-row">
              <span><strong>Forecast alerts</strong><small>Rain, storm, and fog warnings</small></span>
              <input type="checkbox" :checked="state.settings.forecastNotifications" @change="setSetting('forecastNotifications', $event.target.checked)" />
            </div>
            <div v-if="state.careerActive || state.weatherEnabled" class="setting-row">
              <span><strong>Day length</strong><small>Tap to choose the next duration</small></span>
              <button class="setting-value-button" type="button" @click="cycleDayLength">{{ state.settings.dayLengthMinutes || 60 }} min</button>
            </div>
            <div class="setting-row">
              <span><strong>Temperature</strong><small>Tap to switch display unit</small></span>
              <button class="setting-value-button" type="button" @click="toggleTemperatureUnit">{{ state.globalSettings.temperatureUnit === 'C' ? 'Celsius' : 'Fahrenheit' }}</button>
            </div>
          </div>
        </section>
      </template>
    </template>
  </main>
</template>

<script setup>

import { usePhoneAppFocus } from './controllerLayers.js'
import { vBngUiNavScroll } from '@/common/directives'
import { reportUiFailure } from "../../utils/safeLua"

import { onActivated, onDeactivated, onMounted, onUnmounted, reactive, ref, shallowRef, markRaw } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { acquireScope, releaseScope } from '../../utils/luaScopes'

usePhoneAppFocus()


const events = useEvents()
const settingsOpen = ref(false)
const dayLengths = [30, 45, 60, 90, 120]
const hourly = shallowRef([])
const daily = shallowRef([])
const state = reactive({
  ready: false,
  condition: 'clear',
  conditionLabel: 'Clear',
  minuteOfDay: 720,
  settings: {},
  globalSettings: {},
})

function closeSettings() {
  settingsOpen.value = state.ready && !state.weatherEnabled
}

function applyState(next) {
  if (!next || typeof next !== 'object') return
  const wasReady = state.ready
  const wasEnabled = state.weatherEnabled
  const { hourly: nextHourly, daily: nextDaily, ...fields } = next
  Object.assign(state, fields)
  hourly.value = markRaw(Array.isArray(nextHourly) ? nextHourly : Object.values(nextHourly || {}))
  daily.value = markRaw(Array.isArray(nextDaily) ? nextDaily : Object.values(nextDaily || {}))
  state.settings = next.settings || {}
  state.globalSettings = next.globalSettings || {}
  if (next.ready && !next.weatherEnabled && (!wasReady || wasEnabled)) settingsOpen.value = true
}

function weatherIconClass(condition) {
  const known = ['clear', 'partlyCloudy', 'overcast', 'drizzle', 'rain', 'storm']
  return `weather-glyph--${known.includes(condition) ? condition : 'clear'}`
}

function formatTemp(celsius) {
  const value = Number(celsius) || 0
  if (state.globalSettings.temperatureUnit === 'C') return `${Math.round(value)}°`
  return `${Math.round(value * 9 / 5 + 32)}°`
}

function formatTime(minute, compact = false) {
  const total = ((Math.round(Number(minute) || 0) % 1440) + 1440) % 1440
  const hour24 = Math.floor(total / 60)
  const hour12 = hour24 % 12 || 12
  const suffix = hour24 < 12 ? 'AM' : 'PM'
  if (compact) return `${hour12} ${suffix}`
  return `${hour12}:${String(total % 60).padStart(2, '0')} ${suffix}`
}

function dayLabel(index) {
  if (index === 0) return 'Today'
  if (index === 1) return 'Tomorrow'
  if (index === 2) return 'Next day'
  return `Day ${index + 1}`
}

async function setSetting(key, value) {
  try {
    await lua.overhaul_world_weather.setSetting(key, value)
  } catch (error) {
    reportUiFailure([key, error], "[PhoneWeather] Failed to save setting (PhoneWeather)")
  }
}

function cycleDayLength() {
  const current = Number(state.settings.dayLengthMinutes) || 60
  const index = dayLengths.indexOf(current)
  setSetting('dayLengthMinutes', dayLengths[(index + 1) % dayLengths.length])
}

function toggleTemperatureUnit() {
  setSetting('temperatureUnit', state.globalSettings.temperatureUnit === 'C' ? 'F' : 'C')
}

let listening = false
let activation = 0

async function openWeather() {
  if (listening) return
  listening = true
  const currentActivation = ++activation
  closeSettings()
  events.on('RLSWeatherState', applyState)
  try {
    await acquireScope(lua, 'phone.weather')
    if (!listening || activation !== currentActivation) return
    const next = await lua.overhaul_world_weather.requestUiState()
    if (listening && activation === currentActivation) applyState(next)
  } catch (error) {
    reportUiFailure(error, "[PhoneWeather] Weather module unavailable (PhoneWeather)")
  }
}

function closeWeather() {
  if (!listening) return
  listening = false
  activation++
  events.off('RLSWeatherState', applyState)
  Promise.resolve(releaseScope(lua, 'phone.weather')).catch(error => reportUiFailure(error, "[PhoneWeather] Failed to release weather scope"))
}

onMounted(openWeather)
onActivated(openWeather)
onDeactivated(closeWeather)
onUnmounted(closeWeather)
</script>

<style scoped lang="scss">
.weather-app {
  --sky-a: #2775bd;
  --sky-b: #102b58;
  min-height: 100%;
  height: 100%;
  overflow-y: auto;
  color: #fff;
  padding: 42px 0 88px;
  background: linear-gradient(165deg, var(--sky-a), var(--sky-b) 44%, #101725);
  scrollbar-width: none;
}
.weather-app::-webkit-scrollbar { display: none; }
.weather-app--partlyCloudy { --sky-a: #536f9e; --sky-b: #263d67; }
.weather-app--overcast { --sky-a: #526072; --sky-b: #242f42; }
.weather-app--drizzle, .weather-app--rain { --sky-a: #405468; --sky-b: #172738; }
.weather-app--storm { --sky-a: #303748; --sky-b: #101622; }
.loading, .external-lock { min-height: 75%; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; padding: 28px; }
.weather-off { padding: 28px 20px 8px; }
.weather-off p { color: rgba(255,255,255,.72); line-height: 1.5; font-size: 13px; }
.external-lock { background: linear-gradient(180deg, #3b1118, #160f18); }
.external-lock__flag { width: 68px; height: 68px; border-radius: 50%; display: grid; place-items: center; font-size: 44px; font-weight: 900; background: #e43f4f; box-shadow: 0 10px 35px rgba(228, 63, 79, .3); }
.external-lock h1 { margin: 20px 0 8px; font-size: 25px; }
.external-lock p { margin: 0; color: rgba(255,255,255,.72); line-height: 1.5; }
.external-lock__status { margin-top: 24px; padding: 10px 14px; border: 1px solid rgba(255,255,255,.16); border-radius: 12px; color: #ffadb5; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
.hero { padding: 24px 20px 16px; display: grid; grid-template-columns: 1fr auto; align-items: center; }
.location { margin: 0; font-size: 18px; font-weight: 700; }
.condition { margin: 2px 0 0; color: rgba(255,255,255,.72); }
.hero-icon { display: flex; align-items: center; justify-content: center; filter: drop-shadow(0 8px 16px rgba(0,0,0,.25)); }
.temperature { grid-column: 1 / -1; font-size: 78px; font-weight: 300; line-height: 1; margin-top: 10px; }
.clock { grid-column: 1 / -1; margin: 8px 0 0; color: rgba(255,255,255,.72); font-size: 12px; }
.metrics { margin: 0 14px 18px; padding: 14px 8px; display: grid; grid-template-columns: repeat(4, 1fr); gap: 4px; background: linear-gradient(145deg, rgba(125,158,202,.22), rgba(255,255,255,.08)); border: 1px solid rgba(255,255,255,.11); border-radius: 18px; box-shadow: inset 0 1px 0 rgba(255,255,255,.08); contain: paint; }
.metrics div { text-align: center; min-width: 0; }
.metrics strong { display: block; font-size: 13px; white-space: nowrap; }
.metrics span { display: block; margin-top: 4px; font-size: 9px; color: rgba(255,255,255,.62); }
.section { margin-top: 18px; }
.section-title { display: flex; justify-content: space-between; padding: 0 18px 8px; color: rgba(255,255,255,.72); font-size: 11px; text-transform: uppercase; letter-spacing: .08em; }
.hourly-strip { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 8px; overflow: hidden; padding: 0 14px 8px; }
.hour-card { min-width: 0; padding: 11px 4px; display: flex; flex-direction: column; align-items: center; gap: 5px; background: rgba(255,255,255,.1); border: 1px solid rgba(255,255,255,.08); border-radius: 16px; }
.hour-time, .hour-card small { font-size: 10px; color: rgba(255,255,255,.66); }
.hour-icon { height: 28px; display: flex; align-items: center; justify-content: center; }
.daily-section { margin: 22px 14px 0; padding: 14px 0 4px; background: rgba(10,16,28,.35); border-radius: 18px; }
.day-row { display: grid; grid-template-columns: 82px 32px 1fr auto; gap: 6px; align-items: center; padding: 10px 14px; font-size: 12px; }
.day-row + .day-row { border-top: 1px solid rgba(255,255,255,.07); }
.day-icon { height: 24px; display: flex; align-items: center; }
.day-condition { color: rgba(255,255,255,.67); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.day-temps { color: rgba(255,255,255,.55); white-space: nowrap; }
.day-temps strong { color: #fff; margin-right: 5px; }
.settings-card { margin: 18px 14px 0; background: rgba(10,16,28,.48); border-radius: 18px; overflow: hidden; }
.settings-toggle { width: 100%; padding: 16px; display: flex; align-items: center; justify-content: space-between; border: 0; color: #fff; background: transparent; font: inherit; font-weight: 700; text-align: left; cursor: pointer; }
.settings-toggle__chevron { font-size: 24px; line-height: 16px; transform: rotate(90deg); transition: transform .16s ease; }
.settings-toggle__chevron--open { transform: rotate(-90deg); }
.settings-body { border-top: 1px solid rgba(255,255,255,.07); }
.setting-row { min-height: 58px; padding: 10px 15px; display: flex; align-items: center; justify-content: space-between; gap: 14px; border-top: 1px solid rgba(255,255,255,.07); }
.settings-body .setting-row:first-child { border-top: 0; }
.setting-row span { display: flex; flex-direction: column; }
.setting-row strong { font-size: 13px; }
.setting-row small { margin-top: 3px; color: rgba(255,255,255,.55); font-size: 10px; }
.setting-value-button { flex: 0 0 auto; min-width: 82px; padding: 8px 10px; border: 1px solid rgba(255,255,255,.18); border-radius: 9px; color: #fff; background: #243247; font: inherit; font-size: 11px; cursor: pointer; }
.setting-value-button:active, .settings-toggle:active { background-color: rgba(84,169,255,.18); }
.setting-row input[type='checkbox'] { width: 20px; height: 20px; accent-color: #54a9ff; }

.weather-glyph { position: relative; display: inline-block; flex: 0 0 auto; }
.weather-glyph--hero { width: 82px; height: 62px; }
.weather-glyph--hour { width: 35px; height: 28px; }
.weather-glyph--day { width: 30px; height: 24px; }
.weather-glyph i { position: absolute; display: none; box-sizing: border-box; }
.weather-glyph__sun { top: 1%; left: 2%; width: 48%; height: 64%; border-radius: 50%; background: radial-gradient(circle at 35% 32%, #fff59b 0 7%, #ffd54b 32%, #ff9800 100%); box-shadow: 0 0 0 2px rgba(255,193,7,.2), 0 0 10px rgba(255,193,7,.55); }
.weather-glyph__cloud { right: 0; bottom: 18%; width: 72%; height: 34%; border-radius: 999px; background: linear-gradient(180deg, #fff 0%, #e7edf5 58%, #b7c2d1 100%); box-shadow: 0 2px 4px rgba(0,0,0,.2); }
.weather-glyph__cloud::before, .weather-glyph__cloud::after { content: ''; position: absolute; border-radius: 50%; background: inherit; }
.weather-glyph__cloud::before { left: 14%; bottom: 22%; width: 44%; height: 128%; }
.weather-glyph__cloud::after { right: 12%; bottom: 18%; width: 37%; height: 108%; }
.weather-glyph__rain { left: 30%; bottom: 0; width: 66%; height: 22%; transform: skewX(-14deg); background: repeating-linear-gradient(90deg, transparent 0 14%, #5dd7ff 15% 21%, transparent 22% 34%); }
.weather-glyph__bolt { left: 54%; bottom: -1%; width: 18%; height: 32%; background: #ffd740; clip-path: polygon(43% 0, 100% 0, 66% 40%, 96% 40%, 24% 100%, 42% 53%, 8% 53%); filter: drop-shadow(0 1px 1px rgba(0,0,0,.35)); }
.weather-glyph--clear .weather-glyph__sun { display: block; top: 13%; left: 22%; width: 56%; height: 74%; }
.weather-glyph--partlyCloudy .weather-glyph__sun,
.weather-glyph--partlyCloudy .weather-glyph__cloud,
.weather-glyph--overcast .weather-glyph__cloud,
.weather-glyph--drizzle .weather-glyph__cloud,
.weather-glyph--drizzle .weather-glyph__rain,
.weather-glyph--rain .weather-glyph__cloud,
.weather-glyph--rain .weather-glyph__rain,
.weather-glyph--storm .weather-glyph__cloud,
.weather-glyph--storm .weather-glyph__rain,
.weather-glyph--storm .weather-glyph__bolt { display: block; }
.weather-glyph--overcast .weather-glyph__cloud { right: 14%; bottom: 27%; }
.weather-glyph--drizzle .weather-glyph__rain { opacity: .55; }
</style>
