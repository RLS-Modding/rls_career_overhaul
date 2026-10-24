<template><slot /></template>
<script setup>
import Form from './WithdrawForm.vue'
import { useBankPopup } from './useBankPopup.js'
const props = defineProps({ show: Boolean, accountId: { type: String, required: true }, accountBalance: { type: Number, default: 0 } })
const emit = defineEmits(['close', 'withdrawn'])
useBankPopup(Form, props, emit, 'withdrawn')
</script>
