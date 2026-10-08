import { cn } from "@/lib/utils";

/**
 * The green check beside a dog in good standing: every vaccine current.
 * Stricter than "cleared to groom", which only asks about the ones that stop a groom.
 */
export function GoodStanding({ show, className }: { show: boolean | undefined; className?: string }) {
  if (!show) return null;
  return (
    <span title="All vaccines current" aria-label="All vaccines current" role="img"
          className={cn("inline-grid size-4 shrink-0 place-items-center rounded-full bg-ok align-[-2px] text-[10px] font-bold leading-none text-white", className)}>
      ✓
    </span>
  );
}
