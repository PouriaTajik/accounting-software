import { cva, type VariantProps } from "class-variance-authority";
import type { HTMLAttributes } from "react";

import { cn } from "../lib/cn";

const badge = cva("inline-flex items-center rounded-sm px-2 py-0.5 text-xs font-medium", {
  variants: {
    variant: {
      /** Reconciled / posted -- the ledger agrees with reality. */
      success: "bg-success/15 text-success",
      /** Needs review -- an AI suggestion or a low-confidence extraction, not an error. */
      warning: "bg-warning/15 text-warning",
      /** An actual error. Kept rare on purpose -- see design-tokens/tokens.css. */
      destructive: "bg-destructive/15 text-destructive",
      neutral: "bg-muted text-muted-foreground",
      /** AI-suggested / auto-categorized, distinct from a plain neutral badge. */
      accent: "bg-accent/15 text-accent-foreground",
    },
  },
  defaultVariants: { variant: "neutral" },
});

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement>, VariantProps<typeof badge> {}

export function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badge({ variant }), className)} {...props} />;
}
