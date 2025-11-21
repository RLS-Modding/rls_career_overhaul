import BusinessHomeView from "./BusinessHomeView.vue"
import BusinessJobsTab from "./BusinessJobsTab.vue"
import BusinessInventoryTab from "./BusinessInventoryTab.vue"
import BusinessPartsInventoryTab from "./BusinessPartsInventoryTab.vue"
import BusinessTuningTab from "./BusinessTuningTab.vue"
import BusinessPartsCustomizationTab from "./BusinessPartsCustomizationTab.vue"
import BusinessSkillTreeTab from "./BusinessSkillTreeTab.vue"
import BusinessTechsTab from "./BusinessTechsTab.vue"
import BusinessFinancesTab from "./BusinessFinancesTab.vue"

const componentMap = {
  BusinessHomeView,
  BusinessJobsTab,
  BusinessInventoryTab,
  BusinessPartsInventoryTab,
  BusinessTuningTab,
  BusinessPartsCustomizationTab,
  BusinessSkillTreeTab,
  BusinessTechsTab,
  BusinessFinancesTab
}

export function getTabComponent(componentName) {
  return componentMap[componentName] || null
}

export default componentMap

