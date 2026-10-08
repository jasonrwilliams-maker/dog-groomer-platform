"use client";

import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { api, type CalendarEvent, type DogSummary } from "@/lib/api";
import { cn, formatDate } from "@/lib/utils";

/** One dog the calendar is showing on its own. */
export type CalendarDog = { id: string; name: string };

type Kind = "groom" | "expiry";

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// Dates stay as the shop's own calendar days (yyyy-mm-dd), never shifted by
// a time zone.
const iso = (d: Date) => d.toLocaleDateString("en-CA");
const parse = (s: string) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
const firstOfMonth = (d: Date) => new Date(d.getFullYear(), d.getMonth(), 1);

/** The six weeks a month is drawn on, Sunday first. */
function gridDays(month: Date): Date[] {
  const start = new Date(month);
  start.setDate(1 - month.getDay());
  return Array.from({ length: 42 }, (_, i) => new Date(start.getFullYear(), start.getMonth(), start.getDate() + i));
}

/** How one thing reads, and its colour: a groom in the shop's mauve, an expiry by how much it matters. */
function look(e: CalendarEvent, today: string) {
  if (e.kind === "groom") {
    return { tone: "bg-primary text-primary-foreground", short: e.dog,
             long: e.in_progress ? `being groomed by ${e.groomer}` : `groomed by ${e.groomer}` };
  }
  const past = e.on_date < today;
  return { tone: e.stops_grooms ? "bg-stop-soft text-stop" : "bg-warn-soft text-warn",
           short: `${e.dog} · ${e.vaccine}`,
           long: `${e.vaccine} ${past ? "expired" : "expires"}` };
}

/**
 * A month of the shop's dates: grooms that happened, and when each dog's
 * vaccines run out. Filter by what kind, or narrow it to one dog and jump
 * between that dog's dates.
 */
