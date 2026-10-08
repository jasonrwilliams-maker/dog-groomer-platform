"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { DogPicker } from "@/components/calendar/dog-picker";
import {
  api, Refusal, type Appointment, type BookingChoice, type BookingWarning, type CheckInCard, type Service,
  type ShopHours,
} from "@/lib/api";
import { cn, dayLabel, duration, formatDate, formatTime } from "@/lib/utils";
import { GoodStanding } from "@/components/ui/good-standing";
import { DogPhoto } from "@/components/ui/dog-photo";

export type BookingStart = {
  dog?: { id: string; name: string } | null;
  day?: string;
  /** Changing a booking rather than making one. */
  appointment?: Appointment;
};

// The lengths most grooms take; anything else is typed in.
const LENGTHS = [60, 90, 120, 180, 240, 360];

/** The time of day a groom ends, as a shop time. */
function plus(at: string, minutes: number): string {
  const [h, m] = at.slice(11, 16).split(":").map(Number);
  const t = h * 60 + m + minutes;
  return `${at.slice(0, 11)}${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}:00`;
}

/**
 * Book a groom, or change one: the dog, what and how long, the day, the
 * groomer (the dog's usual one first) and one of their free start times.
 * Vaccines that will be out of date by then are a warning; the check-in
 * screen still decides on the day.
 */
