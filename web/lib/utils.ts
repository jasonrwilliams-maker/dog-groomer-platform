import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(`${iso}T12:00:00`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

/** "10:00 AM", from a time of day ("10:00:00") or a shop time ("2026-10-12T10:00:00"). */
export function formatTime(hms: string | null | undefined): string {
  if (!hms) return "";
  const [h, m] = hms.slice(hms.indexOf("T") + 1).split(":").map(Number);
  return new Date(2000, 0, 1, h, m).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
}

/** "1 hr 30 min", "45 min", "10 hr". */
export function duration(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return [h && `${h} hr`, m && `${m} min`].filter(Boolean).join(" ") || "0 min";
}

/** "Mon, Oct 12", from yyyy-mm-dd or a shop time. */
export function dayLabel(at: string): string {
  return new Date(`${at.slice(0, 10)}T12:00:00`).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}
