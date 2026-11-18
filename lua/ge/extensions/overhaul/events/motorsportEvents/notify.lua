-- Owns Motorsport toasts. They join the shared Overhaul Event display stack (overhaul/lib/ui/eventDisplay.lua) in place
-- of the stock ui_message app, so group calls, staging and results read like the Event display card.
-- Callers require this lazily, at the moment they toast.
local hud = require('overhaul/lib/ui/eventDisplay')
-- The old ui_message categories map onto the card's banner tints: an orange call to act, red for a problem.
local KINDS = {info = 'info', good = 'good', motorsport = 'warn', warn = 'warn', warning = 'bad', bad = 'bad',
  wait = 'info', act = 'warn', go = 'good', blocked = 'bad', done = 'good'}

return function(text, kind, seconds)
  return hud.toast('motorsport', text, {kind = KINDS[kind] or 'info', seconds = seconds})
end
