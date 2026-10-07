"use client";

import { useEffect, useState } from "react";
import { Badge, toneFor } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { CopyPreview, PaperworkIntake } from "@/components/check-in/paperwork-intake";
import {
  api, paperworkUrl, type ComplianceLine, type ComplianceSummary, type HandChecked, type Review, type WaitingCopy,
} from "@/lib/api";
import { formatDate } from "@/lib/utils";

// The labelling and review tool (extraction/review/). Managers only.
const RECORDS_URL = process.env.NEXT_PUBLIC_RECORDS_URL ?? "http://localhost:8501";

const REQUEST = {
  queued: "Request queued", sent: "Requested from owner", responded: "Owner replied",
  insufficient: "Paperwork received wasn't enough",
} as Record<string, string>;

// Each group is a different job for the manager, in the order they matter.
const GROUPS: { title: string; note: string; match: (l: ComplianceLine) => boolean }[] = [
  { title: "Can't groom", note: "These stop today's groom until paperwork is confirmed.", match: (l) => l.blocks_service },
  { title: "Waiting to be verified", note: "Typed in with no copy of the paperwork. Groomable now; check them against the paper.",
    match: (l) => !l.blocks_service && l.state === "received_unverified" },
  { title: "Expiring soon", note: "Ask for updated paperwork at the next visit.",
    match: (l) => !l.blocks_service && l.state === "expiring_soon" },
];

