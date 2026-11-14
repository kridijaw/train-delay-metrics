import preact from "@preact/preset-vite";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [preact()],
  server: {
    // The shared queries live in ../sql, outside the Vite root.
    fs: { allow: [".."] },
  },
});
