// A retargetable spring for UI motion, in Apple's two designer terms: damping ratio (1 = no
// overshoot) and response (seconds to reach the target, not a fixed duration). A new target keeps
// the current value and velocity, so motion can be reversed mid-flight without a jump. The loop
// only runs while moving and stops itself at rest.

const STEP_SECONDS = 1 / 240
const MAX_FRAME_SECONDS = 1 / 20 // after a hitch, don't integrate a huge jump
const REST_DISTANCE = 0.001
const REST_SPEED = 0.01

export function createSpring({ value = 0, response = 0.35, damping = 1, onUpdate = () => {}, onRest = () => {}, frames = globalThis } = {}) {
  let current = value
  let velocity = 0
  let target = value
  let params = { response, damping }
  let frame = null
  let lastTime = 0

  function stepTo(now) {
    const omega = (2 * Math.PI) / Math.max(params.response, 0.05)
    let remaining = Math.min(MAX_FRAME_SECONDS, Math.max(0, (now - lastTime) / 1000))
    lastTime = now
    while (remaining > 0) {
      const dt = Math.min(STEP_SECONDS, remaining)
      const acceleration = -omega * omega * (current - target) - 2 * params.damping * omega * velocity
      velocity += acceleration * dt
      current += velocity * dt
      remaining -= dt
    }
    if (Math.abs(current - target) < REST_DISTANCE && Math.abs(velocity) < REST_SPEED) {
      current = target
      velocity = 0
      frame = null
      onUpdate(current)
      onRest(current)
      return
    }
    onUpdate(current)
    frame = frames.requestAnimationFrame(stepTo)
  }

  function stop() {
    if (frame !== null) frames.cancelAnimationFrame(frame)
    frame = null
  }

  return {
    get value() { return current },
    // Jump with no motion (first layout, reduced motion).
    set(next) {
      stop()
      current = target = next
      velocity = 0
      onUpdate(current)
      onRest(current)
    },
    // Retarget from wherever the value is now. Pass velocity (units per second) to hand off a gesture.
    to(next, options = {}) {
      target = next
      params = { response: options.response ?? response, damping: options.damping ?? damping }
      if (Number.isFinite(options.velocity)) velocity = options.velocity
      if (frame === null) {
        lastTime = frames.performance?.now?.() ?? Date.now()
        frame = frames.requestAnimationFrame(stepTo)
      }
    },
    stop,
  }
}
