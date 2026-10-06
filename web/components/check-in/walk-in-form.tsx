"use client";

import { useState } from "react";
import { PaperworkForm, useWalkInOptions } from "@/components/check-in/paperwork-form";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { api, Refusal, type NewDog } from "@/lib/api";
import { cn } from "@/lib/utils";

const SEXES: { value: NonNullable<NewDog["sex"]>; label: string }[] = [
  { value: "female", label: "Female" }, { value: "male", label: "Male" }, { value: "unknown", label: "Not sure" },
];

/** Who the dog belongs to: someone already on file, or a new client. */
export type WalkInFor = { ownerId: string; ownerName: string } | { prefill: { owner?: string; dog?: string } };

/**
 * A walk-in, in two steps: who (the owner, if new, and the dog), then the
 * paper they brought. Saving the first step adds the dog, so a client with no
 * paperwork today is still on file for next time.
 */
export function WalkInForm({ walkIn, groomerId, onDone, onCancel }: {
  walkIn: WalkInFor;
  groomerId: string;
  onDone: (dogId: string) => void;
  onCancel: () => void;
}) {
  const opts = useWalkInOptions();
  const existing = "ownerId" in walkIn ? walkIn : null;
  const prefill = "prefill" in walkIn ? walkIn.prefill : {};
  const [first, ...rest] = (prefill.owner ?? "").trim().split(/\s+/);

  const [owner, setOwner] = useState({ first_name: rest.length ? first : "", last_name: rest.length ? rest.join(" ") : first ?? "",
                                       phone: "", email: "" });
  const [dog, setDog] = useState<NewDog>({ name: prefill.dog ?? "", breed: "", coat: null, sex: null, date_of_birth: null });
  const [coatTouched, setCoatTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<{ dogId: string } | null>(null);
  const today = new Date().toLocaleDateString("en-CA");

  function setBreed(breed: string) {
    // A breed the shop knows suggests its usual coat, until the groomer picks one.
    const known = opts?.breeds.find((b) => b.name.toLowerCase() === breed.trim().toLowerCase());
    setDog((d) => ({ ...d, breed, coat: !coatTouched && known ? known.coat : d.coat }));
  }

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setRefusal(null); setError(null);
    try {
      const who = existing ? { id: existing.ownerId }
        : { ...owner, phone: owner.phone || null, email: owner.email || null };
      const r = await api.addWalkIn(groomerId, { ...dog, breed: dog.breed || null }, who);
      setSaved({ dogId: r.dog_id });
    } catch (err) {
      if (err instanceof Refusal) setRefusal(err);
      else setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  if (saved) {
    return (
      <div className="flex flex-col gap-4">
        <Heading title={`Paperwork for ${dog.name}`}
                 note={`${dog.name} is on file. Did the owner bring vaccination records?`} />
        <PaperworkForm dogId={saved.dogId} dogName={dog.name} groomerId={groomerId}
                       onSaved={() => {}} onClose={() => onDone(saved.dogId)} closeLabel={`Open ${dog.name}'s card`} />
      </div>
    );
  }

  return (
    <form onSubmit={save} className="flex flex-col gap-4">
      <Heading title={existing ? `Another dog for ${existing.ownerName}` : "New client"}
               note="Just the basics. The rest can be filled in at the next visit." />

      {!existing && (
        <Card>
          <CardHeader><CardTitle>Owner</CardTitle></CardHeader>
          <CardContent className="grid gap-3 sm:grid-cols-2">
            <Field label="First name">
              <Input required autoFocus={!prefill.dog} value={owner.first_name}
                     onChange={(e) => setOwner({ ...owner, first_name: e.target.value })} />
            </Field>
            <Field label="Last name">
              <Input required value={owner.last_name} onChange={(e) => setOwner({ ...owner, last_name: e.target.value })} />
            </Field>
            <Field label="Phone">
              <Input type="tel" value={owner.phone} onChange={(e) => setOwner({ ...owner, phone: e.target.value })} />
            </Field>
            <Field label="Email">
              <Input type="email" value={owner.email} onChange={(e) => setOwner({ ...owner, email: e.target.value })} />
            </Field>
            <p className="text-xs text-muted-foreground sm:col-span-2">A phone number or an email, so the shop can reach them.</p>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader><CardTitle>Dog</CardTitle></CardHeader>
        <CardContent className="grid gap-4 sm:grid-cols-2">
          <Field label="Name">
            <Input required autoFocus={!!existing || !!prefill.dog} value={dog.name}
                   onChange={(e) => setDog({ ...dog, name: e.target.value })} />
          </Field>
          <Field label="Breed" note="Pick one, type a new one, or leave it blank.">
            <Input list="known-breeds" value={dog.breed ?? ""} onChange={(e) => setBreed(e.target.value)} />
            <datalist id="known-breeds">
              {opts?.breeds.map((b) => <option key={b.name} value={b.name} />)}
            </datalist>
          </Field>
          <Field group label="Coat" className="sm:col-span-2" note="Decides the clippers, combs and cuts the system suggests.">
            <Choice options={(opts?.coats ?? []).map((c) => ({ value: c.code, label: c.name }))} value={dog.coat}
                    onChange={(coat) => { setCoatTouched(true); setDog({ ...dog, coat }); }} />
          </Field>
          <Field group label="Sex">
            <Choice options={SEXES} value={dog.sex} onChange={(sex) => setDog({ ...dog, sex })} />
          </Field>
          <Field label="Birthday" note="Optional. A puppy needs one so it isn't asked for shots it's too young for.">
            <Input type="date" max={today} value={dog.date_of_birth ?? ""}
                   onChange={(e) => setDog({ ...dog, date_of_birth: e.target.value || null })} />
          </Field>
        </CardContent>
      </Card>

      {refusal && (
        <div role="alert" className="rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">
          <p className="font-medium">{refusal.message}</p>
          {refusal.hint && <p>{refusal.hint}</p>}
        </div>
      )}
      {error && <p role="alert" className="text-sm text-stop">{error}</p>}

      <div className="flex flex-wrap gap-3">
        <Button type="submit" size="lg" disabled={busy || !dog.coat}>
          {busy ? "Saving…" : "Save and add paperwork"}
        </Button>
        <Button type="button" variant="outline" size="lg" onClick={onCancel}>Cancel</Button>
      </div>
      {!dog.coat && <p className="-mt-2 text-sm text-muted-foreground">Choose the coat to save.</p>}
    </form>
  );
}

function Heading({ title, note }: { title: string; note: string }) {
  return (
    <div>
      <h2 className="text-3xl font-semibold tracking-tight">{title}</h2>
      <p className="text-muted-foreground">{note}</p>
    </div>
  );
}

// A label around one input; a plain group around a row of choice buttons,
// since a label would pass a click on its text to the first button.
function Field({ label, note, group = false, className, children }: {
  label: string; note?: string; group?: boolean; className?: string; children: React.ReactNode;
}) {
  const Tag = group ? "div" : "label";
  return (
    <Tag className={cn("flex flex-col gap-1 text-sm", className)}>
      <span className="font-medium">{label}</span>
      {children}
      {note && <span className="text-xs text-muted-foreground">{note}</span>}
    </Tag>
  );
}

function Choice<T extends string>({ options, value, onChange }: {
  options: { value: T; label: string }[]; value: T | null; onChange: (v: T) => void;
}) {
  return (
    <div role="radiogroup" className="flex flex-wrap gap-2">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          onClick={() => onChange(o.value)}
          className={cn(
            "h-10 rounded-[var(--radius)] border px-4 text-sm font-medium transition-colors",
            value === o.value ? "border-primary bg-primary text-primary-foreground" : "border-border bg-card hover:bg-muted",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
