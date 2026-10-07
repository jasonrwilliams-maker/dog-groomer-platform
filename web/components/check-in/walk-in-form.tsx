"use client";

import { useState } from "react";
import { PaperworkIntake } from "@/components/check-in/paperwork-intake";
import {
  blankDog, DogFields, dogToSave, Heading, OwnerFields, ownerToSave, type OwnerDraft,
} from "@/components/check-in/profile-fields";
import { Button } from "@/components/ui/button";
import { api, Refusal, type NewDog } from "@/lib/api";

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
  const existing = "ownerId" in walkIn ? walkIn : null;
  const prefill = "prefill" in walkIn ? walkIn.prefill : {};
  const [first, ...rest] = (prefill.owner ?? "").trim().split(/\s+/);

  const [owner, setOwner] = useState<OwnerDraft>({
    first_name: rest.length ? first : "", last_name: rest.length ? rest.join(" ") : first ?? "", phone: "", email: "",
  });
  const [dog, setDog] = useState<NewDog>({ ...blankDog, name: prefill.dog ?? "" });
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<{ dogId: string } | null>(null);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setRefusal(null); setError(null);
    try {
      const r = await api.addWalkIn(groomerId, dogToSave(dog), existing ? { id: existing.ownerId } : ownerToSave(owner));
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
                 note={`${dog.name} is on file. Did the owner bring vaccination records? Save what they have; the rest can come later.`} />
        <PaperworkIntake dogId={saved.dogId} dogName={dog.name} groomerId={groomerId}
                         onChanged={() => {}} onClose={() => onDone(saved.dogId)}
                         cancelLabel="No paperwork today" closeLabel={`Finish · open ${dog.name}'s card`} />
      </div>
    );
  }

  return (
    <form onSubmit={save} className="flex flex-col gap-4">
      <Heading title={existing ? `Another dog for ${existing.ownerName}` : "New client"}
               note="Just the basics. The rest can be filled in at the next visit." />
      {!existing && <OwnerFields owner={owner} onChange={setOwner} autoFocus={!prefill.dog} />}
      <DogFields dog={dog} onChange={setDog} autoFocus={!!existing || !!prefill.dog} />
      <Problem refusal={refusal} error={error} />
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

export function Problem({ refusal, error }: { refusal: Refusal | null; error: string | null }) {
  if (refusal) {
    return (
      <div role="alert" className="rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">
        <p className="font-medium">{refusal.message}</p>
        {refusal.hint && <p>{refusal.hint}</p>}
      </div>
    );
  }
  return error ? <p role="alert" className="text-sm text-stop">{error}</p> : null;
}
