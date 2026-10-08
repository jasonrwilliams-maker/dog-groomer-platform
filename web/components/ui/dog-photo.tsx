import { dogPhotoUrl } from "@/lib/api";
import { cn } from "@/lib/utils";

const SIZE = { sm: "size-10", md: "size-16", lg: "size-28" } as const;

/**
 * The dog's face: its profile photo, or a drawn placeholder in the shop's
 * colours until someone adds one. Lists use the small square; the card and
 * the booking form the larger one.
 */
export function DogPhoto({ dogId, photo, name, size = "sm", className }: {
  dogId: string; photo: string | null | undefined; name: string;
  size?: keyof typeof SIZE; className?: string;
}) {
  const box = cn("shrink-0 overflow-hidden rounded-full border border-border bg-muted", SIZE[size], className);
  if (photo) {
    return (
      // eslint-disable-next-line @next/next/no-img-element -- a private photo from this machine, not a static asset
      <img src={dogPhotoUrl(dogId, photo, size === "lg" ? "display" : "thumb")} alt={`Photo of ${name}`}
           className={cn(box, "object-cover")} loading="lazy" />
    );
  }
  return (
    <span role="img" aria-label={`No photo of ${name} yet`} className={cn(box, "grid place-items-center")}>
      <PlaceholderDog />
    </span>
  );
}

/** A friendly dog face: floppy ears, a muzzle and a nose. Not any one breed. */
function PlaceholderDog() {
  return (
    <svg viewBox="0 0 64 64" className="size-[78%]" aria-hidden>
      {/* Ears */}
      <path d="M14 18c-6 2-9 12-7 22 1 5 6 6 9 2l4-14z" fill="var(--primary)" />
      <path d="M50 18c6 2 9 12 7 22-1 5-6 6-9 2l-4-14z" fill="var(--primary)" />
      {/* Head */}
      <ellipse cx="32" cy="32" rx="17" ry="18" fill="var(--muted-foreground)" opacity="0.35" />
      <ellipse cx="32" cy="32" rx="17" ry="18" fill="none" stroke="var(--primary)" strokeWidth="1.5" opacity="0.5" />
      {/* Muzzle */}
      <ellipse cx="32" cy="42" rx="9" ry="7" fill="var(--card)" />
      {/* Eyes, with the logo's amber */}
      <circle cx="25" cy="29" r="2.6" fill="var(--foreground)" />
      <circle cx="39" cy="29" r="2.6" fill="var(--foreground)" />
      <circle cx="25.8" cy="28.2" r="0.8" fill="var(--accent)" />
      <circle cx="39.8" cy="28.2" r="0.8" fill="var(--accent)" />
      {/* Nose and mouth */}
      <ellipse cx="32" cy="38.5" rx="3.2" ry="2.3" fill="var(--foreground)" />
      <path d="M32 41v2.5M32 43.5c-1.5 1.6-3.5 1.6-4.5.6M32 43.5c1.5 1.6 3.5 1.6 4.5.6" stroke="var(--foreground)"
            strokeWidth="1.1" fill="none" strokeLinecap="round" />
    </svg>
  );
}
