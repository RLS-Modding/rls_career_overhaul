// Membership follows the named host, including after route-record replacement.
export const PHONE_SHELL_ROUTE = 'phone-shell'

export function isPhoneRoute(route) {
  return !!route?.matched?.some(record => record.name === PHONE_SHELL_ROUTE)
}
