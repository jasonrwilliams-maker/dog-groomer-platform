"use client";

import { useMemo, useState } from "react";
import { ListPicker, NotOnList } from "@/components/check-in/list-picker";
import { useWalkInOptions } from "@/components/check-in/paperwork-form";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { api, type NewDog, type NewOwner } from "@/lib/api";
import { cn } from "@/lib/utils";

// The owner and dog fields, shared by signing up a walk-in and by putting a
// typo right, so both read and behave the same.

export type OwnerDraft = { first_name: string; last_name: string; phone: string; email: string };
export const ownerToSave = (o: OwnerDraft): NewOwner =>
  ({ ...o, phone: o.phone || null, email: o.email || null });

export const blankDog: NewDog = {
  name: "", breed: "", coat: null, is_mixed: false, second_breed: null, new_breed: false,
  sex: null, date_of_birth: null,
};
export const dogToSave = (d: NewDog): NewDog =>
  ({ ...d, breed: d.breed || null, second_breed: d.is_mixed ? d.second_breed || null : null });

const SEXES: { value: NonNullable<NewDog["sex"]>; label: string }[] = [
  { value: "female", label: "Female" }, { value: "male", label: "Male" }, { value: "unknown", label: "Not sure" },
];

export function OwnerFields({ owner, onChange, autoFocus }: {
  owner: OwnerDraft; onChange: (o: OwnerDraft) => void; autoFocus?: boolean;
}) {
  return (
    <Card>
      <CardHeader><CardTitle>Owner</CardTitle></CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2">
        <Field label="First name">
          <Input required autoFocus={autoFocus} value={owner.first_name}
                 onChange={(e) => onChange({ ...owner, first_name: e.target.value })} />
        </Field>
        <Field label="Last name">
          <Input required value={owner.last_name} onChange={(e) => onChange({ ...owner, last_name: e.target.value })} />
        </Field>
        <Field label="Phone">
          <Input type="tel" value={owner.phone} onChange={(e) => onChange({ ...owner, phone: e.target.value })} />
        </Field>
        <Field label="Email">
          <Input type="email" value={owner.email} onChange={(e) => onChange({ ...owner, email: e.target.value })} />
        </Field>
        <p className="text-xs text-muted-foreground sm:col-span-2">A phone number or an email, so the shop can reach them.</p>
      </CardContent>
    </Card>
  );
}

