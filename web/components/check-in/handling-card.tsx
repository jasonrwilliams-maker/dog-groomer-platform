"use client";

import { useState } from "react";
import { useWalkInOptions } from "@/components/check-in/paperwork-form";
import { Choice, Field } from "@/components/check-in/profile-fields";
import { Problem } from "@/components/check-in/walk-in-form";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { api, Refusal, type BehaviourNote, type NewBehaviour } from "@/lib/api";
import { formatDate } from "@/lib/utils";

export const TRIGGERS: { value: string; label: string }[] = [
  { value: "dryer", label: "Dryer" }, { value: "clippers", label: "Clippers" }, { value: "scissors", label: "Scissors" },
  { value: "nail_grinder", label: "Nail grinder" }, { value: "brushing", label: "Brushing" }, { value: "bath", label: "Bath" },
  { value: "water", label: "Water" }, { value: "restraint", label: "Being held" }, { value: "table", label: "The table" },
  { value: "other_dogs", label: "Other dogs" }, { value: "noise", label: "Loud noise" }, { value: "other", label: "Other" },
];
const TRIGGER_WORDS = Object.fromEntries(TRIGGERS.map((t) => [t.value, t.label])) as Record<string, string>;

const DIFFICULTY = [
  { value: "1", label: "Easy" }, { value: "2", label: "Some care" }, { value: "3", label: "Needs care" },
  { value: "4", label: "Two people" }, { value: "5", label: "Specialist only" },
];

/**
 * Handling notes are a history: what a groomer saw, on a day. When one stops
 * being true, a newer note says so; only a typo is corrected in place.
 */
export function HandlingCard({ dogId, notes, groomerId, onChanged }: {
  dogId: string; notes: BehaviourNote[]; groomerId: string; onChanged: () => void;
}) {
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between gap-2">
        <CardTitle>Handling</CardTitle>
        {!adding && <Button variant="ghost" size="sm" className="text-primary" onClick={() => setAdding(true)}>+ Add note</Button>}
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {adding && (
          <NoteForm groomerId={groomerId} saveLabel="Add note"
                    save={(b) => api.addBehaviour(dogId, groomerId, b)}
                    onDone={() => { setAdding(false); onChanged(); }} onCancel={() => setAdding(false)} />
        )}
        {notes.length === 0 && !adding && <p className="text-sm text-muted-foreground">No handling notes yet.</p>}
        <ul className="flex flex-col gap-3">
          {notes.map((b, i) => (
            <li key={b.id}>
              {editing === b.id ? (
                <NoteForm groomerId={groomerId} start={b} saveLabel="Save change"
                          save={(n) => api.correctBehaviour(b.id, groomerId, n)}
                          onDone={() => { setEditing(null); onChanged(); }} onCancel={() => setEditing(null)} />
              ) : (
                <div className={i > 0 ? "opacity-80" : undefined}>
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge tone={b.difficulty >= 4 ? "stop" : b.difficulty === 3 ? "warn" : "ok"}>{b.difficulty_label}</Badge>
                    <span className="text-sm text-muted-foreground">
                      {[b.trigger && TRIGGER_WORDS[b.trigger], b.zone].filter(Boolean).join(" · ")}
                    </span>
                  </div>
                  {b.note && <p className="mt-1 text-sm">{b.note}</p>}
                  <div className="flex items-baseline justify-between gap-2">
                    <p className="text-xs text-muted-foreground">
                      {formatDate(b.observed_on)}{b.observed_by && ` · ${b.observed_by}`}{i === 0 && notes.length > 1 && " · latest"}
                    </p>
                    <button className="text-sm font-medium text-primary underline-offset-2 hover:underline"
                            onClick={() => setEditing(b.id)}>Change</button>
                  </div>
                </div>
              )}
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}

function NoteForm({ start, saveLabel, save, onDone, onCancel }: {
  groomerId: string;
  start?: BehaviourNote;
  saveLabel: string;
  save: (b: NewBehaviour) => Promise<unknown>;
  onDone: () => void;
  onCancel: () => void;
}) {
  const opts = useWalkInOptions();
  const [difficulty, setDifficulty] = useState<string | null>(start ? String(start.difficulty) : null);
  const [trigger, setTrigger] = useState<string | null>(start?.trigger ?? null);
  const [zone, setZone] = useState<string | null>(start?.zone_code ?? null);
  const [note, setNote] = useState(start?.note ?? "");
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!difficulty) return;
    setBusy(true); setRefusal(null); setError(null);
    try {
      await save({ difficulty: Number(difficulty), trigger, zone, note: note || null });
      onDone();
    } catch (err) {
      if (err instanceof Refusal) setRefusal(err);
      else setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  // Tapping a chosen trigger or body part again clears it: both are optional.
  const toggle = (set: (v: string | null) => void, current: string | null) => (v: string) => set(v === current ? null : v);

  return (
    <form onSubmit={submit} className="flex flex-col gap-3 rounded-[var(--radius)] border border-border bg-muted/40 p-3">
      {start && <p className="text-xs text-muted-foreground">For putting right what was typed wrong. If the dog has changed, add a new note instead, so the history shows it.</p>}
      <Field group label="How hard to handle">
        <Choice options={DIFFICULTY} value={difficulty} onChange={setDifficulty} />
      </Field>
      <Field group label="What sets it off" note="Optional.">
        <Choice options={TRIGGERS} value={trigger} onChange={toggle(setTrigger, trigger)} />
      </Field>
      <Field group label="Where on the dog" note="Optional.">
        <Choice options={(opts?.zones ?? []).map((z) => ({ value: z.code, label: z.name }))} value={zone}
                onChange={toggle(setZone, zone)} />
      </Field>
      <Field label="What happens, and what helps">
        <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Fine with the stand dryer on low" />
      </Field>
      <Problem refusal={refusal} error={error} />
      <div className="flex flex-wrap gap-2">
        <Button type="submit" disabled={busy || !difficulty}>{busy ? "Saving…" : saveLabel}</Button>
        <Button type="button" variant="outline" onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  );
}
