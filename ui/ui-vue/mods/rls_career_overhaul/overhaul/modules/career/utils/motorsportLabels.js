// Shared vocabulary. Save identifiers (including finals/championship) stay unchanged.
export const labels = Object.freeze({
  finishEvent: 'Finish Event', startEvent: 'Start Event', final: 'Final',
  upcoming: 'Upcoming', racing: 'Racing', done: 'Done', simulated: 'Simulated',
  bye: 'Bye', noWinner: 'No winner', didNotQualify: 'Did not qualify',
  eliminated: 'Eliminated', excluded: 'Excluded', withdrawn: 'Withdrew',
})
export const count = (value, total, label = '') => `${label ? `${label} ` : ''}${value ?? 0} of ${total ?? 0}`
export function duration(value) {
  const seconds = Math.max(0, Math.ceil(Number(value) || 0))
  return seconds < 60 ? `${seconds} s` : `${Math.floor(seconds / 60)} min${seconds % 60 ? ` ${seconds % 60} s` : ''}`
}
export const money = value => `$${Number(value || 0).toLocaleString('en-US')}`
export const moneyTone = value => Number(value) === 0 ? 'ms-zero' : Number(value) < 0 ? 'ms-bad' : 'ms-money'
const dragResultReasons = Object.freeze({ jumping: 'Red light', outOfLane: 'Out of lane', crashed: 'Crashed',
  stationary: 'Stopped too long', stationaryTooLong: 'Stopped too long', reactionTime: 'Invalid reaction',
  vehicleRemoved: 'Vehicle removed', vehicleReset: 'Vehicle reset', vehicleSwitched: 'Vehicle switched', playerLeft: 'Left the race' })
export function dragResultReason(reason) {
  const prefix = 'missions.dragRace.gameplay.disqualified.'
  return typeof reason === 'string' && reason.startsWith(prefix)
    ? dragResultReasons[reason.slice(prefix.length)] || 'Disqualified' : reason
}
export function roundName(round) {
  if (!round) return 'Eliminations'
  if (round.championship) return labels.final
  return ({ 1: labels.final, 2: 'Semifinals', 4: 'Quarterfinals', 8: 'Round of 16' })[round.fullMatchCount || round.matches?.length]
    || `Round ${round.number || 1}`
}
export const matchStatus = (match, racing = false) => match.bye ? labels.bye
  : match.complete && !match.winnerId ? labels.noWinner : match.simulated ? labels.simulated
  : match.winnerId || match.complete ? labels.done : racing ? labels.racing : labels.upcoming
export const passPhase = phase => ({ armed: 'Head to staging', preparing: 'Stage', approaching: 'Stage', racing: 'Launch on green', cooldown: 'Pass complete', idle: 'Waiting' })[phase] || 'Waiting'
const actions = { acceptOffer: 'accept the offer', declineOffer: 'decline the offer', advanceOffer: 'skip to the next offer',
  withdrawEvent: 'withdraw', finishSpectatorWeekend: 'finish the event', startRegisteredEvent: 'start the event',
  routeRegistration: 'route to registration', routeCheckIn: 'route to check-in', cancelPass: 'cancel the pass',
  leaveSpectatorMode: 'stop watching', advanceDay: 'advance time', skipToMyGroup: 'skip to your group',
  register: 'register the entry', inspect: 'inspect the car', placeBet: 'place the bet' }
export const actionError = (action, reason = '') => `Couldn't ${actions[action] || String(action || 'complete the action').replace(/([A-Z])/g, ' $1').toLowerCase()}.${reason ? ` ${reason}` : ' Try again.'}`