export function CalendarView({ dog, onDog, onOpenDog }: {
  dog: CalendarDog | null; onDog: (dog: CalendarDog | null) => void; onOpenDog: (dogId: string) => void;
}) {
  const today = iso(new Date());
  const [month, setMonth] = useState(() => firstOfMonth(new Date()));
  const [day, setDay] = useState<string | null>(today);
  const [shown, setShown] = useState<Record<Kind, boolean>>({ groom: true, expiry: true });
  const [monthEvents, setMonthEvents] = useState<CalendarEvent[]>([]);
  const [dogEvents, setDogEvents] = useState<CalendarEvent[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  const days = useMemo(() => gridDays(month), [month]);
  const span = { start: iso(days[0]), end: iso(days[days.length - 1]) };

  // Opened from further down a dog's card: start at the top.
  useEffect(() => { window.scrollTo({ top: 0 }); }, []);

  // The month on screen, for every dog.
  useEffect(() => {
    if (dog) return;
    api.calendar(span).then(setMonthEvents).catch((e) => setProblem(String(e.message ?? e)));
  }, [dog, span.start, span.end]);

  // One dog: its whole history, and straight to its latest groom (or, with
  // none, its next expiry).
  useEffect(() => {
    if (!dog) { setDogEvents(null); return; }
    api.calendar({ dogId: dog.id }).then((evs) => {
      setDogEvents(evs);
      const lastGroom = [...evs].reverse().find((e) => e.kind === "groom" && e.on_date <= today);
      const next = evs.find((e) => e.on_date >= today) ?? evs[evs.length - 1];
      const go = lastGroom ?? next;
      if (go) jumpTo(go.on_date);
    }).catch((e) => setProblem(String(e.message ?? e)));
  }, [dog?.id]);

  function jumpTo(date: string) {
    setMonth(firstOfMonth(parse(date)));
    setDay(date);
  }
  const step = (by: number) => setMonth(new Date(month.getFullYear(), month.getMonth() + by, 1));

  const events = (dogEvents ?? monthEvents).filter((e) => shown[e.kind]);
  const byDay = useMemo(() => {
    const m = new Map<string, CalendarEvent[]>();
    for (const e of events) m.set(e.on_date, [...(m.get(e.on_date) ?? []), e]);
    return m;
  }, [events]);
  const onDay = day ? byDay.get(day) ?? [] : [];

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <Card>
        <CardHeader className="gap-3">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-2">
              <Button variant="outline" size="sm" aria-label="Previous month" onClick={() => step(-1)}>‹</Button>
              <CardTitle className="min-w-40 text-center">
                {month.toLocaleDateString("en-US", { month: "long", year: "numeric" })}
              </CardTitle>
              <Button variant="outline" size="sm" aria-label="Next month" onClick={() => step(1)}>›</Button>
              <Button variant="outline" size="sm" onClick={() => jumpTo(today)}>Today</Button>
            </div>
            {/* What to show. */}
            <div className="flex flex-wrap gap-2">
              {([["groom", "Grooms"], ["expiry", "Vaccine expiries"]] as const).map(([k, label]) => (
                <Button key={k} variant="outline" size="sm" aria-pressed={shown[k]}
                        className={shown[k] ? "border-primary bg-primary/10 hover:bg-primary/10" : "text-muted-foreground"}
                        onClick={() => setShown({ ...shown, [k]: !shown[k] })}>
                  {label}
                </Button>
              ))}
            </div>
          </div>
          <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <Key tone="bg-primary text-primary-foreground" label="A groom" />
            <Key tone="bg-stop-soft text-stop" label="Expires and stops grooms (rabies)" />
            <Key tone="bg-warn-soft text-warn" label="Expires, groom can go ahead" />
          </p>
        </CardHeader>
        <CardContent>
          {problem && <p role="alert" className="mb-3 text-sm text-stop">{problem}</p>}
          <div className="grid grid-cols-7 border-l border-t border-border text-sm">
            {WEEKDAYS.map((w) => (
              <div key={w} className="border-b border-r border-border bg-muted/50 px-1 py-1.5 text-center text-xs font-medium text-muted-foreground">
                {w}
              </div>
            ))}
            {days.map((d) => {
              const key = iso(d);
              const list = byDay.get(key) ?? [];
              const inMonth = d.getMonth() === month.getMonth();
              return (
                <button key={key} onClick={() => setDay(key)} aria-pressed={day === key}
                        aria-label={`${d.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" })}: ${list.length} ${list.length === 1 ? "thing" : "things"}`}
                        className={cn("flex min-h-16 flex-col gap-0.5 border-b border-r border-border p-1 text-left align-top transition-colors hover:bg-muted/60 sm:min-h-24",
                                      !inMonth && "bg-muted/30 text-muted-foreground",
                                      day === key && "bg-accent/15 ring-2 ring-inset ring-accent")}>
                  <span className={cn("grid size-6 place-items-center rounded-full text-xs",
                                      key === today && "bg-primary font-semibold text-primary-foreground")}>
                    {d.getDate()}
                  </span>
                  {/* Names from a tablet up; on a phone, a dot each, and the day's list says who. */}
                  <span className="hidden flex-col gap-0.5 sm:flex">
                    {list.slice(0, 3).map((e, i) => (
                      <span key={i} className={cn("truncate rounded px-1 text-[11px] leading-4", look(e, today).tone)}>
                        {look(e, today).short}
                      </span>
                    ))}
                    {list.length > 3 && <span className="px-1 text-[11px] text-muted-foreground">+{list.length - 3} more</span>}
                  </span>
                  <span className="flex flex-wrap gap-0.5 sm:hidden">
                    {list.slice(0, 4).map((e, i) => (
                      <span key={i} className={cn("size-1.5 rounded-full", e.kind === "groom" ? "bg-primary" : e.stops_grooms ? "bg-stop" : "bg-warn")} />
                    ))}
                  </span>
                </button>
              );
            })}
          </div>
        </CardContent>
      </Card>

      <div className="flex flex-col gap-4">
        <DogFilter dog={dog} onDog={onDog} />
        {dog && dogEvents && (
          <DogDates dog={dog} events={dogEvents} today={today} day={day} onJump={jumpTo} onOpenDog={onOpenDog} />
        )}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              {day ? parse(day).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric" })
                   : "Pick a day"}
            </CardTitle>
          </CardHeader>
          <CardContent>
            {!day ? (
              <p className="text-sm text-muted-foreground">Pick a day on the calendar to see what&apos;s on it.</p>
            ) : onDay.length === 0 ? (
              <p className="text-sm text-muted-foreground">Nothing on this day.</p>
            ) : (
              <ul className="flex flex-col divide-y divide-border">
                {onDay.map((e, i) => {
                  const l = look(e, today);
                  return (
                    <li key={i} className="py-2.5 text-sm">
                      <button className="font-medium hover:underline" onClick={() => onOpenDog(e.dog_id)}>{e.dog}</button>
                      <span className="text-muted-foreground"> · {e.owner}</span>
                      <span className="mt-1 flex flex-wrap items-center gap-2">
                        <span className={cn("rounded px-1.5 py-0.5 text-xs font-medium", l.tone)}>{l.long}</span>
                        {e.kind === "expiry" && e.stops_grooms && <span className="text-xs text-stop">stops grooms</span>}
                      </span>
                      {e.note && <span className="mt-1 block text-muted-foreground">{e.note}</span>}
                    </li>
                  );
                })}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function Key({ tone, label }: { tone: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={cn("inline-block h-3 w-5 rounded", tone)} />
      {label}
    </span>
  );
}

/**
 * Narrow the calendar to one dog: a drop-down of every dog and its owner,
 * which typing narrows by either name. Arrow keys and Enter work too.
 */
function DogFilter({ dog, onDog }: { dog: CalendarDog | null; onDog: (dog: CalendarDog | null) => void }) {
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
    onDog({ id: d.id, name: d.name });
  }

  function onKey(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") { e.preventDefault(); setOpen(true); setActive((a) => Math.min(a + 1, hits.length - 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
    else if (e.key === "Enter" && open && hits[active]) { e.preventDefault(); pick(hits[active]); }
    else if (e.key === "Escape") setOpen(false);
  }

  if (dog) {
    return (
      <Card className="border-primary/40">
        <CardContent className="flex items-center justify-between gap-3 pt-5">
          <p className="text-sm">Focused on <span className="font-semibold">{dog.name}</span></p>
          <Button variant="outline" size="sm" onClick={() => onDog(null)}>Show every dog</Button>
        </CardContent>
      </Card>
    );
  }
  return (
    <Card>
      <CardContent className="pt-5">
        <label htmlFor="calendar-dog" className="mb-1 block text-sm font-medium">Focus calendar view:</label>
        <div className="relative">
          <Input id="calendar-dog" role="combobox" aria-expanded={open} aria-controls="calendar-dog-list"
                 aria-activedescendant={open && hits[active] ? `calendar-dog-${hits[active].id}` : undefined}
                 autoComplete="off" placeholder="Pick or type a name"
                 className="pr-9" value={q}
                 onChange={(e) => { setQ(e.target.value); setOpen(true); setActive(0); }}
                 onFocus={() => setOpen(true)}
                 // A beat, so a click on the list lands before it closes.
                 onBlur={() => setTimeout(() => setOpen(false), 150)}
                 onKeyDown={onKey} />
          <span aria-hidden className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground">▾</span>
          {open && (
            <ul id="calendar-dog-list" role="listbox"
                className="absolute z-20 mt-1 max-h-72 w-full overflow-auto rounded-[var(--radius)] border border-border bg-card py-1 shadow-lg">
              {hits.length === 0 ? (
                <li className="px-3 py-2 text-sm text-muted-foreground">No dog or owner by that name.</li>
              ) : hits.map((d, i) => (
                <li key={d.id} id={`calendar-dog-${d.id}`} role="option" aria-selected={i === active}
                    onMouseDown={(e) => { e.preventDefault(); pick(d); }}
                    onMouseEnter={() => setActive(i)}
                    className={cn("cursor-pointer px-3 py-2 text-sm", i === active && "bg-muted")}>
                  <span className="font-medium">{d.name}</span>
                  <span className="text-muted-foreground"> · {d.owner}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </CardContent>
    </Card>
  );
}

/** One dog's dates, newest first; each one jumps the calendar to it. */
function DogDates({ dog, events, today, day, onJump, onOpenDog }: {
  dog: CalendarDog; events: CalendarEvent[]; today: string; day: string | null;
  onJump: (date: string) => void; onOpenDog: (dogId: string) => void;
}) {
  const lastGroom = [...events].reverse().find((e) => e.kind === "groom" && e.on_date <= today);
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{dog.name}&apos;s dates</CardTitle>
        <p className="text-sm text-muted-foreground">
          {lastGroom ? <>Last groomed {formatDate(lastGroom.on_date)}, by {lastGroom.groomer}.</> : "No grooms recorded yet."}
        </p>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {events.length === 0 ? (
          <p className="text-sm text-muted-foreground">Nothing on the calendar for {dog.name} yet.</p>
        ) : (
          <ul className="flex flex-col gap-1">
            {[...events].reverse().map((e, i) => {
              const l = look(e, today);
              return (
                <li key={i}>
                  <Button variant="outline" size="sm" aria-pressed={day === e.on_date}
                          className={cn("w-full justify-between font-normal", day === e.on_date && "border-primary")}
                          onClick={() => onJump(e.on_date)}>
                    <span className={cn("truncate rounded px-1.5 text-xs", l.tone)}>
                      {e.kind === "groom" ? "Groomed" : l.long}
                    </span>
                    <span className="shrink-0 text-muted-foreground">{formatDate(e.on_date)}</span>
                  </Button>
                </li>
              );
            })}
          </ul>
        )}
        <Button variant="outline" size="sm" className="self-start" onClick={() => onOpenDog(dog.id)}>
          Open {dog.name}&apos;s card
        </Button>
      </CardContent>
    </Card>
  );
}
