import { ChevronDown } from "lucide-react";
import {
  Button,
  Label,
  ListBox,
  ListBoxItem,
  Popover,
  Select as AriaSelect,
  SelectValue,
  type SelectProps as AriaSelectProps,
} from "react-aria-components";

import { cn } from "../lib/cn";

export interface SelectOption<T extends string = string> {
  value: T;
  label: string;
}

export interface SelectProps<T extends string = string>
  extends Omit<AriaSelectProps<{ value: T; label: string }>, "children"> {
  label?: string;
  placeholder?: string;
  options: SelectOption<T>[];
}

export function Select<T extends string = string>({
  label,
  placeholder = "Select…",
  options,
  className,
  ...props
}: SelectProps<T>) {
  return (
    <AriaSelect className={cn("flex flex-col gap-1.5", className as string)} {...props}>
      {label ? <Label className="text-sm font-medium text-foreground">{label}</Label> : null}
      <Button
        className={cn(
          "flex h-9 items-center justify-between gap-2 rounded-sm border border-input bg-background px-3 text-sm text-foreground",
          "outline-none data-[focus-visible]:ring-2 data-[focus-visible]:ring-ring data-[focus-visible]:ring-offset-2",
          "data-[disabled]:cursor-not-allowed data-[disabled]:opacity-50",
        )}
      >
        <SelectValue className="truncate data-[placeholder]:text-muted-foreground">
          {({ selectedText }) => selectedText || placeholder}
        </SelectValue>
        <ChevronDown className="h-4 w-4 shrink-0 text-muted-foreground" />
      </Button>
      <Popover className="w-[--trigger-width] rounded-md border border-border bg-card p-1 shadow-md">
        <ListBox className="flex flex-col gap-0.5 outline-none" items={options}>
          {(item) => (
            <ListBoxItem
              id={item.value}
              textValue={item.label}
              className={cn(
                "cursor-default rounded-sm px-2 py-1.5 text-sm text-foreground outline-none",
                "data-[focused]:bg-muted data-[selected]:bg-primary/10 data-[selected]:font-medium",
              )}
            >
              {item.label}
            </ListBoxItem>
          )}
        </ListBox>
      </Popover>
    </AriaSelect>
  );
}
