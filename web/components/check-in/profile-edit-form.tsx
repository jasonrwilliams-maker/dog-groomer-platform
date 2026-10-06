"use client";

import { useState } from "react";
import { DogFields, dogToSave, Heading, OwnerFields, ownerToSave, type OwnerDraft } from "@/components/check-in/profile-fields";
import { Problem } from "@/components/check-in/walk-in-form";
import { Button } from "@/components/ui/button";
import { api, Refusal, type CheckInCard, type NewDog } from "@/lib/api";

/**
 * Putting a typo right: the owner's and the dog's details, as on file. Only
 * the half that changed is sent, and the database records each changed field
 * before and after, with who changed it.
 */
export function ProfileEditForm({ card, groomerId, onDone, onCancel }: {
  card: CheckInCard;
  groomerId: string;
  onDone: () => void;
  onCancel: () => void;
}) {
  const p = card.profile;
  const startOwner: OwnerDraft = { first_name: p.first_name, last_name: p.last_name, phone: p.phone ?? "", email: p.email ?? "" };
  const startDog: NewDog = {
    name: p.name, breed: p.breed ?? "", coat: p.coat, is_mixed: p.is_mixed, second_breed: p.is_mixed ? p.second_breed : null,
    new_breed: false, sex: p.sex, date_of_birth: p.date_of_birth,
  };
  const [owner, setOwner] = useState(startOwner);
  const [dog, setDog] = useState(startDog);
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);

  const ownerChanged = JSON.stringify(owner) !== JSON.stringify(startOwner);
  const dogChanged = JSON.stringify(dog) !== JSON.stringify(startDog);
  const others = card.household.other_dogs;

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setRefusal(null); setError(null);
    try {
      if (ownerChanged) await api.editOwner(card.household.owner_id, groomerId, ownerToSave(owner));
      if (dogChanged) await api.editDog(card.dog.id, groomerId, dogToSave(dog));
      onDone();
    } catch (err) {
      if (err instanceof Refusal) setRefusal(err);
      else setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={save} className="flex flex-col gap-4">
      <Heading title={`Edit ${p.name}`} note="Put right anything typed wrong. Every change is recorded, with who made it." />
      <OwnerFields owner={owner} onChange={setOwner} />
      {others.length > 0 && (
        <p className="-mt-2 text-xs text-muted-foreground">
          The owner&apos;s details are shared with {others.join(", ")}: a change here shows on their cards too.
        </p>
      )}
      <DogFields dog={dog} onChange={setDog} coatTouched />
      <Problem refusal={refusal} error={error} />
      <div className="flex flex-wrap gap-3">
        <Button type="submit" size="lg" disabled={busy || !(ownerChanged || dogChanged) || !dog.coat}>
          {busy ? "Saving…" : "Save changes"}
        </Button>
        <Button type="button" variant="outline" size="lg" onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  );
}
