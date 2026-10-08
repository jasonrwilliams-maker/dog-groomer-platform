"use client";

import { useCallback, useEffect, useState } from "react";
import { Logo } from "@/components/brand/logo";
import { AdminView } from "@/components/check-in/admin-view";
import { CalendarView, type CalendarDog } from "@/components/calendar/calendar-view";
import { DogCard } from "@/components/check-in/dog-card";
import { DogList } from "@/components/check-in/dog-list";
import { WalkInForm, type WalkInFor } from "@/components/check-in/walk-in-form";
import { ViewerProvider } from "@/lib/viewer";
import { Welcome } from "@/components/check-in/welcome";
import { Button } from "@/components/ui/button";
import { api, type CheckInCard, type DogSummary, type Groomer, type SearchBy } from "@/lib/api";
import { cn } from "@/lib/utils";

// Who is at the counter survives a page reload on this device, until someone
// taps "Switch". Storage can be unavailable (private windows); the screen
// then simply asks again.
const WHO = "check-in.groomer";
function remembered(): string | null {
  try { return localStorage.getItem(WHO); } catch { return null; }
}
function remember(id: string | null) {
  try { if (id) localStorage.setItem(WHO, id); else localStorage.removeItem(WHO); } catch { /* ask again next time */ }
}

type View = "check-in" | "calendar" | "admin";
const VIEW_NAME: Record<View, string> = { "check-in": "Check-in", calendar: "Calendar", admin: "Admin" };

