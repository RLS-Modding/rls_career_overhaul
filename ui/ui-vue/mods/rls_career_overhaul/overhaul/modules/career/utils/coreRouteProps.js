// This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
// If a copy of the bCDDL was not distributed with this
// file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

// RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
// RLS modifications: Copyright (C) RLS Modding

// Route params are typed at the component boundary: purchase identifiers become numbers,
// navigation flags become booleans, and profile routes select their load/save mode.
export const routeProps = {
  "overhaul.computer.vehicleShopping.vehicles.vehiclePurchase.chooseInsurance": route => ({
          menuMode: "purchase",
          params: {
            purchaseType: route.params.purchaseType,
            shopId: Number(route.params.shopId),
            insuranceId: route.params.insuranceId ? Number(route.params.insuranceId) : undefined,
          },
        }),
  "overhaul.computer.insurances.chooseInsurance": route => ({
          menuMode: "change",
          params: {
            vehicleId: Number(route.params.vehicleId),
          },
        }),
  "overhaul.organizations": route => ({ orgId: route.params.orgId }),
  "overhaul.progressLanding": route => ({
          pathId: route.params.pathId,
          comesFromBigMap: route.params.comesFromBigMap === "true" || route.params.comesFromBigMap === true
        }),
  "overhaul.branchPage": route => ({
          pathId: route.params.pathId,
          comesFromBigMap: route.params.comesFromBigMap === "true" || route.params.comesFromBigMap === true
        }),
  "overhaul.cargoOverview.organizations": route => ({
          orgId: route.params.orgId,
        }),
  "overhaul.profiles.saves": route => ({
          profileId: route.params.profileId,
          mode: "load",
        }),
  "overhaul.profiles.saveAs": () => ({
          mode: "save",
        }),
}
