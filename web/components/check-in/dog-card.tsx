"use client";

import { useState } from "react";
import { Badge, toneFor } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { api, Refusal, type CheckInCard } from "@/lib/api";
import { cn, formatDate, formatTime } from "@/lib/utils";

const SEX = { male: "Male", female: "Female", unknown: "" } as Record<string, string>;
const CHANNEL = { email: "by email", sms: "by text", verbal_at_counter: "at the counter" } as Record<string, string>;
const TRIGGER = {
  dryer: "Dryer", clippers: "Clippers", nail_grinder: "Nail grinder", restraint: "Restraint", water: "Water", other: "",
} as Record<string, string>;

export function DogCard({
  card, groomerId, onChanged,
}: {
  card: CheckInCard;
  groomerId: string | null;
  onChanged: () => void;
}) {
  const { dog } = card;
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function start() {
    if (!groomerId) return;
    setBusy(true); setRefusal(null); setError(null);
    try {
      await api.startGroom(dog.id, groomerId);
      onChanged();
    } catch (e) {
      if (e instanceof Refusal) {
        // The database knew something this card didn't. Show its words, and
        // reload the card so the rest of the screen agrees with them.
        setRefusal(e);
        onChanged();
      } else {
        setError(e instanceof Error ? e.message : String(e));
      }
    } finally {
      setBusy(false);
    }
  }

  const details = [dog.breed, SEX[dog.sex], dog.age, `${dog.coat} coat`].filter(Boolean).join(" · ");

  return (
    <div className="flex flex-col gap-4">
      {/* Who */}
      <div>
        <h2 className="text-3xl font-semibold tracking-tight">{dog.name}</h2>
        <p className="text-muted-foreground">{details}</p>
        <p className="mt-1 text-sm">
          {dog.owner}
          {dog.phone && <> · <a className="underline-offset-2 hover:underline" href={`tel:${dog.phone}`}>{dog.phone}</a></>}
          {dog.email && <> · {dog.email}</>}
        </p>
      </div>

      {/* Can the groom start? — the one thing this screen exists to answer */}
      <div
        role="status"
        className={cn(
          "rounded-[var(--radius)] border p-4",
          card.open_visit ? "border-primary/30 bg-muted" : card.can_start ? "border-ok/30 bg-ok-soft" : "border-stop/30 bg-stop-soft",
        )}
      >
        {card.open_visit ? (
          <p className="text-lg font-semibold">
            Being groomed — checked in at {formatTime(card.open_visit.check_in)} by {card.open_visit.groomer}
          </p>
        ) : card.can_start ? (
          <p className="text-lg font-semibold text-ok">Cleared for today&apos;s groom</p>
        ) : (
          <>
            <p className="text-lg font-semibold text-stop">Can&apos;t groom today</p>
            <ul className="mt-1 text-stop">
              {card.blocking.map((b) => <li key={b}>{b}</li>)}
            </ul>
            <p className="mt-2 text-sm">Ask the owner for a current certificate. Once it is confirmed, check the dog in again.</p>
          </>
        )}
        {card.paperwork_requests.length > 0 && (
          <ul className="mt-3 border-t border-border/60 pt-2 text-sm text-muted-foreground">
            {card.paperwork_requests.map((r) => (
              <li key={r.vaccine}>
                {r.status === "insufficient"
                  ? `${r.vaccine}: the last paperwork received wasn't enough to record it.`
                  : `${r.vaccine}: certificate requested ${CHANNEL[r.channel] ?? ""}${r.next_reminder_on ? `, reminder due ${formatDate(r.next_reminder_on)}` : ""}.`}
              </li>
            ))}
          </ul>
        )}

        {!card.open_visit && (
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Button variant="go" size="lg" disabled={!card.can_start || !groomerId || busy} onClick={start}>
              {busy ? "Starting…" : "Start groom"}
            </Button>
            {!groomerId && <span className="text-sm text-muted-foreground">Choose who is grooming, above.</span>}
          </div>
        )}
        {refusal && (
          <div className="mt-3 text-sm text-stop" role="alert">
            <p className="font-medium">{refusal.message}</p>
            {/* Once the card has caught up, its banner already gives the hint. */}
            {refusal.hint && card.can_start && <p>{refusal.hint}</p>}
          </div>
        )}
        {error && <p className="mt-3 text-sm text-stop" role="alert">{error}</p>}
      </div>

      {/* Allergies first among the details: they change what goes on the dog. */}
      {card.allergies.length > 0 && (
        <Card className="border-stop/30">
          <CardHeader><CardTitle className="text-stop">Allergies</CardTitle></CardHeader>
          <CardContent>
            <ul className="flex flex-col gap-2">
              {card.allergies.map((a) => (
                <li key={a.allergen} className="flex flex-wrap items-baseline gap-x-2">
                  <span className="font-medium">{a.allergen}</span>
                  <Badge tone={a.severity >= 3 ? "stop" : "warn"}>{a.severity_label}</Badge>
                  {a.note && <span className="w-full text-sm text-muted-foreground">{a.note}</span>}
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader><CardTitle>Vaccinations</CardTitle></CardHeader>
          <CardContent>
            <ul className="flex flex-col divide-y divide-border">
              {card.vaccines.map((v) => (
                <li key={v.code} className="flex items-center justify-between gap-3 py-2">
                  <span>
                    <span className="font-medium">{v.vaccine}</span>
                    {v.expires_on && (
                      <span className="block text-sm text-muted-foreground">
                        {v.days_until_expiry !== null && v.days_until_expiry < 0 ? "Expired" : "Expires"} {formatDate(v.expires_on)}
                      </span>
                    )}
                  </span>
                  <Badge tone={toneFor(v.state, v.blocks_service)}>{v.label}</Badge>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>Handling</CardTitle></CardHeader>
          <CardContent>
            {card.behaviour.length === 0 ? (
              <p className="text-sm text-muted-foreground">No handling notes yet.</p>
            ) : (
              <ul className="flex flex-col gap-3">
                {card.behaviour.map((b, i) => (
                  <li key={i}>
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge tone={b.difficulty >= 4 ? "stop" : b.difficulty === 3 ? "warn" : "ok"}>{b.difficulty_label}</Badge>
                      <span className="text-sm text-muted-foreground">
                        {[b.trigger && TRIGGER[b.trigger], b.zone].filter(Boolean).join(" · ")}
                      </span>
                    </div>
                    {b.note && <p className="mt-1 text-sm">{b.note}</p>}
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader><CardTitle>Last visit</CardTitle></CardHeader>
        <CardContent>
          {card.last_visit ? (
            <p className="text-sm">
              <span className="font-medium">{formatDate(card.last_visit.visit_date)}</span> with {card.last_visit.groomer}
              {card.last_visit.note && <span className="block text-muted-foreground">{card.last_visit.note}</span>}
            </p>
          ) : (
            <p className="text-sm text-muted-foreground">No visits recorded yet.</p>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
