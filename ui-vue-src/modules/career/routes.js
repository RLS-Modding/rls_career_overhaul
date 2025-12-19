// Career routes --------------------------------------

import ProgressLanding from "./views/ProgressLanding.vue"
import CargoDeliveryReward from "./views/CargoDeliveryReward.vue"
import CargoOverview from "./views/CargoOverviewMain.vue"
import CargoDropOff from "./views/CargoDropOff.vue"
import Computer from "./views/ComputerMain.vue"
import Insurances from "./views/InsurancesMain.vue"
import DriverAbstract from "./views/DriverAbstract.vue"
import Logbook from "./views/Logbook.vue"
import Milestones from "./views/Milestones.vue"
import MyCargo from "./views/MyCargo.vue"
import Painting from "./views/PaintingMain.vue"
import PartInventory from "./views/PartInventoryMain.vue"
import PartShopping from "./views/PartShoppingMain.vue"
import Pause from "./views/Pause.vue"
import PauseBigMiddlePanel from "./views/PauseBigMiddlePanel.vue"
import Profiles from "./views/Profiles.vue"
import Repair from "./views/RepairMain.vue"
import Tuning from "./views/TuningMain.vue"
import VehicleInventory from "./views/VehicleInventoryMain.vue"
import VehiclePurchase from "./views/VehiclePurchaseMain.vue"
import VehicleShopping from "./views/VehicleShoppingMain.vue"
import VehiclePerformance from "./views/VehiclePerformanceMain.vue"
import ChooseInsurance from "./views/ChooseInsuranceMain.vue"
import Negotiation from "./views/VehicleNegotiationMain.vue"
import Sleep from "./views/SleepMenu.vue"
import Loans from "./views/LoanMenu.vue"
import RoleAssignment from "./views/RoleAssignment.vue"
import CarMeets from "./views/CarMeetsMenu.vue"
import PurchaseGarage from "./views/PurchaseGarage.vue"
import PurchaseBusiness from "./views/PurchaseBusiness.vue"
import PhoneMain from "./views/PhoneMain.vue"
import PhoneMinimap from "./views/PhoneMinimap.vue"
import PhoneMarketplace from "./views/PhoneMarketplace.vue"
import PhoneTaxi from "./views/PhoneTaxi.vue"
import CarMeetsPhone from "./views/CarMeetsPhone.vue"
import PhoneRepo from "./views/PhoneRepo.vue"
import PhoneLoans from "./views/PhoneLoans.vue"
import PhoneLoanDetails from "./views/PhoneLoanDetails.vue"
import PhoneOfferDetails from "./views/PhoneOfferDetails.vue"
import PhoneBank from "./views/PhoneBank.vue"
import PhoneBankAccount from "./views/PhoneBankAccount.vue"
import PhoneBankRename from "./views/PhoneBankRename.vue"
import PhoneTuningShop from "./views/PhoneTuningShop.vue"
import LevelSwitch from "./views/LevelSwitch.vue"
import ChallengeComplete from "./views/ChallengeComplete.vue"
import BusinessComputerMain from "./views/BusinessComputerMain.vue"
export default [
  // Career Pause
  {
    path: "/menu.careerPause",
    name: "menu.careerPause",
    component: Pause,
    props: true,
    meta: {
      clickThrough: true,
      infoBar: {
        withAngular: true,
        visible: true,
        showSysInfo: true,
      },
      uiApps: {
        shown: false,
      },
      topBar: {
        visible: true
      }
    },
  },
  {
    path: "/career",
    children: [
      // Choose Insurance
      {
        path: "chooseInsurance",
        name: "chooseInsurance",
        component: ChooseInsurance,
      },

      // Career Pause (WIP with middle panel)
      {
        path: "pauseBigMiddlePanel",
        name: "pauseBigMiddlePanel",
        component: PauseBigMiddlePanel,
        props: true,
      },

      // Logbook
      {
        path: "logbook/:id(\\*?.*?)?",
        name: "logbook",
        component: Logbook,
        meta: {
          uiApps: {
            shown: false,
          },
        },
        props: true,
      },

      {
        path: "milestones/:id(\\*?.*?)?",
        name: "milestones",
        component: Milestones,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Computer
      {
        path: "computer",
        name: "computer",
        component: Computer,
        props: true,
        meta: {
          uiApps: {
            shown: false,
            //layout: "tasklist",
          },
        },
      },

      // Vehicle Inventory
      {
        path: "vehicleInventory",
        name: "vehicleInventory",
        component: VehicleInventory,
      },

      // Vehicle Certification
      {
        path: "vehiclePerformance/:inventoryId?",
        name: "vehiclePerformance",
        component: VehiclePerformance,
        props: true,
      },

      // Tuning
      {
        path: "tuning",
        name: "tuning",
        component: Tuning,
      },

      // Painting
      {
        path: "painting",
        name: "painting",
        component: Painting,
      },

      // Repair
      {
        path: "repair/:header?",
        name: "repair",
        component: Repair,
        props: true,
      },

      // Part Shopping
      {
        path: "partShopping",
        name: "partShopping",
        component: PartShopping,
        meta: {
          uiApps: {
            shown: false,
            //layout: "tasklist",
          },
        },
      },

      // Part Inventory
      {
        path: "partInventory",
        name: "partInventory",
        component: PartInventory,
      },

      // Vehicle Purchase
      {
        path: "vehiclePurchase/:vehicleInfo?/:playerMoney?/:inventoryHasFreeSlot?/:lastVehicleInfo?",
        name: "vehiclePurchase",
        component: VehiclePurchase,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Negotiation
      {
        path: "negotiation",
        name: "negotiation",
        component: Negotiation,
      },

      // Vehicle Shopping
      {
        path: "vehicleShopping/:screenTag?/:buyingAvailable?/:marketplaceAvailable?/:selectedSellerId?",
        name: "vehicleShopping",
        component: VehicleShopping,
        props: true,
        meta: {
          uiApps: {
            shown: false,
            //layout: "tasklist",
          },
        },
      },

      // Insurance policies List
      {
        path: "insurances",
        name: "insurances",
        component: Insurances,
      },

      // Driver's Abstract
      {
        path: "playerAbstract",
        name: "playerAbstract",
        component: DriverAbstract,
      },

      // Delivery Reward
      {
        path: "cargoDeliveryReward",
        name: "cargoDeliveryReward",
        component: CargoDeliveryReward,
        props: true,
      },

      // delivery dropoff
      {
        path: "cargoDropOff/:facilityId?/:parkingSpotPath(\\*?.*?)?",
        name: "cargoDropOff",
        component: CargoDropOff,
        props: true,
      },

      // Cargo Overview
      {
        path: "cargoOverview/:facilityId?/:parkingSpotPath(\\*?.*?)?",
        name: "cargoOverview",
        component: CargoOverview,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },
      {
        path: "myCargo",
        name: "myCargo",
        component: MyCargo,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Branch Landing Page
      {
        path: "progressLanding/:pathId?/:comesFromBigMap?",
        name: "progressLanding",
        component: ProgressLanding,
        props: route => ({
          pathId: route.params.pathId,
          comesFromBigMap: route.params.comesFromBigMap === "true" || route.params.comesFromBigMap === true
        }),
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
          },
        },
      },

      // Domain Landing Page
      {
        path: "domainSelection",
        name: "domainSelection",
        component: ProgressLanding,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
          },
        },
      },


      // Profiles
      {
        path: "profiles",
        name: "profiles",
        component: Profiles,
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
            showSysInfo: true,
          },
        }
      },

      // Sleep Menu
      {
        path: "sleep-menu",
        name: "sleep-menu",
        component: Sleep
      },

      // Loans Menu
      {
        path: "loans-menu",
        name: "loans-menu",
        component: Loans
      },

      // Police Assignment
      {
        path: "roleAssignment",
        name: "roleAssignment",
        component: RoleAssignment
      },

      {
        path: "carMeets",
        name: "carMeets",
        component: CarMeets
      },

      {
        path: "purchase-garage",
        name: "purchase-garage",
        component: PurchaseGarage
      },

      {
        path: "purchase-business",
        name: "purchase-business",
        component: PurchaseBusiness
      },

      {
        path: "phone-minimap",
        name: "phone-minimap",
        component: PhoneMinimap
      },

      {
        path: "phone-main",
        name: "phone-main",
        component: PhoneMain
      },

      {
        path: "car-meets-phone",
        name: "car-meets-phone",
        component: CarMeetsPhone
      },

      {
        path: "phone-taxi",
        name: "phone-taxi",
        component: PhoneTaxi
      },

      { 
        path: "phone-marketplace",
        name: "phone-marketplace",
        component: PhoneMarketplace
      },
      
      {
        path: "phone-repo",
        name: "phone-repo",
        component: PhoneRepo
      },

      {
        path: "phone-loans",
        name: "phone-loans",
        component: PhoneLoans
      },
      {
        path: "phone-loan/:loanId",
        name: "phone-loan-details",
        component: PhoneLoanDetails,
        props: true
      },
      {
        path: "phone-loan-offer/:orgId",
        name: "phone-offer-details",
        component: PhoneOfferDetails,
        props: true
      },

      {
        path: "phone-bank",
        name: "phone-bank",
        component: PhoneBank
      },

      {
        path: "phone-bank/:accountId",
        name: "phone-bank-account",
        component: PhoneBankAccount,
        props: true
      },

      {
        path: "phone-bank/:accountId/rename",
        name: "phone-bank-rename",
        component: PhoneBankRename,
        props: true
      },

      {
        path: "phone-tuning-shop",
        name: "phone-tuning-shop",
        component: PhoneTuningShop
      },

      {
        path: "level-switch",
        name: "level-switch",
        component: LevelSwitch
      },
      {
        path: "challenge-completed",
        name: "challenge-completed",
        component: ChallengeComplete
      },

      {
        path: "business-computer/:businessType/:businessId",
        name: "business-computer",
        component: BusinessComputerMain,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      }

    ],
  },
]
