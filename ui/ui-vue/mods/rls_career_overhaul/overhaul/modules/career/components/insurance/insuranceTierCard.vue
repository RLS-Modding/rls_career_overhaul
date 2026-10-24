<!-- One insurance class on the overview (Daily Driver / Commercial / Prestige). House tile: plain icon,
     name, one short line, and how many of your vehicles it covers. -->
<template>
  <div class="rls-house insurance-tier-card" :class="{ covered: classData.carsInsured > 0 }" @click="$emit('select', classId)" bng-nav-item tabindex="0">
    <BngIcon class="insurance-icon" :type="icons[classData.icon]" />
    <div class="insurance-tier-card-name">
      {{ classData.name }}
    </div>
    <div class="insurance-tier-card-description">
      {{ classData.description }}
    </div>
    <div class="insurance-tier-card-cars-insured">
      <span>{{ $translate.instant("ui.career.insurance.vehiclesInsured", { count: classData.carsInsured }) }}</span>
    </div>
  </div>
</template>

<script setup>
import { BngIcon, icons } from "@/common/components/base"
import { $translate } from "@/services/translation"

defineEmits(["select"])

defineProps({
  classId: {
    type: String,
    required: true,
  },
  classData: {
    type: Object,
    required: true,
  },
})
</script>

<style scoped lang="scss">
@use "@/styles/modules/mixins" as *;
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

.insurance-tier-card {
  $f-offset: 0.2em;
  $rad: var(--radius-panel);
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.35em;
  min-width: 0;
  min-height: 10.5em;
  padding: 1em 1em 0.9em;
  border-radius: $rad;
  background: var(--panel);
  color: #fff;
  cursor: pointer;
  transition: background-color 0.12s;

  // controller / keyboard focus: the house ring (hides the game's ::before frame)
  @include house-focus;

  &:hover,
  &:focus,
  &:focus-within {
    background: var(--panel-2);
    .insurance-icon {
      color: #fff;
    }
  }
}

.insurance-icon {
  align-self: flex-start;
  width: auto;
  font-size: 2.2em;
  color: rgba(255, 255, 255, 0.82);
  margin-bottom: 0.2em;
  transition: color 0.12s;
}

.insurance-tier-card-name {
  font-size: 1.35em;
  font-weight: 800;
  line-height: 1.15;
}

.insurance-tier-card-description {
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 600;
  line-height: 1.35;
}

.insurance-tier-card-cars-insured {
  display: flex;
  align-items: baseline;
  gap: 0.45em;
  margin-top: auto;
  padding-top: 0.6em;
  // the game's translated "N VEHICLES INSURED" line, as a Style Guide caption
  color: var(--faint);
  font-size: 0.75em;
  font-weight: 700;
  letter-spacing: 0.06em;
  font-variant-numeric: tabular-nums;
}

// classes that cover your cars: warm icon, glow and count
.insurance-tier-card.covered {
  background:
    radial-gradient(120% 70% at 0% 0%, rgba(255, 102, 0, 0.14), rgba(255, 102, 0, 0) 60%),
    var(--panel);
  .insurance-icon {
    color: var(--accent-soft);
  }
  .insurance-tier-card-cars-insured {
    color: #fff;
  }
  &:hover,
  &:focus,
  &:focus-within {
    background:
      radial-gradient(120% 70% at 0% 0%, rgba(255, 102, 0, 0.2), rgba(255, 102, 0, 0) 60%),
      var(--panel-2);
  }
}
</style>
