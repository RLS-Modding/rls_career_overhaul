<template><slot /></template>
<script setup>
import Form from './DepositForm.vue'
import { useBankPopup } from './useBankPopup.js'
const props = defineProps({ show: Boolean, accountId: { type: String, required: true } })
const emit = defineEmits(['close', 'deposited'])
useBankPopup(Form, props, emit, 'deposited')
</script>
