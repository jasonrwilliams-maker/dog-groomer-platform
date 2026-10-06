"use client";

import { Logo } from "@/components/brand/logo";
import type { Groomer } from "@/lib/api";

// The first thing anyone sees: the shop, and one button per person. Picking a
// name is not a password — it says who is grooming, and whether to offer the
// manager's Admin view.
export function Welcome({ groomers, onPick }: { groomers: Groomer[]; onPick: (g: Groomer) => void }) {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-10 bg-[radial-gradient(ellipse_at_top,var(--card),var(--background)_60%)] px-4 py-12">
      <Logo size="lg" />
      <div className="flex w-full max-w-md flex-col gap-4">
        <h1 className="text-center text-xl font-medium text-muted-foreground">Who&apos;s grooming?</h1>
        <ul className="grid gap-3 sm:grid-cols-2">
          {groomers.map((g) => (
            <li key={g.id}>
              <button
                onClick={() => onPick(g)}
                className="flex h-20 w-full items-center gap-4 rounded-[var(--radius)] border border-border bg-card px-5 text-xl font-semibold shadow-sm transition hover:-translate-y-0.5 hover:border-primary hover:shadow-md"
              >
                <span aria-hidden className="grid size-11 place-items-center rounded-full bg-accent text-lg text-accent-foreground">
                  {g.name.slice(0, 1)}
                </span>
                {g.name}
              </button>
            </li>
          ))}
        </ul>
        {groomers.length === 0 && (
          <p className="text-center text-sm text-muted-foreground">Loading the staff list…</p>
        )}
      </div>
    </div>
  );
}