export function BookingForm({ me, start, onDone, onClose }: {
  me: string; start: BookingStart; onDone: (day: string) => void; onClose: () => void;
}) {
  const appt = start.appointment;
  const [hours, setHours] = useState<ShopHours | null>(null);
  const [services, setServices] = useState<Service[]>([]);
  const [dog, setDog] = useState(appt ? { id: appt.dog_id, name: appt.dog } : start.dog ?? null);
  const [service, setService] = useState(appt?.service_code ?? "full_groom");
  // Left at the service's usual length unless someone says otherwise.
  const [minutes, setMinutes] = useState(appt?.minutes ?? 90);
  const [customLength, setCustomLength] = useState(false);
  // Who the dog is: breed, age, owner and phone, for the groomer on the phone to the owner.
  const [about, setAbout] = useState<CheckInCard | null>(null);
  const [day, setDay] = useState(appt?.starts_at.slice(0, 10) ?? start.day ?? "");
  const [groomerId, setGroomerId] = useState<string | null>(appt?.groomer_id ?? null);
  const [time, setTime] = useState<string | null>(appt?.starts_at ?? null);
  const [note, setNote] = useState(appt?.note ?? "");
  const [reason, setReason] = useState(appt?.other_groomer_reason ?? "");
  const [choices, setChoices] = useState<BookingChoice[]>([]);
  const [warnings, setWarnings] = useState<BookingWarning[]>([]);
  const [saving, setSaving] = useState(false);
  const [problem, setProblem] = useState<{ message: string; hint: string | null } | null>(null);
  const [cancelling, setCancelling] = useState<string | null>(null);

  useEffect(() => {
    api.shopHours().then((h) => { setHours(h); setDay((d) => d && d >= h.today ? d : h.today); }).catch(fail);
    api.services().then((list) => {
      setServices(list);
      const usual = list.find((x) => x.code === service)?.default_minutes;
      if (usual && !appt) setMinutes(usual);
      if (usual && appt && appt.minutes !== usual) setCustomLength(true);
    }).catch(fail);
  }, []);

  useEffect(() => {
    if (!dog) { setAbout(null); return; }
    api.card(dog.id).then(setAbout).catch(() => setAbout(null));
  }, [dog?.id]);

  // Who can take it, and when, whenever the dog, the day or the length changes.
  useEffect(() => {
    if (!dog || !day || !hours) return;
    api.bookingChoices(dog.id, `${day}T${hours.opens}`, minutes, appt?.id).then(({ choices: found, warnings: w }) => {
      const rank = (x: BookingChoice) => (x.is_regular ? 0 : x.groomer_id === me ? 1 : 2);
      const c = [...found].sort((a, b) => rank(a) - rank(b));
      setChoices(c);
      setWarnings(w);
      const keep = c.find((x) => x.groomer_id === groomerId);
      const pick = keep ?? c[0];
      if (pick && !keep) setGroomerId(pick.groomer_id);
      setTime((t) => (t && pick?.free_starts.includes(t) ? t : null));
    }).catch(fail);
  }, [dog?.id, day, minutes, hours]);

  function fail(e: unknown) {
    setProblem(e instanceof Refusal ? { message: e.message, hint: e.hint }
               : { message: String((e as Error).message ?? e), hint: null });
  }

  const chosen = choices.find((c) => c.groomer_id === groomerId);
  const usual = choices.find((c) => c.is_regular);
  const elsewhere = usual && chosen && usual.groomer_id !== chosen.groomer_id;
  const allDay = hours ? (Number(hours.closes.slice(0, 2)) * 60 + Number(hours.closes.slice(3, 5)))
                         - (Number(hours.opens.slice(0, 2)) * 60 + Number(hours.opens.slice(3, 5))) : 600;
  const ready = dog && chosen && time && (!elsewhere || reason.trim());

  function save() {
    if (!dog || !chosen || !time) return;
    setSaving(true); setProblem(null);
    const b = { groomer_id: chosen.groomer_id, starts_at: time, minutes, note: note || null,
                other_groomer_reason: elsewhere ? reason : null, booked_by: me };
    (appt ? api.changeBooking(appt.id, b) : api.book({ ...b, dog_id: dog.id, service }))
      .then(() => onDone(day)).catch(fail).finally(() => setSaving(false));
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>{appt ? `Change ${appt.dog}'s booking` : "Book a groom"}</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-5">
        {/* The dog */}
        {dog ? (
          <div className="flex items-start justify-between gap-3">
            <div className="flex items-start gap-3">
            <DogPhoto dogId={dog.id} photo={about?.photo?.id} name={dog.name} size="md" />
            <div>
              <p className="flex items-center gap-1.5 text-lg font-semibold">{dog.name}<GoodStanding show={about?.in_good_standing} /></p>
              {about && (
                <p className="text-sm text-muted-foreground">
                  {[about.dog.breed, about.dog.age, about.dog.coat && `${about.dog.coat} coat`].filter(Boolean).join(" · ")}
                </p>
              )}
              {about && (
                <p className="text-sm">
                  {about.dog.owner}
                  {about.dog.phone && <span className="text-muted-foreground"> · {about.dog.phone}</span>}
                </p>
              )}
              <p className="text-sm text-muted-foreground">
                {usual ? `Usually with ${usual.groomer}` : "New client: no usual groomer yet"}
                {about?.last_visit && ` · last groomed ${formatDate(about.last_visit.visit_date)}`}
              </p>
            </div>
            </div>
            {!appt && <Button variant="outline" size="sm" onClick={() => { setDog(null); setChoices([]); setGroomerId(null); }}>Change dog</Button>}
          </div>
        ) : (
          <DogPicker id="booking-dog" label="Which dog?" onPick={(d) => setDog({ id: d.id, name: d.name })} />
        )}

        {/* What, and how long */}
        <div className="grid gap-4 sm:grid-cols-2">
          <label className="flex flex-col gap-1 text-sm">
            <span className="font-medium">Service</span>
            <select disabled={!!appt} value={service}
                    onChange={(e) => {
                      setService(e.target.value);
                      const sv = services.find((x) => x.code === e.target.value);
                      if (sv && !customLength) setMinutes(sv.default_minutes);
                    }}
                    className="h-11 rounded-[var(--radius)] border border-border bg-card px-3 text-base">
              {services.map((sv) => <option key={sv.code} value={sv.code}>{sv.name}</option>)}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="font-medium">Day</span>
            <Input type="date" min={hours?.today} value={day} onChange={(e) => setDay(e.target.value)} />
          </label>
        </div>
        <fieldset className="flex flex-col gap-2">
          <legend className="sr-only">How long</legend>
          <p className="text-sm">
            Takes <span className="font-semibold">{duration(minutes)}</span>
            {!customLength && <span className="text-muted-foreground"> · the usual for a {services.find((x) => x.code === service)?.name.toLowerCase() ?? "groom"}</span>}
          </p>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" className="size-4 accent-[var(--primary)]" checked={customLength}
                   onChange={(e) => {
                     setCustomLength(e.target.checked);
                     const usualMinutes = services.find((x) => x.code === service)?.default_minutes;
                     if (!e.target.checked && usualMinutes) setMinutes(usualMinutes);
                   }} />
            Set a different length for this groom
          </label>
          {customLength && (
            <div className="flex flex-wrap gap-2">
              {[...LENGTHS, allDay].map((m) => (
                <Button key={m} type="button" variant="outline" size="sm" aria-pressed={minutes === m}
                        className={minutes === m ? "border-primary bg-primary/10 text-primary hover:bg-primary/10" : ""}
                        onClick={() => setMinutes(m)}>
                  {m === allDay ? "All day" : duration(m)}
                </Button>
              ))}
              <label className="flex items-center gap-2 text-sm text-muted-foreground">
                or
                <Input type="number" min={5} max={allDay} step={15} value={minutes} className="h-8 w-20 text-sm"
                       onChange={(e) => setMinutes(Math.max(5, Number(e.target.value) || 0))} />
                minutes
              </label>
            </div>
          )}
        </fieldset>

        {/* Who */}
        {dog && choices.length > 0 && (
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm font-medium">Groomer</legend>
            <div className="grid gap-2 sm:grid-cols-2">
              {choices.map((c) => (
                <button key={c.groomer_id} type="button" aria-pressed={c.groomer_id === groomerId}
                        onClick={() => { setGroomerId(c.groomer_id); setTime((t) => t && c.free_starts.includes(t) ? t : null); }}
                        className={cn("rounded-[var(--radius)] border p-3 text-left text-sm transition-colors hover:border-primary",
                                      c.groomer_id === groomerId ? "border-primary bg-primary/10" : "border-border bg-card")}>
                  <span className="font-semibold">{c.groomer}{c.groomer_id === me && " (you)"}</span>
                  {c.is_regular && <span className="ml-2 rounded bg-accent/30 px-1.5 py-0.5 text-xs font-medium">Usual groomer</span>}
                  <span className="block text-muted-foreground">
                    {c.last_groomed_on ? `Last groomed ${dog.name} ${formatDate(c.last_groomed_on)}` : c.is_regular ? `${dog.name} is booked with them` : "Hasn't groomed this dog"}
                  </span>
                  <span className={cn("block", c.free_starts.length ? "text-ok" : "text-stop")}>
                    {c.free_starts.length ? `Free from ${formatTime(c.free_starts[0])}` : "No room that day for this length"}
                  </span>
                </button>
              ))}
            </div>
            {elsewhere && (
              <label className="flex flex-col gap-1 rounded-[var(--radius)] border border-warn/40 bg-warn-soft p-3 text-sm">
                <span>
                  {dog.name} usually goes to <span className="font-semibold">{usual.groomer}</span>
                  {usual.free_starts.length > 0 ? <>, who has free time that day</> : <>, who is fully booked that day</>}.
                  Why {chosen.groomer} this time?
                </span>
                <Input placeholder={`e.g. ${usual.groomer} is off, or the owner asked`} value={reason}
                       onChange={(e) => setReason(e.target.value)} />
              </label>
            )}
          </fieldset>
        )}

        {/* When */}
        {chosen && (
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm font-medium">Start time with {chosen.groomer} on {dayLabel(day)}</legend>
            {chosen.free_starts.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                No free time for a groom this long. Try a shorter length, another groomer or another day.
              </p>
            ) : (
              <div className="flex flex-wrap gap-1.5">
                {chosen.free_starts.map((s) => (
                  <Button key={s} type="button" variant="outline" size="sm" aria-pressed={time === s}
                          className={time === s ? "border-primary bg-primary text-primary-foreground hover:bg-primary" : ""}
                          onClick={() => setTime(s)}>
                    {formatTime(s)}
                  </Button>
                ))}
              </div>
            )}
          </fieldset>
        )}

        {/* Vaccines: a warning, never a refusal */}
        {warnings.length > 0 && (
          <div role="status" className="rounded-[var(--radius)] border border-warn/40 bg-warn-soft p-3 text-sm">
            <p className="font-medium text-warn">Paperwork to ask for before the day</p>
            <ul className="mt-1 list-disc pl-5">
              {warnings.map((w) => (
                <li key={w.vaccine}>
                  {w.vaccine}: {w.warning}{w.expires_on && ` (${formatDate(w.expires_on)})`}
                </li>
              ))}
            </ul>
            <p className="mt-1 text-muted-foreground">The booking can still go ahead. On the day, check-in won&apos;t start the groom without it.</p>
          </div>
        )}

        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Note <span className="font-normal text-muted-foreground">(optional)</span></span>
          <Input placeholder="e.g. matted behind the ears, owner drops off at 9" value={note} onChange={(e) => setNote(e.target.value)} />
        </label>

        {problem && (
          <div role="alert" className="text-sm text-stop">
            <p className="font-medium">{problem.message}</p>
            {problem.hint && <p>{problem.hint}</p>}
          </div>
        )}

        <div className="flex flex-wrap gap-2">
          <Button disabled={!ready || saving} onClick={save}>
            {saving ? "Saving…" : ready && dog && chosen && time
              ? `${appt ? "Save" : "Book"} ${dog.name} · ${dayLabel(day)}, ${formatTime(time)}–${formatTime(plus(time, minutes))} with ${chosen.groomer}`
              : appt ? "Save the change" : "Book"}
          </Button>
          <Button variant="outline" onClick={onClose}>{appt ? "Keep it as it was" : "Cancel"}</Button>
          {appt && cancelling === null && (
            <Button variant="danger" className="ml-auto" onClick={() => setCancelling("")}>Cancel this booking</Button>
          )}
        </div>
        {appt && cancelling !== null && (
          <div className="flex flex-col gap-2 rounded-[var(--radius)] border border-stop/40 bg-stop-soft p-3 text-sm">
            <label className="flex flex-col gap-1">
              <span>Why is it cancelled? <span className="text-muted-foreground">(optional)</span></span>
              <Input placeholder="e.g. owner called, dog unwell" value={cancelling} onChange={(e) => setCancelling(e.target.value)} />
            </label>
            <div className="flex gap-2">
              <Button variant="danger" size="sm"
                      onClick={() => api.cancelBooking(appt.id, me, cancelling).then(() => onDone(day)).catch(fail)}>
                Yes, cancel {appt.dog}&apos;s booking
              </Button>
              <Button variant="outline" size="sm" onClick={() => setCancelling(null)}>Keep it</Button>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
