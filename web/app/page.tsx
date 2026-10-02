"use client";

import { useCallback, useEffect, useState } from "react";
import { DogCard } from "@/components/check-in/dog-card";
import { DogList } from "@/components/check-in/dog-list";
import { api, type CheckInCard, type DogSummary, type Groomer } from "@/lib/api";

export default function CheckInPage() {
  const [groomers, setGroomers] = useState<Groomer[]>([]);
  const [groomerId, setGroomerId] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [dogs, setDogs] = useState<DogSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [card, setCard] = useState<CheckInCard | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  useEffect(() => {
    api.groomers().then(setGroomers).catch((e) => setProblem(String(e.message ?? e)));
  }, []);

  // Search as you type, a beat after the last keystroke.
  useEffect(() => {
    setLoading(true);
    const t = setTimeout(() => {
      api.findDogs(query)
        .then((d) => { setDogs(d); setProblem(null); })
        .catch((e) => setProblem(String(e.message ?? e)))
        .finally(() => setLoading(false));
    }, 200);
    return () => clearTimeout(t);
  }, [query]);

  const loadCard = useCallback((id: string) => {
    api.card(id).then(setCard).catch((e) => setProblem(String(e.message ?? e)));
  }, []);

  useEffect(() => {
    if (selectedId) loadCard(selectedId);
    else setCard(null);
  }, [selectedId, loadCard]);

  return (
    <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:px-8">
      <header className="flex flex-wrap items-end justify-between gap-4 border-b border-border pb-4">
        <div>
          <p className="text-sm font-medium text-muted-foreground">Paws &amp; Polish Grooming</p>
          <h1 className="text-2xl font-semibold tracking-tight">Check-in</h1>
        </div>
        <label className="flex items-center gap-2 text-sm">
          <span className="text-muted-foreground">Grooming today:</span>
          <select
            className="h-10 rounded-[var(--radius)] border border-border bg-card px-3"
            value={groomerId ?? ""}
            onChange={(e) => setGroomerId(e.target.value || null)}
          >
            <option value="">Choose…</option>
            {groomers.map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}
          </select>
        </label>
      </header>

      {problem && (
        <p role="alert" className="rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">
          Can&apos;t reach the shop&apos;s records right now: {problem}
        </p>
      )}

      <div className="grid gap-6 md:grid-cols-[minmax(0,20rem)_minmax(0,1fr)]">
        <aside>
          <DogList query={query} onQuery={setQuery} dogs={dogs} selectedId={selectedId}
                   onSelect={setSelectedId} loading={loading} />
        </aside>
        <main>
          {card ? (
            <DogCard key={card.dog.id} card={card} groomerId={groomerId}
                     onChanged={() => { loadCard(card.dog.id); api.findDogs(query).then(setDogs); }} />
          ) : (
            <div className="flex h-64 items-center justify-center rounded-[var(--radius)] border border-dashed border-border text-muted-foreground">
              Find a dog to see whether they&apos;re cleared for today&apos;s groom.
            </div>
          )}
        </main>
      </div>
    </div>
  );
}
