<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<template><slot /></template>
<script setup>
import Form from './WithdrawForm.vue'
import { useBankPopup } from './useBankPopup.js'
const props = defineProps({ show: Boolean, accountId: { type: String, required: true }, accountBalance: { type: Number, default: 0 } })
const emit = defineEmits(['close', 'withdrawn'])
useBankPopup(Form, props, emit, 'withdrawn')
</script>
