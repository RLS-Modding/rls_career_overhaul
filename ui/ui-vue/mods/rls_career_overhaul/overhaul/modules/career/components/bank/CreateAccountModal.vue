<template><slot /></template>
<script setup>
import Form from './CreateAccountForm.vue'
import { useBankPopup } from './useBankPopup.js'
const props = defineProps({ show: Boolean })
const emit = defineEmits(['close', 'created'])
useBankPopup(Form, props, emit, 'created')
</script>
