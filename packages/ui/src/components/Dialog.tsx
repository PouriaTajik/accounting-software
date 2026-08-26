import { X } from "lucide-react";
import {
  Dialog as AriaDialog,
  DialogTrigger,
  Heading,
  Modal,
  ModalOverlay,
  type DialogProps as AriaDialogProps,
} from "react-aria-components";

import { cn } from "../lib/cn";

export { DialogTrigger };

export interface DialogProps extends AriaDialogProps {
  title: string;
  description?: string;
}

export function Dialog({ title, description, className, children, ...props }: DialogProps) {
  return (
    <ModalOverlay
      className={cn(
        "fixed inset-0 z-50 flex items-center justify-center bg-black/40",
        "data-[entering]:animate-in data-[entering]:fade-in data-[exiting]:animate-out data-[exiting]:fade-out",
      )}
      isDismissable
    >
      <Modal
        className={cn(
          "w-full max-w-md rounded-lg border border-border bg-card p-6 shadow-lg",
          "data-[entering]:animate-in data-[entering]:zoom-in-95 data-[exiting]:animate-out data-[exiting]:zoom-out-95",
        )}
      >
        <AriaDialog className={cn("outline-none", className as string)} {...props}>
          {(renderProps) => (
            <>
              <div className="mb-4 flex items-start justify-between gap-4">
                <div className="flex flex-col gap-1">
                  <Heading slot="title" className="text-base font-semibold text-foreground">
                    {title}
                  </Heading>
                  {description ? (
                    <p className="text-sm text-muted-foreground">{description}</p>
                  ) : null}
                </div>
                <button
                  type="button"
                  onClick={renderProps.close}
                  aria-label="Close"
                  className="rounded-sm p-1 text-muted-foreground outline-none data-[focus-visible]:ring-2 data-[focus-visible]:ring-ring hover:bg-muted"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>
              {typeof children === "function" ? children(renderProps) : children}
            </>
          )}
        </AriaDialog>
      </Modal>
    </ModalOverlay>
  );
}