export default function CheckInPage() {
  const [groomers, setGroomers] = useState<Groomer[]>([]);
  const [me, setMe] = useState<Groomer | null>(null);
  const [ready, setReady] = useState(false);
  const [view, setView] = useState<View>("check-in");
  // Which Admin list is open (null: the overview), kept here so it is still
  // open when the manager comes back from a dog.
  const [adminList, setAdminList] = useState<string | null>(null);
  // The one dog the calendar is narrowed to, if any.
  const [calendarDog, setCalendarDog] = useState<CalendarDog | null>(null);
  const [query, setQuery] = useState("");
  const [by, setBy] = useState<SearchBy>("any");
  const [dogs, setDogs] = useState<DogSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [card, setCard] = useState<CheckInCard | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [walkIn, setWalkIn] = useState<WalkInFor | null>(null);

  useEffect(() => {
    api.groomers()
      .then((gs) => { setGroomers(gs); setMe(gs.find((g) => g.id === remembered()) ?? null); })
      .catch((e) => setProblem(String(e.message ?? e)))
      .finally(() => setReady(true));
  }, []);

  // Search as you type, a beat after the last keystroke.
  useEffect(() => {
    if (!me) return;
    setLoading(true);
    const t = setTimeout(() => {
      api.findDogs(query, by)
        .then((d) => { setDogs(d); setProblem(null); })
        .catch((e) => setProblem(String(e.message ?? e)))
        .finally(() => setLoading(false));
    }, 200);
    return () => clearTimeout(t);
  }, [me, query, by]);

  const loadCard = useCallback((id: string) => {
    api.card(id).then(setCard).catch((e) => setProblem(String(e.message ?? e)));
  }, []);

  useEffect(() => {
    if (selectedId) loadCard(selectedId);
    else setCard(null);
  }, [selectedId, loadCard]);

  function signIn(g: Groomer) { remember(g.id); setMe(g); setView("check-in"); }
  function signOut() { remember(null); setMe(null); setSelectedId(null); setWalkIn(null); setQuery(""); setAdminList(null); setCalendarDog(null); setView("check-in"); }
  function select(id: string | null) { setWalkIn(null); setSelectedId(id); }
  // A search that found no one is usually the new client's name: carry it over.
  function newClient() {
    setSelectedId(null);
    setWalkIn({ prefill: by === "dog" ? { dog: query } : by === "owner" ? { owner: query } : {} });
  }
  function walkInDone(dogId: string) {
    setWalkIn(null); setQuery(""); setSelectedId(dogId);
    api.findDogs("", by).then(setDogs);
  }

  const manager = me?.role === "manager";
  const trouble = problem && (
    <p role="alert" className="mx-auto max-w-md rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">
      Can&apos;t reach the shop&apos;s records right now: {problem}
    </p>
  );

  if (!ready) return null;
  if (!me) return <>{trouble}<Welcome groomers={groomers} onPick={signIn} /></>;

  return (
    <div className="min-h-screen">
      <header className="bg-primary text-primary-foreground shadow-md">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-4 px-4 py-3 md:px-8">
          <Logo onBrand />
          <div className="flex flex-wrap items-center gap-3">
            <nav className="flex rounded-[var(--radius)] bg-primary-hover p-1 text-sm" aria-label="Screens">
                {((manager ? ["check-in", "calendar", "admin"] : ["check-in", "calendar"]) as View[]).map((v) => (
                  <button
                    key={v}
                    // Admin again, from inside one of its lists: back to the overview.
                    onClick={() => { if (v === "admin" && view === "admin") setAdminList(null); setView(v); }}
                    aria-current={view === v ? "page" : undefined}
                    className={cn(
                      "rounded-[calc(var(--radius)-0.2rem)] px-3 py-1.5 font-medium transition-colors",
                      view === v ? "bg-accent text-accent-foreground shadow-sm" : "text-primary-foreground/80 hover:text-primary-foreground",
                    )}
                  >
                    {VIEW_NAME[v]}
                  </button>
                ))}
            </nav>
            <span className="text-sm">
              <span className="text-primary-foreground/70">Grooming: </span>
              <span className="font-medium">{me.name}</span>
            </span>
            <Button variant="ghost" size="sm" className="border border-primary-foreground/30 hover:bg-primary-hover"
                    onClick={signOut}>Switch</Button>
          </div>
        </div>
      </header>

      <ViewerProvider value={manager}>
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-6 md:px-8">
        {trouble}

        {view === "calendar" ? (
          <CalendarView dog={calendarDog} onDog={setCalendarDog}
                        onOpenDog={(id) => { select(id); setView("check-in"); }} />
        ) : view === "admin" && manager ? (
          <AdminView groomerId={me.id} onOpenDog={(id) => { select(id); setView("check-in"); }}
                     list={adminList} onList={setAdminList} />
        ) : (
          <div className="grid gap-6 md:grid-cols-[minmax(0,20rem)_minmax(0,1fr)]">
            {/* On a phone the list and the card take turns; side by side from tablet up. */}
            <aside className={cn((selectedId || walkIn) && "hidden md:block")}>
              <DogList query={query} onQuery={setQuery} by={by} onBy={setBy} dogs={dogs}
                       selectedId={selectedId} onSelect={select} loading={loading} onNewClient={newClient} />
            </aside>
            <main className={cn(!selectedId && !walkIn && "hidden md:block")}>
              <Button variant="ghost" size="sm" className="mb-3 md:hidden" onClick={() => select(null)}>
                ← All dogs
              </Button>
              {walkIn ? (
                <WalkInForm key={JSON.stringify(walkIn)} walkIn={walkIn} groomerId={me.id}
                            onDone={walkInDone} onCancel={() => setWalkIn(null)} />
              ) : card ? (
                <DogCard key={card.dog.id} card={card} groomerId={me.id} detailsOpen={manager}
                         onCalendar={() => { setCalendarDog({ id: card.dog.id, name: card.dog.name }); setView("calendar"); }}
                         onAddDog={(ownerId, ownerName) => { setSelectedId(null); setWalkIn({ ownerId, ownerName }); }}
                         onChanged={() => { loadCard(card.dog.id); api.findDogs(query, by).then(setDogs); }} />
              ) : (
                <div className="flex h-64 items-center justify-center rounded-[var(--radius)] border border-dashed border-border px-6 text-center text-muted-foreground">
                  Pick a dog to see whether they&apos;re cleared for today&apos;s groom.
                </div>
              )}
            </main>
          </div>
        )}
      </div>
      </ViewerProvider>
    </div>
  );
}
