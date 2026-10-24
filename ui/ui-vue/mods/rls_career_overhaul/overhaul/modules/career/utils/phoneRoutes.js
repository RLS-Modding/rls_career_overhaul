// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
// Copyright (C) RLS Modding
// SPDX-License-Identifier: AGPL-3.0-only

// Membership follows the named host, including after route-record replacement.
export const PHONE_SHELL_ROUTE = 'phone-shell'

export function isPhoneRoute(route) {
  return !!route?.matched?.some(record => record.name === PHONE_SHELL_ROUTE)
}
