-- What the player has spent on one car, read from the money history: buying it, parts, paint, engines,
-- plates and repairs, less refunds for that car. Running costs (fuel, insurance, fines, towing) are not counted.
-- Pure read: rows are matched by the car's saved finance identity only. Inventory ids are reused slots, so rows saved
-- before the identity cannot be tied to this car and are not counted; the boss then goes by market value.
local metadata=require('overhaul/lib/finance/metadata')
local M={}
M.spendCategories={purchase=true,repair=true}
M.refundCategories={refund=true}

local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end

function M.total(logRows,financeKey)
  if type(financeKey)~='string' or financeKey=='' then return 0 end
  local spent=0
  for _,row in ipairs(type(logRows)=='table' and logRows or {}) do
    local amount=type(row)=='table' and type(row.attributeChange)=='table' and row.attributeChange.money
    if finite(amount) and amount~=0 then
      local meta=metadata.read(row,amount)
      if meta.vehicleKey==financeKey then
        if amount<0 and M.spendCategories[meta.category] then spent=spent-amount
        elseif amount>0 and M.refundCategories[meta.category] then spent=spent-amount end
      end
    end
  end
  return math.max(0,math.floor(spent))
end

-- The boss values your car at what you put into it, or its market value when that is higher.
function M.worth(value,spend)
  return math.max(finite(value) and value or 0,finite(spend) and spend or 0)
end
return M
