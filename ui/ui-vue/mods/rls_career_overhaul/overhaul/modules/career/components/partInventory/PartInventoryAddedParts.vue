<template>
  <div class="added-parts rls-house">
    {{ $t("ui.career.partInventory.addedParts.description") }}
    <table style="width: 100%">
      <thead>
        <tr>
          <th>{{ $t("ui.career.partInventory.addedParts.id") }}</th>
          <th>{{ $t("ui.career.partInventory.addedParts.partDescription") }}</th>
          <th>{{ $t("ui.career.partInventory.addedParts.location") }}</th>
          <th>{{ $t("ui.career.partInventory.addedParts.mileage") }}</th>
          <th>{{ $t("ui.career.partInventory.addedParts.partValue") }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(part, key) in parts" :key="key">
          <td>{{ part.id }}</td>
          <td>{{ part.description.description }}</td>
          <td>{{ getLocationName(part) }}</td>
          <td>{{ units.buildString("length", part.partCondition.odometer, 0) }}</td>
          <td>{{ units.beamBucks(part.finalValue) }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<script setup>
import { useBridge } from "@/bridge"
import { $translate } from "@/services"

const { units } = useBridge()

const props = defineProps({
  parts: {
    type: Object,
    default: {},
  },
})

const getLocationName = part => part.location
  ? $translate.instant("ui.career.partInventory.addedParts.vehicleLocation", { number: part.location, model: part.vehicleModel })
  : $translate.instant("ui.career.partInventory.addedParts.inventory")
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* RLS house style: hairline table, caption headers, white description, gold value. */
.added-parts {
  color: var(--muted);
  font-weight: 600;
}

table {
  width: 100%;
  margin-top: 0.8em;
  border-collapse: collapse;
  font-variant-numeric: tabular-nums;
  & th,
  & td {
    padding: 0.45em 0.6em 0.35em 0;
    text-align: left;
    border-bottom: 1px solid var(--line);
  }
  & thead th {
    padding-top: 0.2em;
    padding-bottom: 0.3em;
    font-size: 0.75em;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--faint);
  }
  & tbody tr:last-child td {
    border-bottom: 0;
  }
  & td {
    color: var(--muted);
  }
  & td:nth-child(2) {
    color: #fff;
    font-weight: 700;
  }
  & th:last-child,
  & td:last-child {
    padding-right: 0;
    text-align: right;
  }
  & td:last-child {
    color: var(--money);
    font-weight: 700;
  }
}
</style>
