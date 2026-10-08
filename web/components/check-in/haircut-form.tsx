"use client";

import { useEffect, useState } from "react";
import { Choice, Field } from "@/components/check-in/profile-fields";
import { Problem } from "@/components/check-in/walk-in-form";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  api, Refusal, type CheckInCard, type Cut, type HaircutChange, type HaircutOptions, type HaircutStart, type PlanZone,
} from "@/lib/api";
import { formatDate } from "@/lib/utils";
import { useIsManager } from "@/lib/viewer";

const cutKey = (c: { tool: string; blade_id: string | null; comb_id: string | null }) =>
  `${c.tool}|${c.blade_id ?? ""}|${c.comb_id ?? ""}`;
const capital = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
// One tap fills the reason in; anything else is typed.
const WHY = ["Owner asked", "Coat condition", "Hot weather", "Dog wouldn't settle"];

/** "Teddy Bear, medium · Ears: Scissors" */
export function describeHaircut(style: string, length: string | null, changes: HaircutChange[]) {
  return [[style, length].filter(Boolean).join(", "), ...changes.map((c) => `${c.zone}: ${c.cut}`)].join(" · ");
}

/**
 * The end of a groom: what was done, how the coat was, the haircut zone by
 * zone, a note for next time. The haircut starts from the dog's usual style;
 * the groomer changes only what she did differently. Saving sends the dog home.
 */
