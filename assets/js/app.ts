import "@vue-flow/core/dist/style.css"
import "@vue-flow/core/dist/theme-default.css"
import "@vue-flow/controls/dist/style.css"
import "@vue-flow/minimap/dist/style.css"
import ReachGraph from "@reach/components/ReachGraph.vue"
import { createApp } from "vue"

createApp(ReachGraph, {
  graphData: (window as Record<string, unknown>).graphData
}).mount("#app")
