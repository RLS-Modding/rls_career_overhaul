// Owns Start Event and Finish Event confirmation content and safe action choices.
// Parts: HouseConfirm hosts MotorsportConfirmRows; motorsportLabels supplies shared words.
// Contract: return the dialog result to callers; never start or finish an event here.
import { markRaw } from 'vue'
import { openHouseConfirmation } from '../components/house/index.js'
import MotorsportConfirmRows from '../components/motorsport/MotorsportConfirmRows.vue'
import { labels } from './motorsportLabels.js'

export const confirmationRows = props => ({ component: markRaw(MotorsportConfirmRows), props })
export function confirmFinishEvent({ eventName = 'Current event', reward = 0 } = {}) {
  return openHouseConfirmation(`${labels.finishEvent}?`, confirmationRows({
    intro: 'The remaining heats are simulated and the event closes.',
    rows: [{ label: 'Event', value: eventName }, { label: 'Payout earned', value: reward, money: true }],
  }), [
    { label: 'Keep watching', value: false, extras: { cancel: true, default: true } },
    { label: labels.finishEvent, value: true, extras: { confirm: true, destructive: true } },
  ])
}
export function confirmStartEvent({ entries = [], eventName = 'Current event' } = {}) {
  const cars = new Set(entries.map(entry => entry.inventoryId ?? entry.vehicleName ?? entry.model))
  const paid = entries.reduce((sum, entry) => sum + Number(entry.refundPaid ? 0 : entry.fee || 0), 0)
  return openHouseConfirmation(`${labels.startEvent}?`, confirmationRows({
    intro: 'Registration will close. Check every car and class before starting.',
    // Cars is listed only when a car is entered in more than one class; otherwise it repeats Entries.
    rows: [{ label: 'Event', value: eventName }, { label: 'Entries', value: entries.length },
      ...(cars.size === entries.length ? [] : [{ label: 'Cars', value: cars.size }]), { label: 'Entry fees paid', value: paid, money: true }],
  }), [
    { label: 'Keep registering', value: false, extras: { cancel: true } },
    { label: labels.startEvent, value: true, extras: { default: true } },
  ])
}
