-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/marketplaceDebug.lua (BeamNG 0.40).
local M = {}
local im = ui_imgui
M.debugOrder = 0
M.debugName = "Marketplace"

local shopGenerationDelay = im.IntPtr(0)
local vehiclesPerDealership = im.IntPtr(0)

local function showVehicleList()
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  if tableIsEmpty(vehicles) then
    im.Text("No vehicles in inventory")
    return
  end

  im.Text("Vehicles in Inventory:")
  im.Separator()

  for inventoryId, veh in pairs(vehicles) do
    im.BeginGroup()

    -- Show vehicle info
    im.Text("Vehicle ID: " .. inventoryId)
    if veh.name then
      im.Text("Name: " .. veh.name)
    end

    -- Show listing status
    local listing = overhaul_career_market_marketplace.findVehicleListing(inventoryId)
    if listing then
      im.TextColored(im.ImVec4(0, 1, 0, 1), "Currently Listed")
    end

    im.EndGroup()
    im.Separator()
  end
end

M.drawDebugMenu = function()
  if im.CollapsingHeader1("Vehicle Inventory", im.TreeNodeFlags_DefaultOpen) then
    showVehicleList()
  end

  if im.CollapsingHeader1("Current Listings") then
    if tableIsEmpty(listedVehicles) then
      im.Text("No vehicles listed")
    else
      for _, listing in ipairs(listedVehicles) do
        if im.TreeNode1("Vehicle " .. listing.id) then
          im.Text("Value: $" .. string.format("%.2f", listing.value))
          im.Text("Timestamp: " .. listing.timestamp)

          if tableIsEmpty(listing.offers) then
            im.Text("No offers")
          else
            if im.BeginTable("OffersTable", 5, im.TableFlags_Borders) then
              im.TableSetupColumn("Offer #")
              im.TableSetupColumn("Value")
              im.TableSetupColumn("Timestamp")
              im.TableSetupColumn("Time Left")
              im.TableSetupColumn("Actions")
              im.TableHeadersRow()

              for i, offer in ipairs(listing.offers) do
                im.TableNextRow()

                im.TableNextColumn()
                im.Text(tostring(i))

                im.TableNextColumn()
                local difference = offer.value - listing.value
                if difference > 0 then
                  im.TextColored(im.ImVec4(0, 1, 0, 1), "$" .. string.format("%.2f", offer.value) .. " (+$" .. string.format("%.2f", difference) .. ")")
                else
                  im.TextColored(im.ImVec4(1, 0, 0, 1), "$" .. string.format("%.2f", offer.value) .. " (-$" .. string.format("%.2f", math.abs(difference)) .. ")")
                end

                im.TableNextColumn()
                im.Text(tostring(offer.timestamp))

                im.TableNextColumn()
                im.Text(tostring(offerTTL - (os.time() - offer.timestamp)) .. "s")

                im.TableNextColumn()
                if im.Button("Accept##" .. i) then
                  overhaul_career_market_marketplace.acceptOffer(listing.id, i)
                end
                im.SameLine()
                if im.Button("Decline##" .. i) then
                  overhaul_career_market_marketplace.declineOffer(listing.id, i)
                end
              end
              im.EndTable()
            end
          end

          im.TreePop()
        end
      end
    end
  end

  if im.Button("Generate Random Offer") then
    overhaul_career_market_marketplace.generateOffer()
  end
end

M.onCareerActivated = function()
end

return M