"use client";

import { useMemo, useState } from "react";
import { ListPicker, NotOnList } from "@/components/check-in/list-picker";
import { useWalkInOptions } from "@/components/check-in/paperwork-form";
import { Choice, Field } from "@/components/check-in/profile-fields";
import { Problem } from "@/components/check-in/walk-in-form";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { api, Refusal, type Allergy, type AllergySource, type AllergyType } from "@/lib/api";
import { cn } from "@/lib/utils";

// What each group changes for the groomer, in the order the card shows them.
export const ALLERGY_TYPES: Record<AllergyType, { label: string; hint: string }> = {
  contact:       { label: "Contact",       hint: "Don't put it on the dog" },
  flea:          { label: "Flea",          hint: "Check for fleas; go gently on irritated skin" },
  environmental: { label: "Environmental", hint: "Expect itchy paws, ears and belly" },
  food:          { label: "Food",          hint: "Mind the treats" },
};
const GROUP_HEADINGS = Object.fromEntries(
  Object.entries(ALLERGY_TYPES).map(([k, v]) => [k, `${v.label} · ${v.hint.toLowerCase()}`]));

const SEVERITIES = [
  { value: "1", label: "Mild" }, { value: "2", label: "Moderate" },
  { value: "3", label: "Severe" }, { value: "4", label: "Dangerous" },
];
const SOURCES: { value: AllergySource; label: string }[] = [
  { value: "owner_reported", label: "Owner says" },
  { value: "observed", label: "We saw it" },
  { value: "vet_documented", label: "Vet's records" },
];
const SOURCE_WORDS = Object.fromEntries(SOURCES.map((s) => [s.value, s.label])) as Record<string, string>;

/**
 * The dog's allergies, worst-to-know first (contact, then the rest), with
 * adding, changing and taking off. Anything that leaves the dog less
 * protected asks for a reason, and goes on the manager's list.
 */
export function AllergyCard({ dogId, allergies, groomerId, onChanged }: {
  dogId: string; allergies: Allergy[]; groomerId: string; onChanged: () => void;
}) {
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);

  return (
    <Card className={cn(allergies.length > 0 && "border-stop/30")}>
      <CardHeader className="flex-row items-center justify-between gap-2">
        <CardTitle className={cn(allergies.length > 0 && "text-stop")}>Allergies</CardTitle>
        {!adding && <Button variant="ghost" size="sm" className="text-primary" onClick={() => setAdding(true)}>+ Add</Button>}
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {allergies.length === 0 && !adding && <p className="text-sm text-muted-foreground">No known allergies.</p>}
        <ul className="flex flex-col gap-3">
          {allergies.map((a, i) => (
            <li key={a.id}>
              {a.type !== allergies[i - 1]?.type && (
                <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {ALLERGY_TYPES[a.type].label} · {ALLERGY_TYPES[a.type].hint.toLowerCase()}
                </p>
              )}
              {editing === a.id ? (
                <EditAllergy allergy={a} groomerId={groomerId}
                             onDone={() => { setEditing(null); onChanged(); }} onCancel={() => setEditing(null)} />
              ) : (
                <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                  <span className="font-medium">{a.allergen}</span>
                  <Badge tone={a.severity >= 3 ? "stop" : "warn"}>{a.severity_label}</Badge>
                  <span className="text-xs text-muted-foreground">{SOURCE_WORDS[a.source]}</span>
                  <button className="ml-auto text-sm font-medium text-primary underline-offset-2 hover:underline"
                          onClick={() => setEditing(a.id)}>Change</button>
                  {a.note && <span className="w-full text-sm text-muted-foreground">{a.note}</span>}
                </div>
              )}
            </li>
          ))}
        </ul>
        {adding && <AddAllergy dogId={dogId} groomerId={groomerId} taken={allergies.map((a) => a.allergen)}
                               onDone={() => { setAdding(false); onChanged(); }} onCancel={() => setAdding(false)} />}
      </CardContent>
    </Card>
  );
}

