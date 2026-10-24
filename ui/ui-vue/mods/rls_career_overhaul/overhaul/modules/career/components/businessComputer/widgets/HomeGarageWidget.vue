<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template>
  <!-- Current Vehicle: photo first, name biggest, payment in gold, goal; Put away is the one orange action. -->
  <div class="rls-house home-widget garage-widget">
    <div class="widget-header">
      <h3>Current vehicle</h3>
      <span v-if="sessionStore.pulledOutVehicle" class="pill">Pulled out</span>
    </div>

    <div class="widget-content current" v-if="sessionStore.pulledOutVehicle">
      <div class="car-photo">
        <img
          v-if="currentVehicleJob?.vehicleImage"
          :src="currentVehicleJob.vehicleImage"
          :alt="currentVehicleJob.vehicleName || 'Vehicle'"
          class="vehicle-image"
        />
        <BngIcon v-else class="car-fallback" :type="icons.car" />
      </div>

      <div class="car-copy">
        <h4 class="car-name" v-if="currentVehicleJob" :title="`${currentVehicleJob.vehicleYear || ''} ${currentVehicleJob.vehicleName || ''}`.trim()">
          {{ currentVehicleJob.vehicleYear }} {{ currentVehicleJob.vehicleName }}
        </h4>
        <h4 class="car-name" v-else :title="sessionStore.pulledOutVehicle?.name || 'Unknown Vehicle'">
          {{ sessionStore.pulledOutVehicle?.name || 'Unknown Vehicle' }}
        </h4>

        <template v-if="currentVehicleJob && !isPersonalVehicle">
          <div class="car-fact">
            <span class="fact-key">Payment</span>
            <span class="payment-value"><BngIcon class="cur" :type="icons.beamCurrency" />{{ Number(currentVehicleJob.reward || 0).toLocaleString() }}</span>
          </div>
          <div v-if="currentVehicleJob.goal" class="car-fact">
            <span class="fact-key">Goal</span>
            <span class="goal-text">{{ currentVehicleJob.goal }}</span>
          </div>
        </template>
        <div class="personal" v-else-if="isPersonalVehicle">
          <span class="pill">Personal vehicle</span>
          <span class="hint">Tune your own vehicle</span>
        </div>

        <div class="actions car-actions" v-if="!isPersonalVehicle">
          <HouseButton
            variant="quiet-danger"
            :icon="icons.xmark"
            :title="sessionStore.hasCapability('fleetVehicles') ? 'Sell vehicle' : 'Abandon Job'"
            :aria-label="sessionStore.hasCapability('fleetVehicles') ? 'Sell vehicle' : 'Abandon Job'"
            @click="$emit('abandon', currentVehicleJob)"
          />
          <HouseButton variant="primary" @click="$emit('put-away')">
            Put away
          </HouseButton>
        </div>
      </div>
    </div>

    <div class="widget-content empty-current" v-else>
      <BngIcon class="empty-car" :type="icons.car" />
      <p>No vehicle is currently being worked on.</p>
      <HouseButton compact @click="$emit('go-to-jobs')">
        {{ sessionStore.hasCapability('fleetVehicles') ? 'You must purchase a vehicle' : 'Select a vehicle from Jobs' }}
      </HouseButton>
    </div>
  </div>
</template>

<script setup>
import { computed } from "vue"
import { useBusinessSessionStore } from "../../../stores/businessComputer/businessSessionStore.js"
import { BngIcon, icons } from "@/common/components/base"
import { HouseButton } from "../../house/index.js"

const sessionStore = useBusinessSessionStore()

const normalizeJobId = (value) => {
  if (value === undefined || value === null) {
    return null
  }
  return String(value)
}

const isPersonalVehicle = computed(() => {
  return sessionStore.pulledOutVehicle?.isPersonal === true
})

const currentVehicleJob = computed(() => {
  const vehicle = sessionStore.pulledOutVehicle
  if (!vehicle) {
    return null
  }
  if (vehicle.isPersonal) {
    return {
      vehicleName: vehicle.vehicleName || 'Unknown Vehicle',
      vehicleYear: vehicle.vehicleYear || '',
      vehicleImage: vehicle.vehicleImage,
      vehicleType: vehicle.vehicleType,
      reward: 0,
      goal: null,
      isPersonal: true
    }
  }
  const jobsSource = sessionStore.activeJobs
  const jobs = Array.isArray(jobsSource)
    ? jobsSource
    : (Array.isArray(jobsSource?.value) ? jobsSource.value : [])
    
  const vid = normalizeJobId(vehicle.vehicleId)
  return jobs.find(job => {
    const sv = normalizeJobId(job?.storedVehicleId)
    if (sv && vid && sv === vid) return true
    const jobId = job?.jobId ?? job?.id
    const vj = normalizeJobId(vehicle.jobId)
    return jobId !== undefined && jobId !== null && vj && String(jobId) === vj
  }) || null
})

defineEmits(['put-away', 'abandon', 'go-to-jobs'])
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

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

.widget-content {
  flex: 1;
  padding: 0 var(--inset) var(--inset);
}

/* photo first and big, copy beside it. The photo is sized from its own track width
   (width 100% + aspect-ratio, top-aligned): a stretched row height used to drive its
   width through aspect-ratio, so a tall copy column (long name/goal) widened the photo
   over the text. The copy track keeps a floor so the name always has room. */
.current {
  display: grid;
  grid-template-columns: minmax(0, 1.15fr) minmax(13em, 1fr);
  gap: 1em;
  align-items: start;
}

.car-photo {
  position: relative;
  width: 100%;
  min-width: 0;
  aspect-ratio: 16 / 9;
  align-self: start;
  border-radius: var(--radius-tile);
  overflow: hidden;
  background: var(--photo);
  display: grid;
  place-items: center;

  .vehicle-image {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
  }

  .car-fallback {
    font-size: 3em;
    color: var(--faint);
  }
}

.car-copy {
  align-self: stretch;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 0.7em;
}

.car-name {
  margin: 0;
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
  letter-spacing: -0.01em;
  color: #fff;
  /* long names: two lines, then ellipsis */
  overflow-wrap: anywhere;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  overflow: hidden;
}

.car-fact {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}

.fact-key {
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--faint);
}

.payment-value {
  font-size: 1.2em;
  font-weight: 800;
  line-height: 1.15;
  color: var(--money);
  font-variant-numeric: tabular-nums;
}

.goal-text {
  overflow-wrap: anywhere;
  color: var(--muted);
  font-size: 0.95em;
  font-weight: 600;
  line-height: 1.35;
}

.personal {
  display: grid;
  justify-items: start;
  gap: 0.35em;
}

.car-actions {
  margin-top: auto;
  padding-top: 0.2em;
  flex-wrap: nowrap;
}

.empty-current {
  display: grid;
  justify-items: center;
  align-content: center;
  gap: 0.7em;
  min-height: 9em;
  text-align: center;
  color: var(--muted);

  .empty-car {
    font-size: 2.2em;
    color: var(--faint);
  }

  p {
    margin: 0;
    font-size: 0.95em;
    font-weight: 600;
  }
}

/* game currency glyph in front of amounts; inherits colour and size */
.cur {
  margin-right: 0.1em;
  transform: translateY(0.08em);
}
</style>
