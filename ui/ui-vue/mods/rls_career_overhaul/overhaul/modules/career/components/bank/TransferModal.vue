<template><slot /></template>
<script setup>
import Form from './TransferForm.vue'
import { useBankPopup } from './useBankPopup.js'
const props = defineProps({ show: Boolean, sourceAccountId: { type: String, default: '' } })
const emit = defineEmits(['close', 'transferred'])
useBankPopup(Form, props, emit, 'transferred')
</script>
