"use client";

import { useEffect, useState } from "react";
import { Badge, toneFor } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { api, type ComplianceLine, type ComplianceSummary, type Review } from "@/lib/api";
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
  { title: "Waiting to be verified", note: "Groomable now; check them against the paperwork.",
    match: (l) => !l.blocks_service && l.state === "received_unverified" },
  { title: "Expiring soon", note: "Ask for updated paperwork at the next visit.",
    match: (l) => !l.blocks_service && l.state === "expiring_soon" },
];

export function AdminView({ groomerId, onOpenDog }: { groomerId: string; onOpenDog: (dogId: string) => void }) {
  const [summary, setSummary] = useState<ComplianceSummary | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [problem, setProblem] = useState<string | null>(null);

  const loadReviews = () => api.reviews().then(setReviews).catch((e) => setProblem(String(e.message ?? e)));
  useEffect(() => {
    api.compliance().then(setSummary).catch((e) => setProblem(String(e.message ?? e)));
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
                      &ldquo;{r.reason}&rdquo; · {r.changed_by}, {new Date(r.changed_at).toLocaleString("en-US", {
                        month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}
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
