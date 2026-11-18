-- Gameplay costs only. None of these values participate in fuel physics.
-- Snapshot: 2026-09-29. DOE April 2026 pump E85 $3.31/US gal;
-- Torco 5-gal methanol $65 ($13/gal), nitromethane $390 ($78/gal).
-- Preserve Career's E85 price anchor and scale by volume-price ratios.
-- Nitro 90 is priced as 90% nitromethane + 10% methanol ($71.50/gal).
-- Source details and exclusions: docs/weepy-fuel-feedback.md.
local e85Anchor=.80
local raceFuelPriceMultiplier=.70
local source={e85=3.31,m100=65/5,nitromethane=390/5}
return {
  referencePricesPerGallon=source,
  conversionPrice=1870,
  methanolConversionPrice=4850,
  nitroConversionPrice=8450,
  -- Fuel delivery upgrades: 1 = larger injectors, 2 = injectors and pump,
  -- 3 = race injectors and pump for big-turbo builds.
  deliveryStagePrices={[1]=1450,[2]=3200,[3]=5500},
  flushPrice=0, -- Draining discards fuel without a fee or refund.
  tunePrice=0,
  gradePriceFactors={regular=1,premium=1.15,e85=e85Anchor,m100=raceFuelPriceMultiplier*e85Anchor*source.m100/source.e85,
    nitro90=raceFuelPriceMultiplier*e85Anchor*(.9*source.nitromethane+.1*source.m100)/source.e85},
}
