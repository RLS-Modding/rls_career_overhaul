import BusinessHomeView from "./BusinessHomeView.vue"
import BusinessActiveJobsTab from "./BusinessActiveJobsTab.vue"
import BusinessNewJobsTab from "./BusinessNewJobsTab.vue"
import BusinessInventoryTab from "./BusinessInventoryTab.vue"
import BusinessPartsInventoryTab from "./BusinessPartsInventoryTab.vue"
import BusinessTuningTab from "./BusinessTuningTab.vue"
import BusinessPartsCustomizationTab from "./BusinessPartsCustomizationTab.vue"
import BusinessSkillTreeTab from "./BusinessSkillTreeTab.vue"

const componentMap = {
  BusinessHomeView,
  BusinessActiveJobsTab,
  BusinessNewJobsTab,
  BusinessInventoryTab,
  BusinessPartsInventoryTab,
  BusinessTuningTab,
  BusinessPartsCustomizationTab,
  BusinessSkillTreeTab
}

export function getTabComponent(componentName) {
  return componentMap[componentName] || null
}

export default componentMap

