import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

export default defineConfig({
  root: "frontend/web-assets",
  base: "/static/careerops/",
  plugins: [tailwindcss()],
  build: {
    manifest: true,
    outDir: "dist",
    emptyOutDir: true,
    rolldownOptions: {
      input: "src/main.ts",
    },
  },
});
