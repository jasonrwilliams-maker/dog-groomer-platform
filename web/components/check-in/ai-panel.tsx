"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { useWalkInOptions } from "@/components/check-in/paperwork-form";
import { api, type AiState } from "@/lib/api";

// Whether the AI is set up on this computer changes only with .env, so ask once.
let status: Promise<{ available: boolean; why_not: string | null }> | null = null;

/**
 * "Have the AI read it", on the check screen. The AI fills the date form in;
 * the person still checks every date against the pages and saves, and what
 * they save is the AI's grade. A name the AI found that the shop has never
 * seen is asked about here, once, and remembered.
 */
export function AiPanel({ documentId, groomerId, state, onState }: {
  documentId: string;
  groomerId: string;
  state: AiState | null;
  onState: (s: AiState) => void;
}) {
  const opts = useWalkInOptions();
  const [available, setAvailable] = useState<{ available: boolean; why_not: string | null } | null>(null);
  const [reading, setReading] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  useEffect(() => {
    status ??= api.aiStatus().catch((e) => { status = null; throw e; });
    status.then(setAvailable).catch(() => setAvailable({ available: false, why_not: "Couldn't ask whether the AI is set up." }));
  }, []);

  async function read() {
    setReading(true); setProblem(null);
    try {
      onState(await api.aiRead(documentId, groomerId));
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e));
    } finally {
      setReading(false);
    }
  }

  async function rule(term: string, vaccine: string | null) {
    setProblem(null);
    try {
      onState(await api.ruleOnTerm(documentId, groomerId, term, vaccine));
    } catch (e) {
      setProblem(e instanceof Error ? e.message : String(e));
    }
  }

  if (!state) return null;
  const done = state.reading !== null && !state.reading.failed ? state : null;
  const found = done ? Object.keys(done.suggestions).length : 0;

  return (
    <div className="flex flex-col gap-3 rounded-[var(--radius)] border border-primary/30 bg-card p-4">
      {!done ? (
        <div className="flex flex-wrap items-center gap-4">
          <Button variant="outline" size="lg" disabled={reading || !available?.available} onClick={read}>
            {reading ? "Reading the pages…" : state.reading?.failed ? "Try the AI again" : "Have the AI read it"}
          </Button>
          <p className="min-w-0 flex-1 text-sm text-muted-foreground">
            {reading
              ? "Usually under a minute. You can keep typing below while it reads."
              : available && !available.available
                ? available.why_not
                : state.reading?.failed
                  ? "The AI's last answer couldn't be used. Try again, or type the dates in."
                  : <>Fills the dates in for you to check. Most reliable on emailed PDFs; on photos, check every date.
                      The pages are sent to Anthropic&apos;s AI service.</>}
          </p>
        </div>
      ) : (
        <p className="text-sm">
          <span className="font-medium">
            {found === 0 ? "The AI didn't find any of the shop's vaccines." :
             `The AI filled in ${found} ${found === 1 ? "vaccine" : "vaccines"}.`}
          </span>{" "}
          <span className="text-muted-foreground">
            Check every date against the pages before saving. What you save is kept as the AI&apos;s score.
          </span>
        </p>
      )}

      {done && done.unfamiliar.length > 0 && (
        <div className="flex flex-col gap-2 border-t border-border pt-3">
          <p className="text-sm font-medium">The AI found names the shop hasn&apos;t seen before. Which vaccine is each?</p>
          <ul className="flex flex-col gap-3">
            {done.unfamiliar.map((u) => (
              <li key={u.line_item_id} className="flex flex-col gap-2">
                <span className="text-sm">
                  &ldquo;{u.term}&rdquo;
                  <span className="text-muted-foreground">
                    {u.administered_on_raw && ` · given ${u.administered_on_raw}`}
                    {u.expires_on_raw && ` · expires ${u.expires_on_raw}`}
                  </span>
                </span>
                <span className="flex flex-wrap gap-2">
                  {(opts?.vaccines ?? []).map((v) => (
                    <Button key={v.code} variant="outline" size="sm" onClick={() => rule(u.term, v.code)}>{v.name}</Button>
                  ))}
                  <Button variant="outline" size="sm" onClick={() => rule(u.term, null)}>Not one we track</Button>
                </span>
              </li>
            ))}
          </ul>
          <p className="text-xs text-muted-foreground">Your answer is remembered for every page after this one.</p>
        </div>
      )}
      {problem && <p role="alert" className="text-sm text-stop">{problem}</p>}
    </div>
  );
}
