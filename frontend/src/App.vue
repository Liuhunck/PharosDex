<template>
  <div>
    <nav>
      <button @click="page = 'mint'">Mint</button>
      <button @click="page = 'dex'">DEX</button>
      <button @click="page = 'add'">Add</button>
      <button @click="page = 'deposit'">Deposit</button>
    </nav>

    <hr />

    <MintPanel v-if="page === 'mint'" />
    <DexPanel v-else-if="page === 'dex'" />
    <AddBase v-else-if="page === 'add'" />
    <Deposit v-else />
  </div>
</template>

<script setup>
import { ref } from "vue";
import MintPanel from "./components/MintPanel.vue";
import DexPanel from "./components/DexPanel.vue";
import AddBase from "./components/AddBase.vue";
import Deposit from "./components/Deposit.vue";

const page = ref("mint");
</script>
