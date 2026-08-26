import { QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import ReactDOM from "react-dom/client";

import { App } from "./App";
import { queryClient } from "./lib/queryClient";
import "./styles/globals.css";

/**
 * Set once at the app root, never inferred per-component -- see
 * design-tokens/tailwind.config.ts and apps/desktop/README.md. Locale
 * switching isn't built yet (no i18n library has been decided), so this is
 * hardcoded to the primary locale for now; when it lands, this is the only
 * place it needs to change.
 */
document.documentElement.lang = "en";
document.documentElement.dir = "ltr";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>,
);
