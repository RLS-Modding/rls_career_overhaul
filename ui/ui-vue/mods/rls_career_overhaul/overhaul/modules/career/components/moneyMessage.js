import { h, markRaw } from "vue"
import MoneyAmount from "./MoneyAmount.vue"

// HouseConfirm accepts a component message. Keep surrounding copy as text nodes,
// including player-authored names, rather than interpolating it into HTML.
export function moneyMessage(before, amount, after = "") {
  return {
    component: markRaw({
      render: () => [before, h(MoneyAmount, null, { default: () => amount }), after],
    }),
  }
}
