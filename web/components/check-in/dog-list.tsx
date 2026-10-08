"use client";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import type { DogSummary, SearchBy } from "@/lib/api";
import { cn } from "@/lib/utils";
import { GoodStanding } from "@/components/ui/good-standing";
import { DogPhoto } from "@/components/ui/dog-photo";

const MODES: { by: SearchBy; label: string; placeholder: string }[] = [
  { by: "any", label: "Both", placeholder: "Dog or owner name" },
  { by: "dog", label: "Dog", placeholder: "Dog's name" },
  { by: "owner", label: "Owner", placeholder: "Owner's name" },
];

export function DogList({
  query, onQuery, by, onBy, dogs, selectedId, onSelect, loading, onNewClient,
}: {
  query: string;
  onQuery: (q: string) => void;
  by: SearchBy;
  onBy: (by: SearchBy) => void;
  dogs: DogSummary[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  loading: boolean;
  onNewClient: () => void;
}) {
  const mode = MODES.find((m) => m.by === by)!;
  return (
    <div className="flex flex-col gap-3">
      <div role="radiogroup" aria-label="Search by" className="flex rounded-[var(--radius)] bg-muted p-1 text-sm">
        {MODES.map((m) => (
          <button
            key={m.by}
            role="radio"
            aria-checked={m.by === by}
            onClick={() => onBy(m.by)}
            className={cn(
              "flex-1 rounded-[calc(var(--radius)-0.2rem)] px-3 py-1.5 font-medium transition-colors",
              m.by === by ? "bg-card shadow-sm" : "text-muted-foreground hover:text-foreground",
            )}
          >
            {m.label}
          </button>
        ))}
      </div>
      <Input
        autoFocus
        type="search"
        value={query}
        onChange={(e) => onQuery(e.target.value)}
        placeholder={mode.placeholder}
        aria-label={`Search by ${mode.placeholder.toLowerCase()}`}
      />
      <div className="flex items-center justify-between gap-2 px-1">
        <p className="text-xs text-muted-foreground" aria-live="polite">
          {loading ? "Searching…" : query ? `${dogs.length} found` : `All dogs · ${dogs.length}`}
        </p>
        <Button variant="ghost" size="sm" className="text-primary" onClick={onNewClient}>+ New client</Button>
      </div>
      <ul className="flex flex-col gap-1.5" aria-busy={loading}>
        {dogs.map((d) => (
          <li key={d.id}>
            <button
              onClick={() => onSelect(d.id)}
              className={cn(
                "flex w-full items-center justify-between gap-3 rounded-[var(--radius)] border px-3 py-2.5 text-left transition-colors",
                d.id === selectedId ? "border-primary bg-card shadow-sm" : "border-transparent hover:bg-card",
              )}
            >
              <span className="flex min-w-0 items-center gap-3">
                <DogPhoto dogId={d.id} photo={d.photo} name={d.name} />
                <span className="min-w-0">
                  <span className="flex items-center gap-1.5 font-medium">{d.name}<GoodStanding show={d.in_good_standing} /></span>
                  <span className="block truncate text-sm text-muted-foreground">{d.owner}</span>
                </span>
              </span>
              <Badge tone={d.blocks_service ? "stop" : "ok"}>
                {d.blocks_service ? "Can't groom" : "Cleared"}
              </Badge>
            </button>
          </li>
        ))}
        {!loading && dogs.length === 0 && (
          <li className="flex flex-col items-start gap-3 px-3 py-6 text-sm text-muted-foreground">
            {by === "dog" ? "No dog by that name." : by === "owner" ? "No owner by that name." : "No dog or owner by that name."}
            {query && <Button onClick={onNewClient}>Add as a new client</Button>}
          </li>
        )}
      </ul>
    </div>
  );
}
