"use client";

import { useEffect, useState } from "react";
import { demoLog, demoShop, demoStatus, onDemoLog, startDemoDatabase } from "@/lib/demo/backend";
import { cn } from "@/lib/utils";

const SOURCE = "https://github.com/jasonrwilliams-maker/dog-groomer-platform";

// Where to look first: each one runs into a rule the database enforces.
const TRY = [
  "Jaddi: his rabies has expired, so the database won't clear him for a groom.",
  "New client: type in a shot with no expiry date. No expiry, no record.",
  "Book Olive with someone other than her usual groomer: it asks why.",
  "Start Pepper's groom, then record the haircut: shave-down a pelted coat.",
];

/**
 * The browser demo's banner: what this is, while the database starts; then
 * what to try, and every change the database accepted or refused.
 */
export function DemoBanner() {
  const [, tick] = useState(0);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const off = onDemoLog(() => tick((n) => n + 1));
    startDemoDatabase().catch(() => tick((n) => n + 1));
    return off;
  }, []);

  const status = demoStatus();
  const shop = demoShop();
  const entries = demoLog();
  const ready = status === "ready";

  return (
    <div className="border-b border-todo-border bg-todo text-sm">
      <div className="mx-auto flex max-w-6xl flex-col gap-2 px-4 py-3 md:px-8">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p>
            <span className="font-semibold">Live demo.</span>{" "}
            {ready && shop
              ? <>The shop&apos;s real database is running in your browser: Postgres, with the project&apos;s own {shop.tables} tables and {shop.functions} functions. Every rule you meet is the database&apos;s own. Nothing leaves this tab; reload to start fresh.</>
              : <span className="text-muted-foreground">{status}</span>}
          </p>
          <div className="flex gap-2">
            {ready && (
              <button onClick={() => setOpen((o) => !o)}
                      className="h-8 rounded-[var(--radius)] border border-todo-border bg-card px-3 font-medium hover:bg-todo-hover">
                {open ? "Hide" : "What to try · what the database did"}{entries.length > 0 && !open ? ` (${entries.length})` : ""}
              </button>
            )}
            <a href={SOURCE} target="_blank" rel="noreferrer"
               className="inline-flex h-8 items-center rounded-[var(--radius)] border border-todo-border bg-card px-3 font-medium hover:bg-todo-hover">
              Source ↗
            </a>
          </div>
        </div>
        {open && (
          <div className="grid gap-4 border-t border-todo-border pt-2 md:grid-cols-2">
            <section>
              <h3 className="font-semibold">Try</h3>
              <ul className="mt-1 list-disc pl-5 text-muted-foreground">
                {TRY.map((t) => <li key={t}>{t}</li>)}
              </ul>
            </section>
            <section>
              <h3 className="font-semibold">What the database did</h3>
              {entries.length === 0 ? (
                <p className="mt-1 text-muted-foreground">Nothing yet. Every change you make is listed here: the function it called, and whether the database said yes.</p>
              ) : (
                <ul className="mt-1 flex max-h-56 flex-col gap-1 overflow-y-auto">
                  {entries.map((e, i) => (
                    <li key={entries.length - i} className="flex gap-2">
                      <span className={cn("shrink-0 font-semibold", e.outcome === "ok" ? "text-ok" : "text-stop")}>
                        {e.outcome === "ok" ? "✓" : "✗"}
                      </span>
                      <span>
                        <code className="text-xs">{e.calls.join(", ") || "change"}</code>
                        {e.detail && <span className="block text-stop">{e.detail}</span>}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          </div>
        )}
      </div>
    </div>
  );
}
