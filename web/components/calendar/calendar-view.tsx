"use client";

import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { BookingForm, type BookingStart } from "@/components/calendar/booking-form";
import { DaySchedule } from "@/components/calendar/day-schedule";
import { DogPicker } from "@/components/calendar/dog-picker";
import { api, type Appointment, type CalendarEvent, type Groomer, type ShopHours } from "@/lib/api";
import { cn, duration, formatDate, formatTime } from "@/lib/utils";
import { GoodStanding } from "@/components/ui/good-standing";

/** One dog the calendar is showing on its own. */
export type CalendarDog = { id: string; name: string };

type Kind = "groom" | "expiry" | "booking";

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

/**
 * How one thing reads, and its colour: a groom done in solid mauve, one booked
 * in outline, an expiry by how much it matters.
 */
function look(e: CalendarEvent, today: string) {
  if (e.kind === "booking") {
    const start = formatTime(e.starts_at);
    return { tone: "border border-primary bg-card text-primary", short: `${start.replace(/ [AP]M$/, "")} ${e.dog}`,
             long: `booked ${start}, ${duration(e.minutes ?? 0)} with ${e.groomer}` };
  }
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
export function CalendarView({ me, dog, onDog, onOpenDog, booking, onBooking }: {
  /** Who is at the screen: they are the one booking. */
  me: string;
  dog: CalendarDog | null; onDog: (dog: CalendarDog | null) => void; onOpenDog: (dogId: string) => void;
  /** A booking being made or changed (null: none), kept by the page so a dog's card can start one. */
  booking: BookingStart | null; onBooking: (b: BookingStart | null) => void;
}) {
  const today = iso(new Date());
  const [month, setMonth] = useState(() => firstOfMonth(new Date()));
  const [day, setDay] = useState<string | null>(today);
  const [shown, setShown] = useState<Record<Kind, boolean>>({ groom: true, expiry: true, booking: true });
  const [hours, setHours] = useState<ShopHours | null>(null);
  const [groomers, setGroomers] = useState<Groomer[]>([]);
  const [dayBookings, setDayBookings] = useState<Appointment[]>([]);
  // Bumped after a booking is saved, so everything on screen is read again.
  const [rev, setRev] = useState(0);
  const [monthEvents, setMonthEvents] = useState<CalendarEvent[]>([]);
  const [dogEvents, setDogEvents] = useState<CalendarEvent[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  const days = useMemo(() => gridDays(month), [month]);
  const span = { start: iso(days[0]), end: iso(days[days.length - 1]) };

  // Opened from further down a dog's card: start at the top.
  useEffect(() => {
    window.scrollTo({ top: 0 });
    api.shopHours().then(setHours).catch((e) => setProblem(String(e.message ?? e)));
    api.groomers().then(setGroomers).catch((e) => setProblem(String(e.message ?? e)));
  }, []);

  // The chosen day's bookings, for the day's schedule.
  useEffect(() => {
    if (!day) { setDayBookings([]); return; }
    api.dayAppointments(day).then(setDayBookings).catch((e) => setProblem(String(e.message ?? e)));
  }, [day, rev]);

  // The month on screen, for every dog.
  useEffect(() => {
    if (dog) return;
    api.calendar(span).then(setMonthEvents).catch((e) => setProblem(String(e.message ?? e)));
  }, [dog, span.start, span.end, rev]);

  // One dog: its whole history, and straight to its latest groom (or, with
  // none, its next expiry).
  useEffect(() => {
    if (!dog) { setDogEvents(null); return; }
    api.calendar({ dogId: dog.id }).then((evs) => {
      setDogEvents(evs);
      const lastGroom = [...evs].reverse().find((e) => e.kind === "groom" && e.on_date <= today);
      const next = evs.find((e) => e.on_date >= today) ?? evs[evs.length - 1];
      const go = lastGroom ?? next;
      if (go && rev === 0) jumpTo(go.on_date);
    }).catch((e) => setProblem(String(e.message ?? e)));
  }, [dog?.id, rev]);

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
  const canBook = !!day && !!hours && day >= hours.today;
  const openBooking = (id: string | null) => {
    const a = dayBookings.find((x) => x.id === id);
    if (a) onBooking({ appointment: a });
  };

  return (
    <div className="flex flex-col gap-6">
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <div className="min-w-0">
      {booking ? (
        <BookingForm key={booking.appointment?.id ?? "new"} me={me} start={booking}
                     onClose={() => onBooking(null)}
                     onDone={(d) => { onBooking(null); jumpTo(d); setRev((r) => r + 1); }} />
      ) : (
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
              {([["booking", "Bookings"], ["groom", "Grooms"], ["expiry", "Vaccine expiries"]] as const).map(([k, label]) => (
                <Button key={k} variant="outline" size="sm" aria-pressed={shown[k]}
                        className={shown[k] ? "border-primary bg-primary/10 hover:bg-primary/10" : "text-muted-foreground"}
                        onClick={() => setShown({ ...shown, [k]: !shown[k] })}>
                  {label}
                </Button>
              ))}
            </div>
          </div>
          <p className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <Key tone="border border-primary bg-card" label="Booked" />
            <Key tone="bg-primary text-primary-foreground" label="Groomed" />
            <Key tone="bg-stop-soft text-stop" label="Expires and stops grooms (rabies)" />
            <Key tone="bg-warn-soft text-warn" label="Expires, groom can go ahead" />
            <span className="inline-flex items-center gap-1.5"><GoodStanding show /> All vaccines current</span>
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
                      <span key={i} className={cn("flex items-center gap-0.5 truncate rounded px-1 text-[11px] leading-4", look(e, today).tone)}>
                        {e.kind === "booking" && <GoodStanding show={e.in_good_standing} className="size-3 text-[8px]" />}
                        <span className="truncate">{look(e, today).short}</span>
                      </span>
                    ))}
                    {list.length > 3 && <span className="px-1 text-[11px] text-muted-foreground">+{list.length - 3} more</span>}
                  </span>
                  <span className="flex flex-wrap gap-0.5 sm:hidden">
                    {list.slice(0, 4).map((e, i) => (
                      <span key={i} className={cn("size-1.5 rounded-full", e.kind === "booking" ? "border border-primary" : e.kind === "groom" ? "bg-primary" : e.stops_grooms ? "bg-stop" : "bg-warn")} />
                    ))}
                  </span>
                </button>
              );
            })}
          </div>
        </CardContent>
      </Card>
      )}
      </div>

      <div className="flex flex-col gap-4">
        <DogFilter dog={dog} onDog={onDog} />
        {dog && dogEvents && (
          <DogDates dog={dog} events={dogEvents} today={today} day={day} onJump={jumpTo} onOpenDog={onOpenDog}
                    onBook={() => onBooking({ dog, day: canBook ? day ?? undefined : undefined })} />
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
                      <button className="font-medium hover:underline" onClick={() => onOpenDog(e.dog_id)}>{e.dog}</button>{" "}
                      <GoodStanding show={e.in_good_standing} />
                      <span className="text-muted-foreground"> · {e.owner}</span>
                      {e.breed && <span className="block text-xs text-muted-foreground">{e.breed}</span>}
                      <span className="mt-1 flex flex-wrap items-center gap-2">
                        <span className={cn("rounded px-1.5 py-0.5 text-xs font-medium", l.tone)}>{l.long}</span>
                        {e.kind === "expiry" && e.stops_grooms && <span className="text-xs text-stop">stops grooms</span>}
                      </span>
                      {e.note && <span className="mt-1 block text-muted-foreground">{e.note}</span>}
                      {e.kind === "booking" && e.on_date >= today && (
                        <Button variant="outline" size="sm" className="mt-2" onClick={() => openBooking(e.appointment_id)}>
                          Change or cancel
                        </Button>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
    {!booking && day && hours && (canBook || dayBookings.length > 0) && (
        <DaySchedule me={me} day={day} hours={hours} groomers={groomers} appointments={dayBookings} canBook={canBook}
                     onOpen={(a) => onBooking({ appointment: a })}
                     onBook={() => onBooking({ day, dog })} />
      )}
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

/** Narrow the calendar to one dog. */
function DogFilter({ dog, onDog }: { dog: CalendarDog | null; onDog: (dog: CalendarDog | null) => void }) {
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
        <DogPicker id="calendar-dog" label="Focus calendar view:" onPick={(d) => onDog({ id: d.id, name: d.name })} />
      </CardContent>
    </Card>
  );
}

/** One dog's dates, newest first; each one jumps the calendar to it. */
function DogDates({ dog, events, today, day, onJump, onOpenDog, onBook }: {
  dog: CalendarDog; events: CalendarEvent[]; today: string; day: string | null;
  onJump: (date: string) => void; onOpenDog: (dogId: string) => void; onBook: () => void;
}) {
  const lastGroom = [...events].reverse().find((e) => e.kind === "groom" && e.on_date <= today);
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-1.5 text-base">
          {dog.name}&apos;s dates <GoodStanding show={events[0]?.in_good_standing} />
        </CardTitle>
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
                      {e.kind === "groom" ? "Groomed" : e.kind === "booking" ? `Booked ${formatTime(e.starts_at)}` : l.long}
                    </span>
                    <span className="shrink-0 text-muted-foreground">{formatDate(e.on_date)}</span>
                  </Button>
                </li>
              );
            })}
          </ul>
        )}
        <div className="flex flex-wrap gap-2">
          <Button size="sm" onClick={onBook}>Book {dog.name}</Button>
          <Button variant="outline" size="sm" onClick={() => onOpenDog(dog.id)}>Open {dog.name}&apos;s card</Button>
        </div>
      </CardContent>
    </Card>
  );
}
