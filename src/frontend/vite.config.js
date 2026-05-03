import { defineConfig } from "vite";
import { copyFileSync, existsSync, mkdirSync } from "fs";

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
      if (existsSync("public/deployment-manifest.json")) {
        copyFileSync("public/deployment-manifest.json", "dist/deployment-manifest.json");
      }
    }
  }],
  server: {
    proxy: {
      "/api": "http://localhost:4943",
    },
  },
});
