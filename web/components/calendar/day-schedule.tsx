"use client";

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { Appointment, Groomer, ShopHours } from "@/lib/api";
import { cn, dayLabel, formatTime } from "@/lib/utils";

const toMinutes = (hms: string) => { const [h, m] = hms.slice(hms.indexOf("T") + 1).split(":").map(Number); return h * 60 + m; };

/**
 * One day, one row per groomer, from opening to closing: each booking a block
 * as long as the groom, so who is free when is plain to see. Whoever is at the
 * screen comes first; it is their day, with the team's below. A block opens
 * the booking.
 */
export function DaySchedule({ me, day, hours, groomers, appointments, canBook, onOpen, onBook }: {
  me: string; day: string; hours: ShopHours; groomers: Groomer[]; appointments: Appointment[]; canBook: boolean;
  onOpen: (a: Appointment) => void; onBook: () => void;
}) {
  const mine = groomers.find((g) => g.id === me);
  const rows = [...groomers].sort((a, b) => Number(b.id === me) - Number(a.id === me));
  const opens = toMinutes(hours.opens), closes = toMinutes(hours.closes), span = closes - opens;
  const marks = Array.from({ length: Math.floor(span / 60) + 1 }, (_, i) => opens + i * 60);
  const pct = (m: number) => `${((m - opens) / span) * 100}%`;

  return (
    <Card>
      <CardHeader className="flex-row flex-wrap items-center justify-between gap-3">
        <div>
          <CardTitle className="text-base">{mine ? `${mine.name}'s day` : "The day"} · {dayLabel(day)}</CardTitle>
          {groomers.length > 1 && <p className="text-sm text-muted-foreground">With the rest of the team below.</p>}
        </div>
        {canBook && <Button size="sm" onClick={onBook}>Book a groom on this day</Button>}
      </CardHeader>
      <CardContent>
        {/* Wide enough to read on a phone; it scrolls sideways inside the card, not the page. */}
        <div className="overflow-x-auto">
          <div className="min-w-[40rem] pr-5">
            <div className="relative ml-24 h-5 text-[11px] text-muted-foreground">
              {marks.map((m) => (
                <span key={m} className="absolute -translate-x-1/2" style={{ left: pct(m) }}>
                  {formatTime(`${String(Math.floor(m / 60)).padStart(2, "0")}:00`).replace(":00", "")}
                </span>
              ))}
            </div>
            {rows.map((g) => {
              const theirs = appointments.filter((a) => a.groomer_id === g.id);
              return (
                <div key={g.id} className="flex items-center border-t border-border py-1.5">
                  <span className={cn("w-24 shrink-0 truncate pr-2 text-sm", g.id === me ? "font-semibold" : "font-medium text-muted-foreground")}>
                    {g.name}{g.id === me && <span className="block text-xs font-normal text-muted-foreground">you</span>}
                  </span>
                  <div className="relative h-10 flex-1 rounded bg-muted/40">
                    {marks.map((m) => (
                      <span key={m} className="absolute inset-y-0 border-l border-border/70" style={{ left: pct(m) }} />
                    ))}
                    {theirs.map((a) => {
                      const s = toMinutes(a.starts_at), e = toMinutes(a.ends_at);
                      return (
                        <button key={a.id} onClick={() => onOpen(a)}
                                title={`${a.dog}${a.breed ? ` (${a.breed})` : ""} · ${formatTime(a.starts_at)}–${formatTime(a.ends_at)}`}
                                className={cn("absolute inset-y-0.5 overflow-hidden rounded border border-primary bg-card px-1.5 text-left text-[11px] leading-tight text-primary hover:bg-primary/10",
                                              a.not_usual_groomer && "border-dashed")}
                                style={{ left: pct(s), width: `calc(${pct(e)} - ${pct(s)})` }}>
                          <span className="block truncate font-semibold">{a.dog}</span>
                          <span className="block truncate">{formatTime(a.starts_at)}–{formatTime(a.ends_at)}</span>
                        </button>
                      );
                    })}
                    {theirs.length === 0 && (
                      <span className="absolute inset-0 grid place-items-center text-xs text-muted-foreground">Free all day</span>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
        <p className="mt-2 text-xs text-muted-foreground">
          Click a booking to change or cancel it. A dashed one is a regular client booked with someone other than their usual groomer.
        </p>
      </CardContent>
    </Card>
  );
}
