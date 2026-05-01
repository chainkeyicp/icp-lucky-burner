import { defineConfig } from "vite";
import { copyFileSync, mkdirSync } from "fs";

export default defineConfig({
  root: "src",
  envDir: "..",
  build: {
    outDir: "../dist",
    emptyOutDir: true,
  },
  plugins: [{
    name: "copy-well-known",
    closeBundle() {
      mkdirSync("dist/.well-known", { recursive: true });
      copyFileSync("src/.well-known/ic-domains", "dist/.well-known/ic-domains");
      copyFileSync("src/.ic-assets.json5", "dist/.ic-assets.json5");
    }
  }],
  server: {
    proxy: {
      "/api": "http://localhost:4943",
    },
  },
});
