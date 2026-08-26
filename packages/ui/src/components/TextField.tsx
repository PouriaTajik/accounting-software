import {
  FieldError,
  Input,
  Label,
  Text,
  TextField as AriaTextField,
  type TextFieldProps as AriaTextFieldProps,
} from "react-aria-components";

import { cn } from "../lib/cn";

export interface TextFieldProps extends AriaTextFieldProps {
  label?: string;
  description?: string;
  placeholder?: string;
  /** Ledger amounts, dates, codes -- anything that must never mirror in RTL. */
  tabularFigure?: boolean;
}

export function TextField({
  label,
  description,
  placeholder,
  tabularFigure,
  className,
  ...props
}: TextFieldProps) {
  return (
    <AriaTextField className={cn("flex flex-col gap-1.5", className as string)} {...props}>
      {label ? (
        <Label className="text-sm font-medium text-foreground">{label}</Label>
      ) : null}
      <Input
        placeholder={placeholder}
        className={cn(
          "h-9 rounded-sm border border-input bg-background px-3 text-sm text-foreground",
          "outline-none data-[focused]:ring-2 data-[focused]:ring-ring data-[focused]:ring-offset-2",
          "data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50",
          tabularFigure && "tabular-figure",
        )}
      />
      {description ? (
        <Text slot="description" className="text-xs text-muted-foreground">
          {description}
        </Text>
      ) : null}
      <FieldError className="text-xs text-destructive" />
    </AriaTextField>
  );
}
