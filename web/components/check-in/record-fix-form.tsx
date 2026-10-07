"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { api, Refusal } from "@/lib/api";

// How a manager checked a shot that has no photo behind it. "Something else"
// takes their own words.
const HOW = ["Saw the owner's paper", "Called the vet's office"] as const;
const OTHER = "Something else";

/**
 * A manager's form for one shot on their list: its dates, ready to put right,
 * and — for a shot typed in with no photo — how they checked it.
 *
 *   verify  the shot is waiting to be verified: saving verifies it, with any
 *           fix to the dates
 *   fix     a hand-checked shot whose dates don't match the photo: saving
 *           puts them right, and is its second look
 */
export function RecordFixForm({ mode, recordId, vaccine, given: given0, expires: expires0, groomerId, onSaved, onCancel }: {
  mode: "verify" | "fix"; recordId: string; vaccine: string; given: string; expires: string; groomerId: string;
  onSaved: () => void; onCancel: () => void;
}) {
  const today = new Date().toLocaleDateString("en-CA");      // yyyy-mm-dd, local
  const [given, setGiven] = useState(given0);
  const [expires, setExpires] = useState(expires0);
  const [how, setHow] = useState<string | null>(null);
  const [own, setOwn] = useState("");
  const [saving, setSaving] = useState(false);
  const [problem, setProblem] = useState<{ message: string; hint: string | null } | null>(null);

  const changed = given !== given0 || expires !== expires0;
  const howText = how === OTHER ? own.trim() : how ?? "";
  const ready = mode === "fix" ? changed : howText !== "";

  const save = () => {
    setSaving(true);
    setProblem(null);
    (mode === "fix"
      ? api.fixRecord(recordId, groomerId, given, expires)
      : api.verifyRecord(recordId, groomerId, howText, given, expires))
      .then(onSaved)
      .catch((e) => setProblem(e instanceof Refusal ? { message: e.message, hint: e.hint } : { message: String(e.message ?? e), hint: null }))
      .finally(() => setSaving(false));
  };

  return (
    <div className="mt-3 flex w-full flex-col gap-3 rounded-[var(--radius)] border border-border bg-muted/40 p-3">
      <p className="text-sm text-muted-foreground">
        {mode === "fix"
          ? `Type ${vaccine}'s dates as the photo shows them. Your reading replaces the groomer's; theirs is kept in the history.`
          : `Check ${vaccine}'s dates against the paper or with the vet. Put them right here if they were typed in wrong.`}
      </p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-muted-foreground">Given</span>
          <Input type="date" max={today} value={given} onChange={(e) => { setGiven(e.target.value); setProblem(null); }} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-muted-foreground">Expires</span>
          <Input type="date" value={expires} onChange={(e) => { setExpires(e.target.value); setProblem(null); }} />
        </label>
      </div>

      {mode === "verify" && (
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-sm text-muted-foreground">How did you check it?</legend>
          <div className="flex flex-wrap gap-2">
            {[...HOW, OTHER].map((h) => (
              <Button key={h} type="button" variant="outline" size="sm" aria-pressed={how === h}
                      className={how === h ? "border-primary bg-primary/10 text-primary hover:bg-primary/10" : ""}
                      onClick={() => setHow(h)}>
                {h}
              </Button>
            ))}
          </div>
          {how === OTHER && (
            <Input autoFocus placeholder="How you checked it" value={own} onChange={(e) => setOwn(e.target.value)} />
          )}
        </fieldset>
      )}

      {problem && (
        <div role="alert" className="text-sm text-stop">
          <p className="font-medium">{problem.message}</p>
          {problem.hint && <p>{problem.hint}</p>}
        </div>
      )}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={!ready || saving} onClick={save}>
          {saving ? "Saving…" : mode === "fix" ? "Save the right dates" : changed ? "Save the dates and verify" : "Verify"}
        </Button>
        <Button size="sm" variant="outline" disabled={saving} onClick={onCancel}>Cancel</Button>
      </div>
    </div>
  );
}
