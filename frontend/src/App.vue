<template>
  <div>
    <nav>
      <button @click="page = 'mint'">Mint</button>
      <button @click="page = 'dex'">DEX</button>
    </nav>

    <hr />

    <MintPanel v-if="page === 'mint'" />
    <DexPanel v-else />
  </div>
</template>

<script setup>
import { ref } from "vue";
import MintPanel from "./components/MintPanel.vue";
import DexPanel from "./components/DexPanel.vue";

const page = ref("mint");
</script>
