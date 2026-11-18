-- LuaJIT's table.sort partition order, expressed in Lua so its comparison loop
-- can be JIT compiled. The swap order matters: bank timestamp ties are observable.
-- Adapted from LuaJIT lib_table.c auxsort and Lua 5.1 ltablib.c.
--[[
Copyright (C) 2005-2026 Mike Pall. All rights reserved.
Copyright (C) 1994-2012 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
]]
local function partitionSort(rows, less, lower, upper)
  while lower < upper do
    if less(rows[upper], rows[lower]) then rows[lower], rows[upper] = rows[upper], rows[lower] end
    if upper - lower == 1 then break end
    local middle = math.floor((lower + upper) / 2)
    if less(rows[middle], rows[lower]) then rows[middle], rows[lower] = rows[lower], rows[middle]
    elseif less(rows[upper], rows[middle]) then rows[middle], rows[upper] = rows[upper], rows[middle] end
    if upper - lower == 2 then break end
    local pivot = rows[middle]
    rows[middle], rows[upper - 1] = rows[upper - 1], rows[middle]
    local left, right = lower, upper - 1
    while true do
      repeat
        left = left + 1
        if not less(rows[left], pivot) then break end
        if left >= upper then error('invalid order function for sorting') end
      until false
      repeat
        right = right - 1
        if not less(pivot, rows[right]) then break end
        if right <= lower then error('invalid order function for sorting') end
      until false
      if right < left then break end
      rows[left], rows[right] = rows[right], rows[left]
    end
    rows[upper - 1], rows[left] = rows[left], rows[upper - 1]
    -- Recurse into the smaller partition to bound stack depth, as the VM does.
    if left - lower < upper - left then
      partitionSort(rows, less, lower, left - 1)
      lower = left + 1
    else
      partitionSort(rows, less, left + 1, upper)
      upper = left - 1
    end
  end
end

return function(rows, less) partitionSort(rows, less, 1, #rows) end