export function DogFields({ dog, onChange, autoFocus, coatTouched = false }: {
  dog: NewDog;
  onChange: (d: NewDog) => void;
  autoFocus?: boolean;
  /** Once the groomer has picked a coat, a breed no longer changes it. */
  coatTouched?: boolean;
}) {
  const opts = useWalkInOptions();
  const [picked, setPicked] = useState(coatTouched);
  const today = new Date().toLocaleDateString("en-CA");

  function setBreed(breed: string) {
    // A breed the shop knows suggests its usual coat, until the groomer picks one.
    const known = opts?.breeds.find((b) => b.name.toLowerCase() === breed.trim().toLowerCase());
    onChange({ ...dog, breed, new_breed: false, coat: !picked && known ? known.coat : dog.coat });
  }

  return (
    <Card>
      <CardHeader><CardTitle>Dog</CardTitle></CardHeader>
      <CardContent className="grid gap-4 sm:grid-cols-2">
        <Field label="Name">
          <Input required autoFocus={autoFocus} value={dog.name} onChange={(e) => onChange({ ...dog, name: e.target.value })} />
        </Field>

        <div className="flex flex-col gap-2">
          <BreedInput label={dog.is_mixed ? "Main breed" : "Breed"} value={dog.breed ?? ""} onChange={setBreed}
                      note={dog.is_mixed ? "Leave blank if nobody knows." : "Pick from the list, or leave it blank."} />
          {dog.breed && !dog.new_breed && <BreedNotOnList value={dog.breed} onPick={setBreed}
                                                          onNew={() => onChange({ ...dog, new_breed: true })} />}
          {dog.new_breed && (
            <p className="text-xs text-muted-foreground">
              &ldquo;{dog.breed}&rdquo; will be added to the breed list.{" "}
              <button type="button" className="font-medium text-primary underline-offset-2 hover:underline"
                      onClick={() => onChange({ ...dog, new_breed: false })}>Undo</button>
            </p>
          )}
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" className="size-4 accent-[var(--primary)]" checked={dog.is_mixed}
                   onChange={(e) => onChange({ ...dog, is_mixed: e.target.checked, second_breed: null })} />
            Mixed breed
          </label>
        </div>

        {dog.is_mixed && (
          <div className="flex flex-col gap-2 sm:col-span-2">
            <Field group label="Mixed with">
              <div className="flex flex-wrap items-start gap-2">
                <Choice options={[{ value: "unknown", label: "Unknown" }, { value: "known", label: "A breed I can name" }]}
                        value={dog.second_breed === null ? "unknown" : "known"}
                        onChange={(v) => onChange({ ...dog, second_breed: v === "known" ? "" : null })} />
              </div>
            </Field>
            {dog.second_breed !== null && (
              <div className="flex max-w-sm flex-col gap-2">
                <BreedInput label="Other breed" value={dog.second_breed} autoFocus
                            onChange={(second_breed) => onChange({ ...dog, second_breed })} />
                {dog.second_breed && <BreedNotOnList value={dog.second_breed}
                                                onPick={(second_breed) => onChange({ ...dog, second_breed })} />}
              </div>
            )}
          </div>
        )}

        <Field group label="Coat" className="sm:col-span-2" note="Decides the clippers, combs and cuts the system suggests.">
          <Choice options={(opts?.coats ?? []).map((c) => ({ value: c.code, label: c.name }))} value={dog.coat}
                  onChange={(coat) => { setPicked(true); onChange({ ...dog, coat }); }} />
        </Field>
        <Field group label="Sex">
          <Choice options={SEXES} value={dog.sex} onChange={(sex) => onChange({ ...dog, sex })} />
        </Field>
        <Field label="Birthday" note="Optional. A puppy needs one so it isn't asked for shots it's too young for.">
          <Input type="date" max={today} value={dog.date_of_birth ?? ""}
                 onChange={(e) => onChange({ ...dog, date_of_birth: e.target.value || null })} />
        </Field>
      </CardContent>
    </Card>
  );
}

function BreedInput({ label, value, onChange, note, autoFocus }: {
  label: string; value: string; onChange: (v: string) => void; note?: string; autoFocus?: boolean;
}) {
  const opts = useWalkInOptions();
  const breeds = useMemo(() => (opts?.breeds ?? []).map((b) => ({ name: b.name })), [opts]);
  return (
    // A group, not a label: a click on the open list would otherwise be passed
    // on to the box and open the list again.
    <Field group label={label} note={note}>
      <ListPicker label={label} value={value} onChange={onChange} options={breeds} autoFocus={autoFocus} />
    </Field>
  );
}

function BreedNotOnList({ value, onPick, onNew }: { value: string; onPick: (n: string) => void; onNew?: () => void }) {
  const opts = useWalkInOptions();
  const known = useMemo(() => (opts?.breeds ?? []).map((b) => b.name), [opts]);
  return <NotOnList value={value} known={known} suggest={api.suggestBreeds} what="breed list" onPick={onPick} onNew={onNew} />;
}

export function Heading({ title, note }: { title: string; note: string }) {
  return (
    <div>
      <h2 className="text-3xl font-semibold tracking-tight">{title}</h2>
      <p className="text-muted-foreground">{note}</p>
    </div>
  );
}

// A label around one input; a plain group around a row of choice buttons,
// since a label would pass a click on its text to the first button.
export function Field({ label, note, group = false, className, children }: {
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

export function Choice<T extends string>({ options, value, onChange }: {
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
