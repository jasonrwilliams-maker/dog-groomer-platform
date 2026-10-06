import { cn } from "@/lib/utils";

// A placeholder until the shop has its own logo. To swap it, put the file in
// web/public/ (say logo.png) and return <img src="/logo.png" alt={SHOP_NAME} />
// here; every screen uses this one component.
export const SHOP_NAME = "Paws & Polish";

// The shop's colours: an amber paw (the spaniel's eyes) on coat mauve. On a
// mauve header bar, `onBrand` turns the badge dark so it still stands out.
export function Logo({ size = "sm", onBrand = false, className }: {
  size?: "sm" | "lg"; onBrand?: boolean; className?: string;
}) {
  const big = size === "lg";
  return (
    <div className={cn("flex items-center gap-3", big && "flex-col gap-4 text-center", className)}>
      <span
        aria-hidden
        className={cn(
          "grid shrink-0 place-items-center rounded-full text-accent",
          onBrand ? "bg-foreground" : "bg-primary",
          big ? "size-24 shadow-lg ring-4 ring-accent/40" : "size-10",
        )}
      >
        <svg viewBox="0 0 24 24" className={big ? "size-12" : "size-5"} fill="currentColor">
          <ellipse cx="6" cy="9.5" rx="2" ry="2.6" />
          <ellipse cx="10" cy="5.5" rx="2" ry="2.6" />
          <ellipse cx="14" cy="5.5" rx="2" ry="2.6" />
          <ellipse cx="18" cy="9.5" rx="2" ry="2.6" />
          <path d="M12 11c-3 0-6 4.5-6 7 0 1.7 1.3 2.5 3 2.5 1.3 0 2-.6 3-.6s1.7.6 3 .6c1.7 0 3-.8 3-2.5 0-2.5-3-7-6-7Z" />
        </svg>
      </span>
      <span>
        <span className={cn("block font-semibold tracking-tight", big ? "text-3xl" : "text-lg leading-tight")}>
          {SHOP_NAME}
        </span>
        <span className={cn("block font-medium uppercase tracking-[0.2em]", onBrand ? "text-accent" : "text-primary",
                             big ? "text-sm" : "text-[0.65rem]")}>Grooming</span>
      </span>
    </div>
  );
}
