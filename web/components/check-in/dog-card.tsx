"use client";

import { useState } from "react";
import { Badge, toneFor } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AllergyCard } from "@/components/check-in/allergy-card";
import { HandlingCard } from "@/components/check-in/handling-card";
import { PaperworkIntake } from "@/components/check-in/paperwork-intake";
import { ProfileEditForm } from "@/components/check-in/profile-edit-form";
import { api, paperworkUrl, Refusal, type CheckInCard } from "@/lib/api";
import { cn, formatDate, formatTime } from "@/lib/utils";

const SEX = { male: "Male", female: "Female", unknown: "" } as Record<string, string>;
const CHANNEL = { email: "by email", sms: "by text", verbal_at_counter: "at the counter" } as Record<string, string>;

export function DogCard({
  card, groomerId, onChanged, onAddDog, detailsOpen = false,
}: {
  card: CheckInCard;
  groomerId: string;
  onChanged: () => void;
  /** Start a walk-in for another dog of this owner. */
  onAddDog: (ownerId: string, ownerName: string) => void;
  /** Managers see everything unfolded; groomers get the short card. */
  detailsOpen?: boolean;
}) {
  const { dog } = card;
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Open: a new copy (true), or one already waiting to be checked.
  const [paperwork, setPaperwork] = useState<boolean | { documentId: string }>(false);
  const [editing, setEditing] = useState(false);

  async function start() {
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

  if (editing) {
    return <ProfileEditForm card={card} groomerId={groomerId} onCancel={() => setEditing(false)}
                            onDone={() => { setEditing(false); onChanged(); }} />;
  }

  return (
    <div className="flex flex-col gap-4">
      {/* Who */}
      <div>
        <div className="flex items-start justify-between gap-3">
          <h2 className="text-3xl font-semibold tracking-tight">{dog.name}</h2>
          <Button variant="outline" size="sm" onClick={() => setEditing(true)}>Edit profile</Button>
        </div>
        <p className="text-muted-foreground">{details}</p>
        <p className="mt-1 text-sm">
          {dog.owner}
          {dog.phone && <> · <a className="underline-offset-2 hover:underline" href={`tel:${dog.phone}`}>{dog.phone}</a></>}
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
            <p className="mt-2 text-sm">Ask the owner for a current certificate, and add it below.</p>
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

        {card.paperwork_waiting.length > 0 && !paperwork && (
          <div className="mt-3 flex flex-wrap items-center justify-between gap-2 border-t border-border/60 pt-2 text-sm">
            <span>
              Paperwork received from the owner{card.paperwork_waiting.length > 1 && ` (${card.paperwork_waiting.length} copies)`},
              waiting to be checked.
            </span>
            <Button variant="outline" size="sm"
                    onClick={() => setPaperwork({ documentId: card.paperwork_waiting[0].document_id })}>
              Check it now
            </Button>
          </div>
        )}

        {!card.open_visit && (
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <Button variant="go" size="lg" disabled={!card.can_start || busy} onClick={start}>
              {busy ? "Starting…" : "Start groom"}
            </Button>
            {!paperwork && (
              <Button variant="outline" size="lg" onClick={() => setPaperwork(true)}>
                Add paperwork
              </Button>
            )}
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

      {paperwork && (
        <Card className="border-primary/40">
          <CardHeader><CardTitle>Paperwork the owner brought</CardTitle></CardHeader>
          <CardContent>
            <PaperworkIntake key={typeof paperwork === "object" ? paperwork.documentId : "new"}
                             dogId={dog.id} dogName={dog.name} groomerId={groomerId}
                             resume={typeof paperwork === "object" ? paperwork : undefined}
                             onChanged={onChanged} onClose={() => setPaperwork(false)} />
          </CardContent>
        </Card>
      )}

      {/* Allergies first among the details: they change what goes on the dog. */}
      <AllergyCard dogId={dog.id} allergies={card.allergies} groomerId={groomerId} onChanged={onChanged} />

      <HandlingCard dogId={dog.id} notes={card.behaviour} groomerId={groomerId} onChanged={onChanged} />

      {/* The rest is there when it's wanted, out of the way when it isn't. */}
      <details open={detailsOpen} className="group">
        <summary className="cursor-pointer list-none rounded-[var(--radius)] px-1 py-2 text-sm font-medium text-muted-foreground hover:text-foreground">
          <span className="group-open:hidden">▸ More details: vaccinations, last visit, contact</span>
          <span className="hidden group-open:inline">▾ Fewer details</span>
        </summary>
        <div className="mt-2 grid gap-4 md:grid-cols-2">
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
                      {v.hand_checked && (
                        <a href={paperworkUrl(v.hand_checked.document_id)} target="_blank" rel="noreferrer"
                           className="block text-xs text-muted-foreground hover:underline">
                          Checked by hand by {v.hand_checked.checked_by}, {formatDate(v.hand_checked.checked_on)}
                          {v.hand_checked.fixed_by ? ` · dates fixed by ${v.hand_checked.fixed_by}`
                            : v.hand_checked.second_look ? " · manager agreed" : " · manager hasn't looked yet"} · photo ↗
                        </a>
                      )}
                    </span>
                    <Badge tone={toneFor(v.state, v.blocks_service)}>{v.label}</Badge>
                  </li>
                ))}
              </ul>
            </CardContent>
          </Card>

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
              <p className="mt-4 text-sm">
                <span className="block font-medium">{dog.owner}</span>
                {dog.phone && <a className="block underline-offset-2 hover:underline" href={`tel:${dog.phone}`}>{dog.phone}</a>}
                {dog.email && <a className="block underline-offset-2 hover:underline" href={`mailto:${dog.email}`}>{dog.email}</a>}
              </p>
              {card.household.other_dogs.length > 0 && (
                <p className="mt-2 text-sm text-muted-foreground">Also brings {card.household.other_dogs.join(", ")}.</p>
              )}
              <Button variant="outline" size="sm" className="mt-3"
                      onClick={() => onAddDog(card.household.owner_id, dog.owner)}>
                + Add another dog for {dog.owner.split(" ")[0]}
              </Button>
            </CardContent>
          </Card>
        </div>
      </details>
    </div>
  );
}
