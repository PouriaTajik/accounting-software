import type { Config } from "tailwindcss";

import baseConfig from "../../design-tokens/tailwind.config";

/**
 * Extends design-tokens/tailwind.config.ts rather than editing it -- that
 * file is the shared design decision, consumed here (and eventually by any
 * other app in the monorepo) rather than forked per-app.
 */
const config: Config = {
  ...baseConfig,
  content: [
    "./src/renderer/**/*.{ts,tsx}",
    "../../packages/ui/src/**/*.{ts,tsx}",
  ],
  plugins: [...(baseConfig.plugins ?? []), require("tailwindcss-animate")],
};

export default config;