export function HaircutForm({ card, groomerId, onCancel, onDone }: {
  card: CheckInCard; groomerId: string; onCancel: () => void; onDone: () => void;
}) {
  const dog = card.dog;
  const manager = useIsManager();
  const [opts, setOpts] = useState<HaircutOptions | null>(null);
  const [start, setStart] = useState<HaircutStart | null>(null);
  const [services, setServices] = useState<Set<string>>(new Set());
  const [condition, setCondition] = useState<number | null>(null);
  const [density, setDensity] = useState<number | null>(null);
  const [style, setStyle] = useState<string | null>(null);
  const [length, setLength] = useState<string | null>(null);
  const [plan, setPlan] = useState<PlanZone[]>([]);
  // Zones cut differently today, by zone code: only the ones that differ from the plan.
  const [changes, setChanges] = useState<Record<string, Cut>>({});
  const [why, setWhy] = useState("");
  const [keep, setKeep] = useState<boolean | null>(null);
  const [overrideReason, setOverrideReason] = useState("");
  const [approvedBy, setApprovedBy] = useState<string | null>(manager ? groomerId : null);
  const [told, setTold] = useState(false);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([api.haircutOptions(), api.haircutStart(dog.id)])
      .then(([o, s]) => {
        setOpts(o); setStart(s);
        setServices(new Set([s.booked_service ?? "full_groom"]));
        if (s.start) { setStyle(s.start.style); setLength(s.start.length); }
      })
      .catch((e) => setError(String(e.message ?? e)));
  }, [dog.id]);

  const chosen = opts?.styles.find((s) => s.code === style) ?? null;
  const shaveDown = chosen?.shave_down ?? false;
  const haircut = !!opts?.services.some((s) => s.haircut && services.has(s.code));
  const ready = !!chosen && (shaveDown || !!length);

  // The coat matters to the plan only for a shave-down.
  const planLength = shaveDown ? null : length;
  const planCoat = shaveDown ? condition : null;
  useEffect(() => {
    if (!style || !ready) { setPlan([]); return; }
    // Quick taps send several requests; only the latest one's answer counts.
    let current = true;
    api.haircutPlan(dog.id, style, planLength, planCoat)
      .then((p) => {
        if (!current) return;
        setPlan(p);
        // Keep today's changes for zones this cut still has, unless they now match it.
        setChanges((ch) => Object.fromEntries(Object.entries(ch).filter(([zone, c]) => {
          const z = p.find((x) => x.zone_code === zone);
          return z && cutKey(z) !== cutKey(c);
        })));
      })
      .catch((e) => { if (current) setError(String(e.message ?? e)); });
    return () => { current = false; };
  }, [dog.id, style, planLength, planCoat, ready]);

  const usual = start?.usual ?? null;
  const differs = !!usual && haircut && ready &&
    (style !== usual.style_code || (!shaveDown && length !== usual.length) || Object.keys(changes).length > 0);
  const keepAsUsual = keep ?? !usual;                       // first haircut: kept unless she says not
  const needsCoat = haircut && shaveDown;
  const belowShave = shaveDown && chosen?.min_coat != null && (condition ?? 0) < chosen.min_coat;
  const pelted = shaveDown && condition != null && opts != null && condition >= opts.pelted_level;
  const needsOk = haircut && ready && (belowShave || !!start?.under_age);

  const missing = [
    services.size === 0 && "tick what was done",
    haircut && !chosen && "pick the style",
    haircut && chosen && !shaveDown && !length && "pick the length",
    needsCoat && condition == null && "say how the coat was",
    condition != null && density == null && "say how thick the coat was",
    differs && !why.trim() && "say why today is different",
    needsOk && !overrideReason.trim() && "give the reason a manager agreed to",
    needsOk && !approvedBy && "pick the manager who OK'd it",
    pelted && !told && "tick that the owner was told",
  ].filter(Boolean) as string[];

  function toggleService(code: string) {
    setServices((s) => { const n = new Set(s); if (n.has(code)) n.delete(code); else n.add(code); return n; });
  }
  function setCut(zone: PlanZone, key: string) {
    const cut = opts?.cuts.find((c) => cutKey(c) === key);
    if (!cut) return;
    setChanges((ch) => {
      const n = { ...ch };
      if (key === cutKey(zone)) delete n[zone.zone_code]; else n[zone.zone_code] = cut;
      return n;
    });
  }

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!start?.visit || missing.length) return;
    setBusy(true); setRefusal(null); setError(null);
    try {
      await api.finishGroom(start.visit.id, {
        groomer_id: groomerId,
        services: [...services],
        coat: condition != null && density != null ? { condition, density, note: null } : null,
        haircut: haircut && style ? {
          style, length: shaveDown ? null : length,
          changes: Object.entries(changes).map(([zone, c]) => ({ zone, tool: c.tool, blade_id: c.blade_id, comb_id: c.comb_id })),
          why_different: differs ? why : null,
          keep_as_usual: !shaveDown && keepAsUsual,
          override_reason: needsOk ? overrideReason : null,
          approved_by: needsOk ? approvedBy : null,
          shave_acknowledged: pelted && told,
        } : null,
        note: note.trim() || null,
      });
      onDone();
    } catch (err) {
      if (err instanceof Refusal) setRefusal(err);
      else setError(err instanceof Error ? err.message : String(err));
    } finally {
      setBusy(false);
    }
  }

  if (!opts || !start) {
    return <p className="text-muted-foreground">{error ?? "Getting the haircut ready…"}</p>;
  }
  if (!start.visit) {
    return (
      <div className="flex flex-col gap-3">
        <p>{dog.name}&apos;s groom is already finished, or hasn&apos;t started today.</p>
        <Button variant="outline" className="self-start" onClick={onCancel}>Back to {dog.name}</Button>
      </div>
    );
  }

  const styleZones = plan.filter((z) => !z.is_hygiene);
  const hygiene = plan.filter((z) => z.is_hygiene);
  const groups = (["Blade", "Comb", "Other"] as const).map((k) => ({ k, cuts: opts.cuts.filter((c) => c.kind === k) }));

  const zoneRow = (z: PlanZone) => {
    const today = changes[z.zone_code];
    return (
      <li key={z.zone_code} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2">
        <span className="w-36 font-medium">{z.zone}</span>
        <select
          aria-label={`${z.zone} cut`}
          value={cutKey(today ?? z)}
          onChange={(e) => setCut(z, e.target.value)}
          className="h-10 min-w-44 rounded-[var(--radius)] border border-border bg-card px-2 text-base"
        >
          {groups.map((g) => (
            <optgroup key={g.k} label={g.k === "Blade" ? "Blades" : g.k === "Comb" ? "Combs (on a #30)" : "No clipper"}>
              {g.cuts.map((c) => <option key={cutKey(c)} value={cutKey(c)}>{c.label}</option>)}
            </optgroup>
          ))}
        </select>
        {today ? (
          <>
            <Badge tone="warn">Today: was {z.cut}</Badge>
            <Button type="button" variant="outline" size="sm" onClick={() => setCut(z, cutKey(z))}>Undo</Button>
          </>
        ) : z.source === "usual" ? (
          <Badge>{dog.name}&apos;s usual</Badge>
        ) : null}
      </li>
    );
  };

  return (
    <form onSubmit={save} className="flex flex-col gap-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight">Record the haircut</h2>
          <p className="text-muted-foreground">
            {dog.name} · checked in by {start.visit.groomer}. Saving finishes the groom.
          </p>
        </div>
        <Button type="button" variant="outline" onClick={onCancel}>Back to {dog.name}</Button>
      </div>

      {(usual || start.last) && (
        <div className="rounded-[var(--radius)] border border-border bg-muted p-3 text-sm">
          {usual && (
            <p><span className="font-medium">Usual style:</span> {describeHaircut(usual.style, usual.length, usual.changes)}</p>
          )}
          {start.last && (
            <p className="text-muted-foreground">
              Last time ({formatDate(start.last.visit_date)}, {start.last.groomer}):{" "}
              {describeHaircut(start.last.style, start.last.length, start.last.changes.filter((c) => c.today))}
              {start.last.deviation_reason && <> · &ldquo;{start.last.deviation_reason}&rdquo;</>}
            </p>
          )}
        </div>
      )}

      <Card>
        <CardHeader><CardTitle>What was done</CardTitle></CardHeader>
        <CardContent>
          <div className="flex flex-wrap gap-2" role="group" aria-label="Services">
            {opts.services.map((s) => (
              <button key={s.code} type="button" role="checkbox" aria-checked={services.has(s.code)}
                      onClick={() => toggleService(s.code)}
                      className={services.has(s.code)
                        ? "h-10 rounded-[var(--radius)] border border-primary bg-primary px-4 text-sm font-medium text-primary-foreground"
                        : "h-10 rounded-[var(--radius)] border border-border bg-card px-4 text-sm font-medium hover:bg-muted"}>
                {services.has(s.code) ? "✓ " : ""}{s.name}
              </button>
            ))}
          </div>
          {!haircut && services.size > 0 && (
            <p className="mt-2 text-sm text-muted-foreground">No haircut on this visit. Tick Full groom to record one.</p>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle>The coat</CardTitle></CardHeader>
        <CardContent className="flex flex-col gap-3">
          <Field label="Condition" group note={needsCoat ? "Needed for a shave-down." : undefined}>
            <Choice options={opts.coat_condition.map((c) => ({ value: String(c.level), label: `${c.level} · ${c.label}` }))}
                    value={condition == null ? null : String(condition)} onChange={(v) => setCondition(Number(v))} />
          </Field>
          <Field label="Thickness" group>
            <Choice options={opts.coat_density.map((c) => ({ value: String(c.level), label: c.label }))}
                    value={density == null ? null : String(density)} onChange={(v) => setDensity(Number(v))} />
          </Field>
        </CardContent>
      </Card>

      {haircut && (
        <Card>
          <CardHeader><CardTitle>The haircut</CardTitle></CardHeader>
          <CardContent className="flex flex-col gap-4">
            <Field label="Style" group note={chosen?.description ?? undefined}>
              <Choice options={opts.styles.map((s) => ({ value: s.code, label: s.shave_down ? "Shave-down" : s.name }))}
                      value={style} onChange={setStyle} />
            </Field>
            {chosen && !shaveDown && (
              <Field label="Length" group>
                <Choice options={opts.lengths.map((l) => ({ value: l, label: capital(l) }))} value={length} onChange={setLength} />
              </Field>
            )}

            {shaveDown && condition != null && !belowShave && !pelted && (
              <p role="status" className="rounded-[var(--radius)] border border-warn/30 bg-warn-soft p-3 text-sm text-warn">
                Matted all over: a #7F shave-down. Let the owner know it will be short, and why.
              </p>
            )}
            {pelted && (
              <label className="flex items-start gap-3 rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">
                <input type="checkbox" className="mt-1 size-5" checked={told} onChange={(e) => setTold(e.target.checked)} />
                <span>
                  <span className="block font-medium">Pelted: shaved close with a #10.</span>
                  I&apos;ve told the owner it can leave the skin red, itchy or nicked, and the coat takes months to grow back.
                </span>
              </label>
            )}

            {styleZones.length > 0 && (
              <div>
                <p className="text-sm font-medium">Zone by zone</p>
                <p className="text-xs text-muted-foreground">Change only what you did differently.</p>
                <ul className="mt-1 divide-y divide-border">{styleZones.map(zoneRow)}</ul>
                {hygiene.length > 0 && (
                  <details className="mt-2">
                    <summary className="cursor-pointer text-sm text-muted-foreground hover:text-foreground">
                      Hygiene: {hygiene.map((z) => `${z.zone} ${changes[z.zone_code]?.label ?? z.cut}`).join(" · ")}
                    </summary>
                    <ul className="divide-y divide-border">{hygiene.map(zoneRow)}</ul>
                  </details>
                )}
              </div>
            )}

            {differs && (
              <Field label={`Why is it different from ${dog.name}'s usual today?`} group>
                <div className="flex flex-wrap gap-2">
                  {WHY.map((w) => (
                    <Button key={w} type="button" variant="outline" size="sm" onClick={() => setWhy(w)}>{w}</Button>
                  ))}
                </div>
                <Input value={why} onChange={(e) => setWhy(e.target.value)} placeholder="Owner asked for shorter for summer" />
              </Field>
            )}

            {needsOk && (
              <div className="flex flex-col gap-3 rounded-[var(--radius)] border border-todo-border bg-todo p-3">
                <p className="text-sm font-medium">
                  {belowShave
                    ? `A coat at level ${condition ?? "—"} doesn't call for a shave-down. It can go ahead with a manager's OK.`
                    : `${dog.name} is under the shop's grooming age. A haircut needs a manager's OK.`}
                </p>
                <Field label="Reason">
                  <Input value={overrideReason} onChange={(e) => setOverrideReason(e.target.value)}
                         placeholder={belowShave ? "Owner wants it all off for the summer" : "Face and feet tidy only, owner asked"} />
                </Field>
                <Field label="OK'd by" group>
                  <Choice options={opts.managers.map((m) => ({ value: m.id, label: m.name }))}
                          value={approvedBy} onChange={setApprovedBy} />
                </Field>
              </div>
            )}

            {ready && !shaveDown && (
              <label className="flex items-start gap-3 text-sm">
                <input type="checkbox" className="mt-0.5 size-5" checked={keepAsUsual} onChange={(e) => setKeep(e.target.checked)} />
                <span>
                  {usual ? `Make this ${dog.name}'s usual style from now on` : `Keep this as ${dog.name}'s usual style`}
                  <span className="block text-xs text-muted-foreground">The next groom starts from it.</span>
                </span>
              </label>
            )}
          </CardContent>
        </Card>
      )}

      <Field label="Notes for next time">
        <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2}
                  placeholder="How it went, anything the next groomer should know"
                  className="rounded-[var(--radius)] border border-border bg-card px-3 py-2 text-base focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring" />
      </Field>

      <Problem refusal={refusal} error={error} />
      <div className="flex flex-wrap items-center gap-3">
        <Button type="submit" variant="go" size="lg" disabled={busy || missing.length > 0}>
          {busy ? "Saving…" : "Save and finish the groom"}
        </Button>
        {missing.length > 0 && <span className="text-sm text-muted-foreground">To finish: {missing.join(", ")}.</span>}
      </div>
    </form>
  );
}