export function AdminView({ groomerId, onOpenDog }: { groomerId: string; onOpenDog: (dogId: string) => void }) {
  const [summary, setSummary] = useState<ComplianceSummary | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [problem, setProblem] = useState<string | null>(null);

  const [waiting, setWaiting] = useState<WaitingCopy[]>([]);
  const [handChecked, setHandChecked] = useState<HandChecked[]>([]);
  const [checking, setChecking] = useState<WaitingCopy | null>(null);

  const fail = (e: { message?: string }) => setProblem(String(e.message ?? e));
  const loadReviews = () => api.reviews().then(setReviews).catch(fail);
  const loadPaperwork = () => {
    api.paperworkWaiting().then(setWaiting).catch(fail);
    api.handChecked().then(setHandChecked).catch(fail);
    api.compliance().then(setSummary).catch(fail);
  };
  useEffect(() => {
    loadPaperwork();
    loadReviews();
  }, []);

  if (problem) {
    return <p role="alert" className="rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">{problem}</p>;
  }
  if (!summary) return <p className="text-muted-foreground">Loading…</p>;

  const grouped = GROUPS.map((g) => ({ ...g, lines: summary.lines.filter(g.match) }));
  const other = summary.lines.filter((l) => !GROUPS.some((g) => g.match(l)));

  return (
    <div className="flex flex-col gap-6">
      <div className="grid gap-3 sm:grid-cols-3">
        <Stat label="Dogs on the books" value={summary.dogs} />
        <Stat label="Cleared to groom" value={summary.cleared} tone="ok" />
        <Stat label="Can't groom" value={summary.blocked} tone={summary.blocked ? "stop" : undefined} />
      </div>

      <Card>
        <CardContent className="flex flex-wrap items-center justify-between gap-4 pt-5">
          <div>
            <p className="font-semibold">Vaccination records</p>
            <p className="text-sm text-muted-foreground">
              Label, review and confirm paperwork, and manage owner reminders.
            </p>
          </div>
          <a
            href={RECORDS_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex h-10 items-center rounded-[var(--radius)] bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary-hover"
          >
            Open records tool ↗
          </a>
        </CardContent>
      </Card>

      {checking && (
        <Card className="border-primary/40">
          <CardHeader>
            <CardTitle>{checking.dog}&apos;s paperwork</CardTitle>
            <p className="text-sm text-muted-foreground">
              {checking.owner} · received by {checking.received_by}, {when(checking.received_at)}
            </p>
          </CardHeader>
          <CardContent>
            <PaperworkIntake key={checking.document_id} dogId={checking.dog_id} dogName={checking.dog}
                             groomerId={groomerId}
                             resume={{ documentId: checking.document_id, mimeType: checking.mime_type }}
                             onChanged={loadPaperwork} onClose={() => { setChecking(null); loadPaperwork(); }} />
          </CardContent>
        </Card>
      )}

      {waiting.length > 0 && (
        <Card className="border-warn/40">
          <CardHeader>
            <CardTitle>Paperwork to check · {waiting.length}</CardTitle>
            <p className="text-sm text-muted-foreground">
              Copies taken at the counter that nobody has finished checking. Read each one and type in its dates.
            </p>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col divide-y divide-border">
              {waiting.map((w) => (
                <li key={`${w.document_id}-${w.dog_id}`} className="flex flex-wrap items-center justify-between gap-3 py-2.5">
                  <span className="flex min-w-0 items-center gap-3">
                    <CopyPreview documentId={w.document_id} mimeType={w.mime_type} small />
                    <span>
                      <button className="font-medium hover:underline" onClick={() => onOpenDog(w.dog_id)}>{w.dog}</button>
                      <span className="text-muted-foreground"> · {w.owner}</span>
                      <span className="block text-sm text-muted-foreground">Received by {w.received_by}, {when(w.received_at)}</span>
                    </span>
                  </span>
                  <Button size="sm" disabled={checking?.document_id === w.document_id} onClick={() => setChecking(w)}>
                    Check it
                  </Button>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      {handChecked.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Checked by hand · {handChecked.length}</CardTitle>
            <p className="text-sm text-muted-foreground">
              Shots a groomer verified by reading a photo at the counter. Compare each with its photo: a date misread
              in a rush is the shop&apos;s problem at inspection. If one doesn&apos;t match, leave it here and sort it out
              with the groomer.
            </p>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col divide-y divide-border">
              {handChecked.map((r) => (
                <li key={r.id} className="flex flex-wrap items-center justify-between gap-3 py-2.5">
                  <span className="min-w-0">
                    <button className="font-medium hover:underline" onClick={() => onOpenDog(r.dog_id)}>{r.dog}</button>
                    <span className="text-muted-foreground"> · {r.owner}</span>
                    <span className="block text-sm">
                      {r.vaccine} · given {formatDate(r.administered_on)} · expires {formatDate(r.expires_on)}
                    </span>
                    <span className="block text-sm text-muted-foreground">
                      Checked by {r.checked_by}, {when(r.checked_at)} ·{" "}
                      <a href={paperworkUrl(r.document_id)} target="_blank" rel="noreferrer" className="underline-offset-2 hover:underline">
                        see the photo ↗
                      </a>
                    </span>
                  </span>
                  <Button variant="outline" size="sm"
                          onClick={() => api.secondLook(r.id, groomerId).then(loadPaperwork).catch(fail)}>
                    Matches the photo
                  </Button>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      {reviews.length > 0 && (
        <Card className="border-warn/40">
          <CardHeader>
            <CardTitle>Changes to review · {reviews.length}</CardTitle>
            <p className="text-sm text-muted-foreground">
              Allergies taken off or made less severe while no manager was in. Check each with the groomer or the owner.
            </p>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col divide-y divide-border">
              {reviews.map((r) => (
                <li key={r.id} className="flex flex-wrap items-center justify-between gap-3 py-2.5">
                  <button className="min-w-0 text-left hover:underline" onClick={() => onOpenDog(r.dog_id)}>
                    <span className="font-medium">{r.dog}</span>
                    <span className="text-muted-foreground"> · {r.owner}</span>
                    <span className="block text-sm">{r.summary}</span>
                    <span className="block text-sm text-muted-foreground">
                      &ldquo;{r.reason}&rdquo; · {r.changed_by}, {when(r.changed_at)}
                    </span>
                  </button>
                  <Button variant="outline" size="sm"
                          onClick={() => api.markReviewed(r.id, groomerId).then(loadReviews)
                                             .catch((e) => setProblem(String(e.message ?? e)))}>
                    Mark reviewed
                  </Button>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}

      {grouped.map((g) => g.lines.length > 0 && (
        <Group key={g.title} title={`${g.title} · ${g.lines.length}`} note={g.note} lines={g.lines} onOpenDog={onOpenDog} />
      ))}
      {other.length > 0 && (
        <Group title={`Other · ${other.length}`} note="Not blocking, but not complete either." lines={other} onOpenDog={onOpenDog} />
      )}
      {summary.lines.length === 0 && (
        <p className="text-muted-foreground">Every dog&apos;s vaccinations are in order.</p>
      )}
    </div>
  );
}

const when = (at: string) =>
  new Date(at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

function Stat({ label, value, tone }: { label: string; value: number; tone?: "ok" | "stop" }) {
  const colour = tone === "ok" ? "text-ok" : tone === "stop" ? "text-stop" : "";
  return (
    <Card>
      <CardContent className="pt-5">
        <p className={`text-3xl font-semibold ${colour}`}>{value}</p>
        <p className="text-sm text-muted-foreground">{label}</p>
      </CardContent>
    </Card>
  );
}

function Group({ title, note, lines, onOpenDog }: {
  title: string; note: string; lines: ComplianceLine[]; onOpenDog: (dogId: string) => void;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <p className="text-sm text-muted-foreground">{note}</p>
      </CardHeader>
      <CardContent>
        <ul className="flex flex-col divide-y divide-border">
          {lines.map((l) => (
            <li key={`${l.dog_id}-${l.vaccine}`}>
              <button
                onClick={() => onOpenDog(l.dog_id)}
                className="flex w-full flex-wrap items-center justify-between gap-x-3 gap-y-1 py-2.5 text-left hover:bg-muted/50"
              >
                <span className="min-w-0">
                  <span className="font-medium">{l.dog}</span>
                  <span className="text-muted-foreground"> · {l.owner}</span>
                  <span className="block text-sm text-muted-foreground">
                    {l.vaccine}
                    {l.expires_on && ` · ${l.days_until_expiry !== null && l.days_until_expiry < 0 ? "expired" : "expires"} ${formatDate(l.expires_on)}`}
                    {l.request_status && ` · ${REQUEST[l.request_status] ?? l.request_status}`}
                  </span>
                </span>
                <Badge tone={toneFor(l.state, l.blocks_service)}>{l.label}</Badge>
              </button>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}
