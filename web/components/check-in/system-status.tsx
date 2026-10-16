"use client";

import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { api, type SystemStatus } from "@/lib/api";
import { cn } from "@/lib/utils";

const HOW = { built: "When it was built", baseline: "Already there", update: "Added by an update" } as const;

/** "Oct 16, 2026, 9:38 PM", in the shop's own time. */
function when(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric",
                                                  hour: "numeric", minute: "2-digit" });
}

/** "2 hours ago", for how old the newest backup is. */
function ago(iso: string | null): string {
  if (!iso) return "";
  const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 2) return "just now";
  if (mins < 60) return `${mins} minutes ago`;
  const hours = Math.round(mins / 60);
  if (hours < 48) return `${hours} ${hours === 1 ? "hour" : "hours"} ago`;
  return `${Math.round(hours / 24)} days ago`;
}

function megabytes(bytes: number): string {
  return bytes < 1024 * 1024 ? `${Math.max(1, Math.round(bytes / 1024))} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** What the card on the Admin overview says: the one thing to know first. */
export function systemHeadline(s: SystemStatus | null): { text: string; tone: "ok" | "warn" | "stop" } {
  if (!s) return { text: "Checking…", tone: "warn" };
  if (!s.update.ok) return { text: "The last update failed", tone: "stop" };
  if (s.waiting.length) return { text: "New sections wait for a restart", tone: "warn" };
  if (!s.backups.length) return { text: "Up to date · no backups yet", tone: "warn" };
  return { text: `Up to date · last backup ${ago(s.backups[0].made_utc)}`, tone: "ok" };
}

/**
 * Database and backups, from Admin: how the last start's update went, every
 * section of the shop's rules the database holds, and every backup. A manager
 * can take a backup here; restoring is done from the records tool (SOP
 * SYS-08), since it replaces the shop's data.
 */
export function SystemScreen({ onChanged }: { onChanged?: () => void }) {
  const [status, setStatus] = useState<SystemStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const [allSections, setAllSections] = useState(false);

  const load = () => api.systemStatus().then(setStatus).catch((e) => setError(String(e.message ?? e)));
  useEffect(() => { load(); }, []);

  async function backUp() {
    setBusy(true); setError(null); setDone(null);
    try {
      const b = await api.backUpNow();
      setDone(`Backup saved: ${b.name} (${megabytes(b.bytes)}).`);
      load(); onChanged?.();
    } catch (e) {
      setError(String((e as Error).message ?? e));
    } finally {
      setBusy(false);
    }
  }

  if (!status) {
    return error
      ? <p role="alert" className="rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">{error}</p>
      : <p className="text-muted-foreground">Loading…</p>;
  }

  const { update } = status;
  const added = status.sections.filter((s) => s.how === "update");
  const shown = allSections ? status.sections : status.sections.slice(0, 8);

  return (
    <div className="flex flex-col gap-4">
      {/* The update on the last start. */}
      <Card className={cn(!update.ok && "border-stop/30 bg-stop-soft")}>
        <CardHeader>
          <CardTitle>The shop&apos;s database</CardTitle>
          <p className="text-sm text-muted-foreground">
            Each time the app starts, it adds any new sections of the shop&apos;s rules, after a backup.
          </p>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 text-sm">
          {update.ok ? (
            <p>
              <Badge tone="ok">Up to date</Badge>{" "}
              Holds all {status.section_files} sections. Last checked {when(update.checked_at)}
              {update.applied.length > 0 && <>, when it added {update.applied.join(", ")}</>}.
            </p>
          ) : (
            <div className="text-stop">
              <p><Badge tone="stop">Update failed</Badge> {when(update.checked_at)}</p>
              <p className="mt-1">
                <span className="font-mono">{update.failed_file}</span> could not be added, so the update stopped
                there. The database is as it was before that section.
                {update.backup && <> A backup was taken first: <span className="font-mono">{update.backup}</span>.</>}
              </p>
              {update.message && <pre className="mt-2 whitespace-pre-wrap text-xs">{update.message}</pre>}
            </div>
          )}
          {status.waiting.length > 0 && (
            <p className="rounded-[var(--radius)] border border-warn/30 bg-warn-soft p-3 text-warn">
              Waiting for the app to restart: {status.waiting.join(", ")}. They are added, after a backup, the
              next time the app starts.
            </p>
          )}

          <div>
            <p className="mb-1 font-medium">
              Sections in the database
              {added.length > 0 && <span className="font-normal text-muted-foreground"> · {added.length} added by updates</span>}
            </p>
            <ul className="divide-y divide-border rounded-[var(--radius)] border border-border bg-card">
              {shown.map((s) => (
                <li key={s.file} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
                  <span className="font-mono text-xs">{s.file}</span>
                  <span className="text-xs text-muted-foreground">
                    {HOW[s.how]}{s.how === "update" && <> · {when(s.applied_at)}</>}
                  </span>
                </li>
              ))}
            </ul>
            {status.sections.length > 8 && (
              <Button variant="outline" size="sm" className="mt-2" onClick={() => setAllSections((a) => !a)}>
                {allSections ? "Show fewer" : `Show all ${status.sections.length}`}
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      {/* The backups. */}
      <Card>
        <CardHeader>
          <CardTitle>Backups · {status.backups.length}</CardTitle>
          <p className="text-sm text-muted-foreground">
            Each holds the shop&apos;s database and the copies of paperwork and dog photos, in the backups folder on
            this computer. Keep a copy somewhere else too. Restoring one is done from the records tool.
          </p>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-3">
            <Button disabled={busy} onClick={backUp}>{busy ? "Backing up… this takes a minute" : "Back up now"}</Button>
            {done && <p className="text-sm text-ok">{done}</p>}
            {error && <p role="alert" className="text-sm text-stop">{error}</p>}
          </div>
          {status.backups.length === 0 ? (
            <p className="text-sm text-muted-foreground">No backups yet.</p>
          ) : (
            <ul className="divide-y divide-border rounded-[var(--radius)] border border-border bg-card text-sm">
              {status.backups.map((b) => (
                <li key={b.name} className="flex flex-wrap items-start justify-between gap-2 px-3 py-2.5">
                  <span className="min-w-0">
                    <span className="block font-medium">{when(b.made_utc)}</span>
                    <span className="block text-muted-foreground">
                      {b.why} · {megabytes(b.bytes)}
                      {b.readable ? ` · ${b.databases.length} databases, ${b.private_files ?? 0} files` : ""}
                    </span>
                    <span className="block font-mono text-xs text-muted-foreground">{b.name}</span>
                  </span>
                  {!b.readable && <Badge tone="stop">Can&apos;t be read</Badge>}
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
