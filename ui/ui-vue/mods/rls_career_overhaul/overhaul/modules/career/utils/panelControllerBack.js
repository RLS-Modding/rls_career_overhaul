// A visible panel can release navigation while retaining just its Back action.
// Decide a walk-mode tap/hold on release so a hold never opens a dialog first.
// onHoldChange reports when a walk-mode press starts or ends, so the panel can
// show hold progress without a timer of its own.
export const PANEL_CONTROLLER_HOLD_MS = 600

export function createPanelControllerBack({ isWalking, walk, interact, leave, onHoldChange, now = () => performance.now(), holdMs = PANEL_CONTROLLER_HOLD_MS }) {
  let press = null
  const isHolding = () => !!press && !press.fromUi
  const setPress = next => {
    const wasHolding = isHolding()
    press = next
    if (wasHolding !== isHolding()) onHoldChange?.(isHolding())
  }
  return {
    cancel() { setPress(null) },
    handle(value) {
      if (value === 1) {
        if (press) return
        setPress({ started: now(), fromUi: !isWalking() })
        if (press.fromUi) walk()
      } else if (value === 0 && press) {
        const previous = press
        setPress(null)
        if (previous.fromUi) return
        if (now() - previous.started >= holdMs) interact()
        else leave()
      }
    },
  }
}
