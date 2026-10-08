"use client";

import { useEffect, useState } from "react";
import { Input } from "@/components/ui/input";
import { api, type DogSummary } from "@/lib/api";
import { cn } from "@/lib/utils";
import { GoodStanding } from "@/components/ui/good-standing";

/**
 * Pick a dog: a drop-down of every dog and its owner, which typing narrows by
 * either name. Arrow keys and Enter work too.
 */
export function DogPicker({ id, label, onPick }: { id: string; label: string; onPick: (dog: DogSummary) => void }) {
  const [all, setAll] = useState<DogSummary[]>([]);
  const [q, setQ] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);

  useEffect(() => {
    api.findDogs("").then((d) => setAll([...d].sort((a, b) => a.name.localeCompare(b.name)))).catch(() => setAll([]));
  }, []);

  const needle = q.trim().toLowerCase();
  const hits = needle
    ? all.filter((d) => d.name.toLowerCase().includes(needle) || d.owner.toLowerCase().includes(needle))
    : all;

  function pick(d: DogSummary) {
    setQ(""); setOpen(false); setActive(0);
    onPick(d);
  }

  function onKey(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") { e.preventDefault(); setOpen(true); setActive((a) => Math.min(a + 1, hits.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
    else if (e.key === "Enter" && open && hits[active]) { e.preventDefault(); pick(hits[active]); }
    else if (e.key === "Escape") setOpen(false);
  }

  return (
    <div>
      <label htmlFor={id} className="mb-1 block text-sm font-medium">{label}</label>
      <div className="relative">
        <Input id={id} role="combobox" aria-expanded={open} aria-controls={`${id}-list`}
               aria-activedescendant={open && hits[active] ? `${id}-${hits[active].id}` : undefined}
               autoComplete="off" placeholder="Pick or type a name" className="pr-9" value={q}
               onChange={(e) => { setQ(e.target.value); setOpen(true); setActive(0); }}
               onFocus={() => setOpen(true)}
               // A beat, so a click on the list lands before it closes.
               onBlur={() => setTimeout(() => setOpen(false), 150)}
               onKeyDown={onKey} />
        <span aria-hidden className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground">▾</span>
        {open && (
          <ul id={`${id}-list`} role="listbox"
              className="absolute z-20 mt-1 max-h-72 w-full overflow-auto rounded-[var(--radius)] border border-border bg-card py-1 shadow-lg">
            {hits.length === 0 ? (
              <li className="px-3 py-2 text-sm text-muted-foreground">No dog or owner by that name.</li>
            ) : hits.map((d, i) => (
              <li key={d.id} id={`${id}-${d.id}`} role="option" aria-selected={i === active}
                  onMouseDown={(e) => { e.preventDefault(); pick(d); }}
                  onMouseEnter={() => setActive(i)}
                  className={cn("cursor-pointer px-3 py-2 text-sm", i === active && "bg-muted")}>
                <span className="font-medium">{d.name}</span> <GoodStanding show={d.in_good_standing} />
                <span className="text-muted-foreground"> · {d.owner}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
