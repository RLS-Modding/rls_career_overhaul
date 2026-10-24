<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template><!-- Visible content belongs to the stock popup host. --></template>

<script setup>
// Gameplay owners stay mounted to receive hide/resync events. Only their
// visible content enters the stock popup host, which enables menu action maps.
import { defineComponent, onBeforeUnmount, useSlots, watch } from "vue"
import { useRoute } from "vue-router"
import { openOverhaulPopup } from "../utils/openOverhaulPopup.js"

defineOptions({ inheritAttrs: false })

const props = defineProps({ active: Boolean, canCancel: { type: Boolean, default: true } })
const emit = defineEmits(["cancel", "leave"])
const slots = useSlots()
const route = useRoute()
const content = defineComponent({ setup: () => () => slots.default?.() })
let popup = null

function close() {
  const closing = popup
  popup = null
  closing?.return(true)
}

watch(() => props.active, active => {
  close()
  if (!active) return
  const opened = popup = openOverhaulPopup(content, {}, { beforeCancel: () => props.canCancel, fullscreen: true })
  opened.promise.then(result => {
    if (popup !== opened) return
    popup = null
    if (result === false) emit("cancel")
  })
}, { immediate: true, flush: "post" })

watch(() => route.fullPath, () => {
  if (!popup) return
  close()
  emit("leave")
})
onBeforeUnmount(close)
</script>
