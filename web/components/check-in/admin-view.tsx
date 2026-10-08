"use client";

import { useEffect, useState, type ReactNode } from "react";
import { Badge, toneFor } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { CopyPages, PaperworkIntake } from "@/components/check-in/paperwork-intake";
import { RecordFixForm } from "@/components/check-in/record-fix-form";
import {
  api, paperworkUrl, type AiAccuracy, type DogSummary, type ComplianceLine, type ComplianceSummary, type HandChecked, type Review,
  type WaitingCopy, type WaitingShot,
} from "@/lib/api";
import { cn, formatDate } from "@/lib/utils";
import { GoodStanding } from "@/components/ui/good-standing";

// The labelling and review tool (extraction/review/). Managers only.
const RECORDS_URL = process.env.NEXT_PUBLIC_RECORDS_URL ?? "http://localhost:8501";

const REQUEST = {
  queued: "Request queued", sent: "Requested from owner", responded: "Owner replied",
  insufficient: "Paperwork received wasn't enough",
} as Record<string, string>;

type Tone = "ok" | "stop" | "warn" | "info";

// Each group is a different job for the manager, in the order they matter.
// A vaccine line is in exactly one: anything that stops a groom is under
// "Can't groom" (rabies, as the shop is set up: vaccine_type.blocks_service_if_expired),
// and the rest by what is wrong with it. The count cards point at them by id.
const GROUPS: { id: string; title: string; note: string; match: (l: ComplianceLine) => boolean }[] = [
  { id: "cant-groom", title: "Can't groom", note: "These stop future grooms until paperwork is confirmed.",
    match: (l) => l.blocks_service },
  { id: "expired", title: "Expired",
    note: "Past their date. Under the shop's rules these don't stop a groom; ask for updated paperwork at the next visit.",
    match: (l) => !l.blocks_service && l.state === "expired" },
  { id: "missing", title: "No paperwork on file",
    note: "Never received, or asked for and not in yet. These don't stop a groom; ask the owner for them.",
    match: (l) => !l.blocks_service && (l.state === "no_record" || l.state === "requested_pending") },
  { id: "expiring", title: "Expiring soon", note: "Ask for updated paperwork at the next visit.",
    match: (l) => !l.blocks_service && l.state === "expiring_soon" },
  // Listed with its own buttons (WaitingCard), not as a plain group.
  { id: "waiting", title: "Waiting to be verified", note: "",
    match: (l) => !l.blocks_service && l.state === "received_unverified" },
  { id: "disputed", title: "Disputed", note: "Two records disagree. Compare them in the records tool.",
    match: (l) => !l.blocks_service && l.state === "disputed_record" },
];
// Nothing should land here; if something does, it is shown rather than lost.
const OTHER = { id: "other", title: "Anything else", note: "A state this screen doesn't have a list for yet." };

/** How many dogs a list of vaccine lines is about. */
const dogsIn = (lines: ComplianceLine[]) => new Set(lines.map((l) => l.dog_id)).size;
const dogs = (n: number) => `${n} ${n === 1 ? "dog" : "dogs"}`;

// The manager's own jobs, as against the state of the book. They share the
// shop's amber (the logo, the spaniel's eyes), card and screen alike, so a job
// and its list are plainly the same thing.
const TODO = new Set(["waiting", "paperwork", "hand-checked", "reviews"]);
const TODO_SURFACE = "border-todo-border bg-todo";

/**
 * The Admin view: an overview of counts, and behind each count its own screen
 * with just that list and its tools. `list` is which screen is open (null:
 * the overview); the page keeps it, so a manager who opens a dog from a list
 * comes back to the same list.
 */
