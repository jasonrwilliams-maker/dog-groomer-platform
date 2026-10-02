"use client";

import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import type { DogSummary } from "@/lib/api";
import { cn } from "@/lib/utils";

export function DogList({
  query, onQuery, dogs, selectedId, onSelect, loading,
}: {
  query: string;
  onQuery: (q: string) => void;
  dogs: DogSummary[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  loading: boolean;
}) {
  return (
    <div className="flex flex-col gap-3">
      <Input
        autoFocus
        value={query}
        onChange={(e) => onQuery(e.target.value)}
        placeholder="Dog or owner name"
        aria-label="Find a dog by its name or its owner's name"
      />
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
              <span className="min-w-0">
                <span className="block font-medium">{d.name}</span>
                <span className="block truncate text-sm text-muted-foreground">
                  {d.breed ?? "Breed not recorded"} · {d.owner}
                </span>
                {d.attention && (
                  <span className={cn("block truncate text-sm", d.blocks_service ? "text-stop" : "text-warn")}>
                    {d.attention}
                  </span>
                )}
              </span>
              <Badge tone={d.blocks_service ? "stop" : "ok"}>
                {d.blocks_service ? "Can't groom" : "Cleared"}
              </Badge>
            </button>
          </li>
        ))}
        {!loading && dogs.length === 0 && (
          <li className="px-3 py-6 text-sm text-muted-foreground">No dog or owner by that name.</li>
        )}
      </ul>
    </div>
  );
}
