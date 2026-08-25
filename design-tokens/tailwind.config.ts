import type { Config } from "tailwindcss";

/**
 * shadcn's own components already emit logical properties when built with
 * this config — the discipline that matters going forward is: never write
 * `ml-*`, `mr-*`, `left-*`, `right-*`, or `text-left` in new component code.
 * Always use `ms-*` / `me-*` / `ps-*` / `pe-*` and `text-start` / `text-end`.
 * That's what makes RTL "native from day zero" rather than a retrofit.
 */
const config: Config = {
  darkMode: "class",
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      borderRadius: {
        sm: "var(--radius-sm)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
        xl: "var(--radius-xl)",
      },
      colors: {
        background: "hsl(var(--background))",
        foreground: "hsl(var(--foreground))",
        primary: {
          DEFAULT: "hsl(var(--primary))",
          foreground: "hsl(var(--primary-foreground))",
        },
        accent: {
          DEFAULT: "hsl(var(--accent))",
          foreground: "hsl(var(--accent-foreground))",
        },
        success: "hsl(var(--success))",
        warning: "hsl(var(--warning))",
        destructive: {
          DEFAULT: "hsl(var(--destructive))",
          foreground: "hsl(var(--destructive-foreground))",
        },
        muted: {
          DEFAULT: "hsl(var(--muted))",
          foreground: "hsl(var(--muted-foreground))",
        },
        border: "hsl(var(--border))",
        input: "hsl(var(--input))",
        ring: "hsl(var(--ring))",
        card: {
          DEFAULT: "hsl(var(--card))",
          foreground: "hsl(var(--card-foreground))",
        },
      },
      fontFamily: {
        sans: ["var(--font-sans-ltr)"],
        "sans-rtl": ["var(--font-sans-rtl)"],
        mono: ["var(--font-mono)"],
      },
    },
  },
  plugins: [
    // tailwindcss-rtl (or Tailwind v4's built-in logical utilities) so
    // ms-*/me-*/ps-*/pe-* resolve correctly per the <html dir> attribute.
    require("tailwindcss-rtl"),
  ],
};

export default config;

/**
 * App-root bootstrapping (e.g. in App.tsx):
 *
 *   useEffect(() => {
 *     document.documentElement.lang = activeLocale;               // "en" | "fa"
 *     document.documentElement.dir = activeLocale === "fa" ? "rtl" : "ltr";
 *   }, [activeLocale]);
 *
 * Set once at the root — never per-component — so every shadcn primitive
 * and every ms-/me- utility inherits the correct direction automatically.
 */
