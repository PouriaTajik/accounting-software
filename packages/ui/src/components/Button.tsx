import { cva, type VariantProps } from "class-variance-authority";
import { Button as AriaButton, type ButtonProps as AriaButtonProps } from "react-aria-components";

import { cn } from "../lib/cn";

/**
 * State styling uses RAC's own data-attribute convention
 * (data-[hovered]/[pressed]/[focus-visible]/[disabled]), not :hover/:active
 * pseudo-classes -- RAC drives these from real interaction state (pointer,
 * keyboard, touch), which is what makes it accessible in the first place.
 */
const button = cva(
  [
    "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium",
    "transition-colors outline-none",
    "data-[focus-visible]:ring-2 data-[focus-visible]:ring-ring data-[focus-visible]:ring-offset-2",
    "data-[disabled]:pointer-events-none data-[disabled]:opacity-50",
  ],
  {
    variants: {
      variant: {
        primary: "bg-primary text-primary-foreground data-[hovered]:bg-primary/90",
        secondary:
          "bg-muted text-foreground border border-border data-[hovered]:bg-muted/70",
        outline:
          "border border-border bg-background text-foreground data-[hovered]:bg-muted",
        ghost: "text-foreground data-[hovered]:bg-muted",
        destructive:
          "bg-destructive text-destructive-foreground data-[hovered]:bg-destructive/90",
      },
      size: {
        sm: "h-8 px-3 text-xs",
        md: "h-9 px-4",
        lg: "h-10 px-6",
        icon: "h-9 w-9 shrink-0",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);

export interface ButtonProps extends AriaButtonProps, VariantProps<typeof button> {}

export function Button({ className, variant, size, ...props }: ButtonProps) {
  return <AriaButton className={cn(button({ variant, size }), className as string)} {...props} />;
}
