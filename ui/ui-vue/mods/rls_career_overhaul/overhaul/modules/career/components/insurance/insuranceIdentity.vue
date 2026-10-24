<template>
  <div class="insurance-identity" :class="{ 'no-insurance': !hasInsurance }">
    <div v-if="svgContent" class="insurance-icon" v-html="svgContent"></div>

    <BngImage
      v-else-if="props.insuranceData.image"
      class="insurance-icon"
      :src="`/${props.insuranceData.image}`"
      :alt="$translate.instant(props.insuranceData.name)"
    />

    <div v-else class="insurance-icon is-text">
      <div class="insurance-name" :class="{ 'is-none': hasNoInsurance }">
        <BngIcon class="insurance-no-icon" :type="icons.danger" />
        {{ hasNoInsurance ? $t("ui.career.insurance.noInsurance") : $translate.instant(props.insuranceData.name) }}
      </div>
    </div>

    <div v-if="!hasNoInsurance" class="insurance-slogan" :title="$translate.instant(props.insuranceData.slogan || '')">
      "{{ $translate.instant(props.insuranceData.slogan) }}"
    </div>
  </div>
</template>

<script setup>
import { $translate } from "@/services/translation"
import { reportUiFailure } from "../../utils/safeLua.js"

import { ref, watch, computed } from "vue"
import { BngImage, BngIcon, icons } from "@/common/components/base"
import { getURL, getFile } from "@/utils"
import "./insuranceStyle.css"

const props = defineProps({
  insuranceData: {
    type: Object,
    required: true,
  },
})

const hasInsurance = computed(() => svgContent.value || props.insuranceData.image)

const hasNoInsurance = computed(() => props.insuranceData?.id === -1)

const svgContent = ref(null)

watch(
  () => props.insuranceData.image,
  async newPath => {
    if (newPath && newPath.endsWith(".svg")) {
      try {
        const rawSvg = await getFile(`/${newPath}`)
        if (rawSvg) {
          // Basic sanitization: remove script tags and event handlers
          svgContent.value = rawSvg
            .replace(/<script\b[^>]*>([\s\S]*?)<\/script>/gim, "")
            .replace(/ on\w+="[^"]*"/g, "")
        } else {
          svgContent.value = null
        }
      } catch (e) {
        reportUiFailure(e, "Failed to load SVG inline:")
        svgContent.value = null
      }
    } else {
      svgContent.value = null
    }
  },
  { immediate: true }
)
</script>

<style scoped lang="scss">
/* RLS house: the provider's logo is the name, so it is the biggest thing on its card; the slogan
   is one faint line under it. Fixed height so logo / no-logo / no-insurance cards line up. */
.insurance-identity {
  align-self: stretch;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: center;
  gap: 0.35em;
  min-width: 0;
  height: 6.4em;
  overflow: hidden;

  .insurance-icon {
    flex: 1 1 auto;
    min-height: 0;
    width: 100%;
    object-fit: contain;
    :deep(svg) {
      width: 100%;
      height: 100%;
    }
    .insurance-name {
      display: flex;
      justify-content: center;
      align-items: center;
      gap: 0.3em;
      width: 100%;
      height: 100%;
      font-size: 1.55em;
      font-weight: 800;
      line-height: 1.15;
      text-align: center;
      overflow-wrap: anywhere;
    }
    .insurance-no-icon {
      --bng-icon-size: 1em;
      --bng-icon-color: var(--bad, #fca5a5);
      transform: translateY(-0.06em);
    }
  }

  .insurance-slogan {
    flex: 0 0 auto;
    color: var(--faint, rgba(255, 255, 255, 0.55));
    font-size: 0.85em;
    font-style: italic;
    font-weight: 600;
    text-align: center;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
}

/* the warning glyph only makes sense for "No insurance"; a provider without a logo just shows its name */
.insurance-name:not(.is-none) .insurance-no-icon {
  display: none;
}
</style>
