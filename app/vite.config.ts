import { defineConfig } from "vite";

// The dashboard imports the keeper's indexer and pool-state code directly from `../keeper/src`
// rather than keeping a copy: the numbers on screen are folded by the same functions the keeper
// acts on. `dedupe` makes those files resolve `viem` from this package, so a fresh clone only
// needs `npm install` here.
export default defineConfig({
  base: "./",
  resolve: { dedupe: ["viem"] },
  server: { fs: { allow: [".."] } },
});