function AddAllergy({ dogId, groomerId, taken, onDone, onCancel }: {
  dogId: string; groomerId: string; taken: string[]; onDone: () => void; onCancel: () => void;
}) {
  const opts = useWalkInOptions();
  const options = useMemo(() => (opts?.allergens ?? []).map((a) => ({ name: a.name, group: a.type })), [opts]);
  const known = useMemo(() => options.map((o) => o.name), [options]);
  const [allergen, setAllergen] = useState("");
  const [isNew, setIsNew] = useState(false);
  const [type, setType] = useState<AllergyType | null>(null);
  const [severity, setSeverity] = useState<string | null>(null);
  const [source, setSource] = useState<AllergySource>("owner_reported");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);

  const onList = known.some((k) => k.toLowerCase() === allergen.trim().toLowerCase());
  const ready = allergen.trim() && severity && (onList || (isNew && type));

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!ready) return;
    setBusy(true); setRefusal(null); setError(null);
    try {
      await api.addAllergy(dogId, groomerId, {
        allergen, severity: Number(severity), source, note: note || null, new_allergen: isNew, type: isNew ? type : null,
      });
      onDone();
    } catch (err) {
      if (err instanceof Refusal) setRefusal(err);
      else setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={save} className="flex flex-col gap-3 rounded-[var(--radius)] border border-border bg-muted/40 p-3">
      <Field group label="Allergic to">
        <ListPicker label="Allergy" value={allergen} autoFocus placeholder="Pick or type, e.g. oatmeal, chicken, fleas"
                    options={options.filter((o) => !taken.includes(o.name))} groupLabels={GROUP_HEADINGS}
                    onChange={(v) => { setAllergen(v); setIsNew(false); }} />
      </Field>
      {allergen.trim() && !isNew && (
        <NotOnList value={allergen} known={known} suggest={api.suggestAllergens} what="allergy list"
                   onPick={setAllergen} onNew={() => setIsNew(true)} />
      )}
      {isNew && (
        <Field group label={`What kind of allergy is "${allergen.trim()}"?`}>
          <Choice options={(Object.keys(ALLERGY_TYPES) as AllergyType[]).map((t) => ({ value: t, label: ALLERGY_TYPES[t].label }))}
                  value={type} onChange={setType} />
        </Field>
      )}
      <Field group label="How bad">
        <Choice options={SEVERITIES} value={severity} onChange={setSeverity} />
      </Field>
      <Field group label="Who says so">
        <Choice options={SOURCES} value={source} onChange={setSource} />
      </Field>
      <Field label="Note" note="Optional. What happens, or what to use instead.">
        <Input value={note} onChange={(e) => setNote(e.target.value)} />
      </Field>
      <Problem refusal={refusal} error={error} />
      <div className="flex flex-wrap gap-2">
        <Button type="submit" disabled={busy || !ready}>{busy ? "Saving…" : "Add allergy"}</Button>
        <Button type="button" variant="outline" onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  );
}

function EditAllergy({ allergy, groomerId, onDone, onCancel }: {
  allergy: Allergy; groomerId: string; onDone: () => void; onCancel: () => void;
}) {
  const [severity, setSeverity] = useState(String(allergy.severity));
  const [source, setSource] = useState(allergy.source);
  const [note, setNote] = useState(allergy.note ?? "");
  const [reason, setReason] = useState("");
  const [removing, setRemoving] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Less protection for the dog: say why, and a manager will see it.
  const weaker = removing || Number(severity) < allergy.severity;
  const changed = removing || Number(severity) !== allergy.severity || source !== allergy.source || note !== (allergy.note ?? "");

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setRefusal(null); setError(null);
    try {
      if (removing) await api.removeAllergy(allergy.id, groomerId, reason);
      else await api.editAllergy(allergy.id, groomerId, { severity: Number(severity), source, note: note || null,
                                                         reason: reason || null });
      onDone();
    } catch (err) {
      if (err instanceof Refusal) setRefusal(err);
      else setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={save} className="flex flex-col gap-3 rounded-[var(--radius)] border border-border bg-muted/40 p-3">
      <p className="font-medium">{allergy.allergen}</p>
      {!removing && (
        <>
          <Field group label="How bad"><Choice options={SEVERITIES} value={severity} onChange={setSeverity} /></Field>
          <Field group label="Who says so"><Choice options={SOURCES} value={source} onChange={setSource} /></Field>
          <Field label="Note"><Input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
        </>
      )}
      {removing && <p className="text-sm">This takes {allergy.allergen} off the dog&apos;s allergies. It stays on file as removed.</p>}
      {weaker && (
        <Field label="Why?" note="Required. This leaves the dog less protected, so a manager will look at it.">
          <Input required autoFocus value={reason} onChange={(e) => setReason(e.target.value)}
                 placeholder={removing ? "e.g. entered on the wrong dog" : "e.g. vet says it was a one-off"} />
        </Field>
      )}
      <Problem refusal={refusal} error={error} />
      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" variant={removing ? "outline" : "default"}
                className={cn(removing && "border-stop/40 text-stop hover:bg-stop-soft")}
                disabled={busy || !changed || (weaker && !reason.trim())}>
          {busy ? "Saving…" : removing ? "Take it off" : "Save"}
        </Button>
        <Button type="button" variant="outline" onClick={removing ? () => setRemoving(false) : onCancel}>Cancel</Button>
        {!removing && (
          <button type="button" className="ml-auto text-sm text-stop underline-offset-2 hover:underline"
                  onClick={() => setRemoving(true)}>Take this allergy off</button>
        )}
      </div>
    </form>
  );
}
