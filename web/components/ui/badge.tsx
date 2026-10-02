import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

// Three colours, each a meaning for today's groom — not a colour per state.
const badgeVariants = cva("inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium whitespace-nowrap", {
  variants: {
    tone: {
      ok: "bg-ok-soft text-ok",
      warn: "bg-warn-soft text-warn",
      stop: "bg-stop-soft text-stop",
      neutral: "bg-muted text-muted-foreground",
    },
  },
  defaultVariants: { tone: "neutral" },
});

export function Badge({ className, tone, ...props }: React.HTMLAttributes<HTMLSpanElement> & VariantProps<typeof badgeVariants>) {
  return <span className={cn(badgeVariants({ tone }), className)} {...props} />;
}

export type Tone = NonNullable<VariantProps<typeof badgeVariants>["tone"]>;

/** Red if it stops today's groom; green if it is in order; amber otherwise. */
export function toneFor(state: string, blocksService: boolean): Tone {
  if (blocksService) return "stop";
  if (state === "current" || state === "not_yet_due") return "ok";
  return "warn";
}
