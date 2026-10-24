-- Delivery mode belongs to logistics general, independently of whether the cargo screen is loaded.
-- Read constants and policies before the public owner adapters.

return function(M)
  return {
    id = 'deliveryMode', label = 'Logistics delivery mode', role = 'orchestrator', modes = {'career'},
    blocks = {'travelJournal'},
    blockingOrder = 10,
    probe = function()
      return not not (M.isDeliveryModeActive and M.isDeliveryModeActive())
    end,
  }
end
