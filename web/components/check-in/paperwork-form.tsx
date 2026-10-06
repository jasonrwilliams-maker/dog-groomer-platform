"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { api, Refusal, type WalkInOptions } from "@/lib/api";
import { cn } from "@/lib/utils";

// The vaccines and choices the forms offer change only when the shop's
// configuration does, so one fetch serves every form on the page.
let options: Promise<WalkInOptions> | null = null;
export function useWalkInOptions(): WalkInOptions | null {
  const [value, setValue] = useState<WalkInOptions | null>(null);
  useEffect(() => {
    options ??= api.walkInOptions().catch((e) => { options = null; throw e; });
    options.then(setValue).catch(() => setValue(null));
  }, []);
  return value;
}

type Line = { given: string; expires: string; saved: boolean; refusal: Refusal | null; error: string | null };
const blank: Line = { given: "", expires: "", saved: false, refusal: null, error: null };

/** One line per vaccine the shop tracks: the two dates, typed off the paper. */
export function PaperworkForm({ dogId, dogName, groomerId, onSaved, onClose, closeLabel = "Done" }: {
  dogId: string;
  dogName: string;
  groomerId: string;
  onSaved: () => void;
  onClose: () => void;
  closeLabel?: string;
}) {
  const opts = useWalkInOptions();
  const [lines, setLines] = useState<Record<string, Line>>({});
  const [busy, setBusy] = useState(false);
  const today = new Date().toLocaleDateString("en-CA");      // yyyy-mm-dd, local

  const line = (code: string) => lines[code] ?? blank;
  const set = (code: string, patch: Partial<Line>) =>
    setLines((ls) => ({ ...ls, [code]: { ...(ls[code] ?? blank), ...patch } }));

  const toSave = (opts?.vaccines ?? []).filter((v) => {
    const l = line(v.code);
    return !l.saved && (l.given || l.expires);
  });

  async function save() {
    setBusy(true);
    let any = false;
    for (const v of toSave) {
      const l = line(v.code);
      set(v.code, { refusal: null, error: null });
      try {
        await api.addShot(dogId, groomerId, v.code, l.given || null, l.expires || null);
        set(v.code, { saved: true });
        any = true;
      } catch (e) {
        if (e instanceof Refusal) set(v.code, { refusal: e });
        else set(v.code, { error: e instanceof Error ? e.message : String(e) });
      }
    }
    setBusy(false);
    if (any) onSaved();
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Type the dates exactly as {dogName}&apos;s paper prints them. A shot with no expiry date on the paper
        can&apos;t be recorded: the system never guesses one. Shots entered here count for today&apos;s groom,
        and a manager checks them against the paper later.
      </p>

      {!opts ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : (
        <ul className="flex flex-col divide-y divide-border rounded-[var(--radius)] border border-border bg-card">
          {opts.vaccines.map((v) => {
            const l = line(v.code);
            return (
              <li key={v.code} className={cn("flex flex-col gap-2 p-4", l.saved && "bg-ok-soft")}>
                <div className="flex items-baseline justify-between gap-2">
                  <span className="font-medium">
                    {v.name}
                    {v.required && <span className="ml-2 text-xs font-normal text-muted-foreground">required by law</span>}
                  </span>
                  {l.saved && <span className="text-sm font-medium text-ok">Saved · awaiting verification</span>}
                </div>
                {!l.saved && (
                  <div className="grid gap-3 sm:grid-cols-2">
                    <label className="flex flex-col gap-1 text-sm">
                      <span className="text-muted-foreground">Given</span>
                      <Input type="date" max={today} value={l.given}
                             onChange={(e) => set(v.code, { given: e.target.value, refusal: null })} />
                    </label>
                    <label className="flex flex-col gap-1 text-sm">
                      <span className="text-muted-foreground">Expires</span>
                      <Input type="date" value={l.expires}
                             onChange={(e) => set(v.code, { expires: e.target.value, refusal: null })} />
                    </label>
                  </div>
                )}
                {l.refusal && (
                  <div role="alert" className="text-sm text-stop">
                    <p className="font-medium">{l.refusal.message}</p>
                    {l.refusal.hint && <p>{l.refusal.hint}</p>}
                  </div>
                )}
                {l.error && <p role="alert" className="text-sm text-stop">{l.error}</p>}
              </li>
            );
          })}
        </ul>
      )}

      <div className="flex flex-wrap items-center gap-3">
        <Button size="lg" disabled={busy || toSave.length === 0} onClick={save}>
          {busy ? "Saving…" : toSave.length > 1 ? `Save ${toSave.length} shots` : "Save shot"}
        </Button>
        <Button variant="outline" size="lg" onClick={onClose}>{closeLabel}</Button>
      </div>
    </div>
  );
}