export function AdminView({ groomerId, onOpenDog, list, onList }: {
  groomerId: string; onOpenDog: (dogId: string) => void;
  list: string | null; onList: (list: string | null) => void;
}) {
  const [summary, setSummary] = useState<ComplianceSummary | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [problem, setProblem] = useState<string | null>(null);

  const [waiting, setWaiting] = useState<WaitingCopy[]>([]);
  const [handChecked, setHandChecked] = useState<HandChecked[]>([]);
  const [checking, setChecking] = useState<WaitingCopy | null>(null);
  const [aiScore, setAiScore] = useState<AiAccuracy[]>([]);
  const [typedIn, setTypedIn] = useState<WaitingShot[]>([]);
  // Every dog on the books, as the check-in list has them: who can be groomed today.
  const [book, setBook] = useState<DogSummary[]>([]);
  // The one record whose form is open: verifying a typed-in shot, or fixing a hand-checked one.
  const [fixing, setFixing] = useState<string | null>(null);

  const fail = (e: { message?: string }) => setProblem(String(e.message ?? e));
  const loadReviews = () => api.reviews().then(setReviews).catch(fail);
  const loadPaperwork = () => {
    api.paperworkWaiting().then(setWaiting).catch(fail);
    api.handChecked().then(setHandChecked).catch(fail);
    api.waitingVerification().then(setTypedIn).catch(fail);
    api.aiAccuracy().then(setAiScore).catch(fail);
    api.compliance().then(setSummary).catch(fail);
    api.findDogs("").then(setBook).catch(fail);
  };
  useEffect(() => {
    loadPaperwork();
    loadReviews();
  }, []);
  useEffect(() => { window.scrollTo({ top: 0 }); }, [list]);

  if (problem) {
    return <p role="alert" className="rounded-[var(--radius)] border border-stop/30 bg-stop-soft p-3 text-sm text-stop">{problem}</p>;
  }
  if (!summary) return <p className="text-muted-foreground">Loading…</p>;

  const grouped = GROUPS.map((g) => ({ ...g, lines: summary.lines.filter(g.match) }));
  const other = summary.lines.filter((l) => !GROUPS.some((g) => g.match(l)));

  const byId = Object.fromEntries(grouped.map((g) => [g.id, g]));
  const typedInDogs = new Set(typedIn.map((r) => r.dog_id)).size;

  // Each screen behind a count: its list, and the tools that go with it.
  const screens: Record<string, { empty: string; node: ReactNode }> = {
    paperwork: { empty: "No copies waiting to be checked.", node: (checking || waiting.length > 0) && (
      <>
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
                             resume={{ documentId: checking.document_id }}
                             onChanged={loadPaperwork} onClose={() => { setChecking(null); loadPaperwork(); }} />
          </CardContent>
        </Card>
        )}
        {waiting.length > 0 && (
        <Card className={TODO_SURFACE}>
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
                    <CopyPages documentId={w.document_id} small />
                    <span>
                      <button className="font-medium hover:underline" onClick={() => onOpenDog(w.dog_id)}>{w.dog}</button>
                      <span className="text-muted-foreground"> · {w.owner}</span>
                      <span className="block text-sm text-muted-foreground">
                        Received by {w.received_by}, {when(w.received_at)}
                        {w.ai_read && <span className="ml-2 font-medium text-primary">· AI has read it</span>}
                      </span>
                    </span>
                  </span>
                  <span className="flex gap-2">
                    <Button size="sm" disabled={checking?.document_id === w.document_id} onClick={() => setChecking(w)}>
                      Check it
                    </Button>
                    <Button variant="outline" size="sm"
                            onClick={() => window.confirm(`Remove this copy of ${w.dog}'s paperwork? Its pages are deleted.`)
                              && api.removePaperwork(w.dog_id, w.document_id, groomerId).then(loadPaperwork).catch(fail)}>
                      Remove
                    </Button>
                  </span>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
        )}
      </>
    ) },
    "hand-checked": { empty: "Nothing checked by hand is waiting for a second look.", node: handChecked.length > 0 && (
        <Card className={TODO_SURFACE}>
          <CardHeader>
            <CardTitle>Checked by hand · {handChecked.length}</CardTitle>
            <p className="text-sm text-muted-foreground">
              Shots a groomer verified by reading a photo at the counter. Compare each with its photo: a date misread
              in a rush is the shop&apos;s problem at inspection. If one doesn&apos;t match, fix the dates here.
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
                  {fixing !== r.id && (
                    <span className="flex gap-2">
                      <Button variant="outline" size="sm"
                              onClick={() => api.secondLook(r.id, groomerId).then(loadPaperwork).catch(fail)}>
                        Matches the photo
                      </Button>
                      <Button variant="outline" size="sm" onClick={() => setFixing(r.id)}>
                        Doesn&apos;t match: fix it
                      </Button>
                    </span>
                  )}
                  {fixing === r.id && (
                    <RecordFixForm mode="fix" recordId={r.id} vaccine={r.vaccine} given={r.administered_on}
                                   expires={r.expires_on} groomerId={groomerId}
                                   onSaved={() => { setFixing(null); loadPaperwork(); }} onCancel={() => setFixing(null)} />
                  )}
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      ) },
    waiting: { empty: "No shots waiting to be verified.", node: typedIn.length > 0 && (
        <Card className={TODO_SURFACE}>
          <CardHeader>
            <CardTitle>Waiting to be verified · {dogs(typedInDogs)}</CardTitle>
            <p className="text-sm text-muted-foreground">
              Shots typed in at the counter with no copy of the paperwork. The dog can be groomed meanwhile. Check
              each one against the owner&apos;s paper or with the vet, then verify it.
            </p>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col divide-y divide-border">
              {typedIn.map((r) => (
                <li key={r.id} className="flex flex-wrap items-center justify-between gap-3 py-2.5">
                  <span className="min-w-0">
                    <button className="font-medium hover:underline" onClick={() => onOpenDog(r.dog_id)}>{r.dog}</button>
                    <span className="text-muted-foreground"> · {r.owner}</span>
                    <span className="block text-sm">
                      {r.vaccine} · given {formatDate(r.administered_on)} · expires {formatDate(r.expires_on)}
                    </span>
                    <span className="block text-sm text-muted-foreground">
                      Typed in{r.entered_by && ` by ${r.entered_by}`}, {when(r.entered_at)}
                    </span>
                  </span>
                  {fixing !== r.id && (
                    <Button variant="outline" size="sm" onClick={() => setFixing(r.id)}>Verify</Button>
                  )}
                  {fixing === r.id && (
                    <RecordFixForm mode="verify" recordId={r.id} vaccine={r.vaccine} given={r.administered_on}
                                   expires={r.expires_on} groomerId={groomerId}
                                   onSaved={() => { setFixing(null); loadPaperwork(); }} onCancel={() => setFixing(null)} />
                  )}
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      ) },
    reviews: { empty: "No allergy changes to review.", node: reviews.length > 0 && (
        <Card className={TODO_SURFACE}>
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
      ) },
    book: { empty: "No dogs on the books yet.", node: book.length > 0 && (
      <Card>
        <CardHeader>
          <CardTitle>Dogs on the books · {book.length}</CardTitle>
          <p className="text-sm text-muted-foreground">Every active dog, and whether it can be groomed today.</p>
        </CardHeader>
        <CardContent className="flex flex-col gap-5">
          <DogRows title="Can't groom today" dogs={book.filter((d) => d.blocks_service)} onOpenDog={onOpenDog} />
          <DogRows title="Cleared to groom" dogs={book.filter((d) => !d.blocks_service)} onOpenDog={onOpenDog} />
        </CardContent>
      </Card>
    ) },
    cleared: { empty: "No dogs are cleared to groom right now.", node: book.some((d) => !d.blocks_service) && (
      <Card>
        <CardHeader>
          <CardTitle>Cleared to groom · {dogs(book.filter((d) => !d.blocks_service).length)}</CardTitle>
          <p className="text-sm text-muted-foreground">
            Nothing stops these dogs being groomed today. Any note beside one is worth raising with the owner.
          </p>
        </CardHeader>
        <CardContent>
          <DogRows dogs={book.filter((d) => !d.blocks_service)} onOpenDog={onOpenDog} />
        </CardContent>
      </Card>
    ) },
    ...Object.fromEntries([...grouped.filter((g) => g.id !== "waiting"), { ...OTHER, lines: other }].map((g) => [g.id, {
      empty: "Nothing on this list now.",
      node: g.lines.length > 0 && (
        <Group id={g.id} title={`${g.title} · ${dogs(dogsIn(g.lines))}`} note={g.note} lines={g.lines} onOpenDog={onOpenDog} />
      ),
    }])),
  };

  const open = list ? screens[list] : undefined;
  if (list && open) {
    return (
      <div className="flex flex-col gap-4">
        <Button variant="outline" size="sm" className="self-start" onClick={() => onList(null)}>
          ← Back to the overview
        </Button>
        {open.node || (
          <Card className={TODO.has(list) ? TODO_SURFACE : ""}>
            <CardContent className="pt-5 text-muted-foreground">{open.empty}</CardContent>
          </Card>
        )}
      </div>
    );
  }

  const stat = (label: string, value: number, tone: Tone | undefined, target: string) =>
    <Stat label={label} value={value} tone={tone} todo={TODO.has(target)} onOpen={() => onList(target)} />;

  return (
    <div className="flex flex-col gap-6">
      {/* The book at a glance, then the manager's own jobs. A card with a list behind it opens that list. */}
      <section className="flex flex-col gap-2">
        <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Vaccinations</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          {stat("Dogs on the books", summary.dogs, undefined, "book")}
          {stat("Cleared to groom", summary.cleared, "ok", "cleared")}
          {stat("Can't groom", dogsIn(byId["cant-groom"].lines), "stop", "cant-groom")}
          {stat("Expired", dogsIn(byId["expired"].lines), "stop", "expired")}
          {stat("No paperwork on file", dogsIn(byId["missing"].lines), "warn", "missing")}
          {stat("Expiring soon", dogsIn(byId["expiring"].lines), "warn", "expiring")}
        </div>
      </section>
      <section className="flex flex-col gap-2">
        <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Your to-do list</h2>
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          {stat("Waiting to be verified", typedInDogs, "info", "waiting")}
          {stat("Paperwork to check", waiting.length, "info", "paperwork")}
          {stat("Checked by hand, to look over", handChecked.length, "info", "hand-checked")}
          {stat("Allergy changes to review", reviews.length, "info", "reviews")}
        </div>
      </section>
      {other.length > 0 && (
        <Group id={OTHER.id} title={`${OTHER.title} · ${dogs(dogsIn(other))}`} note={OTHER.note} lines={other}
               onOpenDog={onOpenDog} />
      )}

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardContent className="flex h-full flex-col justify-between gap-4 pt-5">
            <div>
              <p className="font-semibold">Vaccination records</p>
              <p className="text-sm text-muted-foreground">
                The test bench: label sample paperwork, compare AI prompts and models, and manage owner reminders.
              </p>
            </div>
            <a
              href={RECORDS_URL}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-10 items-center self-start rounded-[var(--radius)] border border-border bg-card px-4 text-sm font-medium hover:bg-muted"
            >
              Open records tool ↗
            </a>
          </CardContent>
        </Card>
        <AiScoreboard rows={aiScore} />
      </div>

      {summary.lines.length === 0 && (
        <p className="text-muted-foreground">Every dog&apos;s vaccinations are in order.</p>
      )}
    </div>
  );
}

/** How the AI has done on real paperwork, graded by whoever checked each copy. */
function AiScoreboard({ rows }: { rows: AiAccuracy[] }) {
  const kinds = { pdf: "Emailed PDFs", photo: "Photos" } as const;
  return (
    <Card>
      <CardContent className="flex h-full flex-col gap-3 pt-5">
        <div>
          <p className="font-semibold">How the AI is doing</p>
          <p className="text-sm text-muted-foreground">
            Graded by whoever checked each copy it read: on the shop&apos;s own paperwork.
          </p>
        </div>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Nothing graded yet. Use &ldquo;Have the AI read it&rdquo; when checking a copy, and the score starts here.
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-border">
            {rows.map((r) => {
              const graded = r.right_first_time + r.read_wrong + r.missed + r.made_up;
              const pct = graded ? Math.round((100 * r.right_first_time) / graded) : 0;
              return (
                <li key={r.copy_kind} className="flex items-baseline justify-between gap-3 py-2">
                  <span className="min-w-0">
                    <span className="font-medium">{kinds[r.copy_kind]}</span>
                    <span className="text-muted-foreground"> · {r.readings} read</span>
                    <span className="block text-xs text-muted-foreground">
                      {r.right_first_time} right · {r.read_wrong} read wrong · {r.missed} missed · {r.made_up} made up
                    </span>
                  </span>
                  {graded ? (
                    <span className={`shrink-0 text-xl font-semibold ${pct >= 95 ? "text-ok" : pct >= 80 ? "text-warn" : "text-stop"}`}>
                      {pct}%
                    </span>
                  ) : (
                    <span className="shrink-0 text-sm text-muted-foreground">not graded yet</span>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}

const when = (at: string) =>
  new Date(at).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

const TONE: Record<Tone, string> = { ok: "text-ok", stop: "text-stop", warn: "text-warn", info: "text-primary" };

function Stat({ label, value, tone, todo, onOpen }: {
  label: string; value: number; tone?: Tone; todo?: boolean; onOpen?: () => void;
}) {
  const colour = tone && value > 0 ? TONE[tone] : "";
  const body = (
    <>
      <p className={`text-3xl font-semibold ${colour}`}>{value}</p>
      <p className="text-sm text-muted-foreground">{label}</p>
    </>
  );
  // Nothing behind it, or nothing in the list: a plain count.
  if (!onOpen || value === 0) {
    return <Card className={todo ? TODO_SURFACE : ""}><CardContent className="pt-5">{body}</CardContent></Card>;
  }
  return (
    <button onClick={onOpen}
            className={cn("group flex flex-col items-start justify-start rounded-[var(--radius)] border p-5 text-left shadow-sm transition-colors hover:border-primary",
                          todo ? `${TODO_SURFACE} hover:bg-todo-hover` : "border-border bg-card hover:bg-muted")}>
      {body}
      <p className="mt-1 text-xs font-medium text-primary group-hover:underline">Open the list →</p>
    </button>
  );
}

/** Dogs as the check-in list shows them: the one thing to know first, and whether they can be groomed. */
function DogRows({ title, dogs: rows, onOpenDog }: {
  title?: string; dogs: DogSummary[]; onOpenDog: (dogId: string) => void;
}) {
  if (rows.length === 0) return null;
  return (
    <div>
      {title && (
        <h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {title} · {dogs(rows.length)}
        </h3>
      )}
      <ul className="flex flex-col divide-y divide-border">
        {rows.map((d) => (
          <li key={d.id}>
            <button onClick={() => onOpenDog(d.id)}
                    className="flex w-full flex-wrap items-center justify-between gap-x-3 gap-y-1 py-2.5 text-left hover:bg-muted/50">
              <span className="min-w-0">
                <span className="font-medium">{d.name}</span> <GoodStanding show={d.in_good_standing} />
                <span className="text-muted-foreground"> · {d.owner}</span>
                {(d.breed || d.attention) && (
                  <span className="block text-sm text-muted-foreground">
                    {[d.breed, d.attention].filter(Boolean).join(" · ")}
                  </span>
                )}
              </span>
              <Badge tone={d.blocks_service ? "stop" : "ok"}>{d.blocks_service ? "Can't groom" : "Cleared"}</Badge>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Group({ id, title, note, lines, onOpenDog }: {
  id: string; title: string; note: string; lines: ComplianceLine[]; onOpenDog: (dogId: string) => void;
}) {
  return (
    <Card id={id}>
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
