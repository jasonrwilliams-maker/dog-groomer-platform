"use client";

import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Camera, wantsLiveCamera } from "@/components/check-in/camera";
import { PaperworkForm } from "@/components/check-in/paperwork-form";
import { api, pageUrl, paperworkUrl, Refusal, type ReceivedCopy } from "@/lib/api";

type Step =
  | { at: "pick" }
  | { at: "camera" }
  | { at: "choose"; copy: ReceivedCopy }
  | { at: "check"; documentId: string }
  | { at: "later" }
  | { at: "typed" };

/** A page picked or photographed, not yet saved. */
type Pending = { id: number; file: File; preview: string | null };

const mb = (bytes: number) => bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)} MB` : `${Math.round(bytes / 1024)} KB`;
const isPdf = (f: File) => f.type === "application/pdf" || f.name.toLowerCase().endsWith(".pdf");
let nextId = 1;

/**
 * The owner's paperwork, from the counter. Every page goes in first (photos,
 * files, or both; a blurry one removed or taken again) and is saved as one
 * copy kept with the dog. Then the groomer chooses to check it now or leave it
 * for a manager. Opened on a copy already waiting (`resume`), it goes
 * straight to checking.
 */
export function PaperworkIntake({
  dogId, dogName, groomerId, resume, onChanged, onClose, cancelLabel = "Cancel", closeLabel,
}: {
  dogId: string;
  dogName: string;
  groomerId: string;
  resume?: { documentId: string };
  onChanged: () => void;
  onClose: () => void;
  /** The way out before any copy is taken. */
  cancelLabel?: string;
  /** The way out once the dates are in. */
  closeLabel?: string;
}) {
  const [step, setStep] = useState<Step>(resume ? { at: "check", ...resume } : { at: "pick" });
  const [pending, setPending] = useState<Pending[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const camera = useRef<HTMLInputElement>(null);
  const picker = useRef<HTMLInputElement>(null);

  // Previews live only while the page is in the tray.
  const previews = useRef(new Set<string>());
  useEffect(() => {
    const urls = previews.current;
    return () => urls.forEach((u) => URL.revokeObjectURL(u));
  }, []);

  function add(files: FileList | File[] | null | undefined) {
    const list = Array.from(files ?? []);
    if (!list.length) return;
    setError(null);
    setPending((ps) => [...ps, ...list.map((file) => {
      const preview = isPdf(file) ? null : URL.createObjectURL(file);
      if (preview) previews.current.add(preview);
      return { id: nextId++, file, preview };
    })]);
    setStep({ at: "pick" });
    if (camera.current) camera.current.value = "";
    if (picker.current) picker.current.value = "";
  }

  function drop(id: number) {
    setPending((ps) => ps.filter((p) => {
      if (p.id === id && p.preview) { URL.revokeObjectURL(p.preview); previews.current.delete(p.preview); }
      return p.id !== id;
    }));
  }

  async function save() {
    setBusy(true); setError(null);
    try {
      const copy = await api.sendPaperwork(dogId, groomerId, pending.map((p) => p.file));
      pending.forEach((p) => drop(p.id));
      setStep({ at: "choose", copy });
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function done(documentId: string) {
    setBusy(true); setError(null);
    try {
      await api.paperworkDone(dogId, documentId, groomerId);
      onChanged();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusy(false);
    }
  }

  async function remove(documentId: string) {
    if (!window.confirm("Remove this copy? Its pages are deleted, and you can take them again.")) return;
    setBusy(true); setError(null);
    try {
      await api.removePaperwork(dogId, documentId, groomerId);
      onChanged();
      setStep({ at: "pick" });
    } catch (e) {
      setError(e instanceof Refusal ? `${e.message}. ${e.hint ?? ""}` : e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const problem = error && <p role="alert" className="text-sm text-stop">{error}</p>;
  const takePhoto = () => wantsLiveCamera() ? setStep({ at: "camera" }) : camera.current?.click();

  // Two inputs: on a tablet, capture opens the camera app; the other offers files, several at once.
  const inputs = (
    <>
      <input ref={camera} type="file" accept="image/*" capture="environment" className="hidden"
             onChange={(e) => add(e.target.files)} />
      <input ref={picker} type="file" accept="image/*,application/pdf,.heic" multiple className="hidden"
             onChange={(e) => add(e.target.files)} />
    </>
  );

  if (step.at === "camera") {
    return (
      <>
        {inputs}
        <Camera onPhoto={(f) => add([f])} onCancel={() => setStep({ at: "pick" })}
                onChooseFile={() => picker.current?.click()} />
      </>
    );
  }

  if (step.at === "pick" && pending.length > 0) {
    const n = pending.length;
    return (
      <div className="flex flex-col gap-4">
        {inputs}
        <p className="text-sm text-muted-foreground">
          Add every page the owner has, then save. Remove any that came out blurry and take it again.
        </p>
        <ul className="flex flex-wrap gap-3">
          {pending.map((p, i) => (
            <li key={p.id} className="relative flex w-28 flex-col gap-1">
              {p.preview ? (
                <img src={p.preview} alt={`Photo ${i + 1}`}
                     className="h-36 w-28 rounded-[var(--radius)] border border-border bg-muted object-cover" />
              ) : (
                <span className="flex h-36 w-28 items-center justify-center break-all rounded-[var(--radius)] border border-border bg-muted p-2 text-center text-xs font-medium">
                  PDF · {p.file.name}
                </span>
              )}
              <span className="text-xs text-muted-foreground">{p.preview ? "Photo" : "File"} {i + 1}</span>
              <button aria-label={`Remove ${p.preview ? "photo" : "file"} ${i + 1}`} disabled={busy} onClick={() => drop(p.id)}
                      className="absolute right-1 top-1 flex h-7 w-7 items-center justify-center rounded-full bg-card/90 text-sm font-semibold shadow hover:bg-stop-soft hover:text-stop">
                ✕
              </button>
            </li>
          ))}
        </ul>
        <div className="flex flex-wrap gap-3">
          <Button size="lg" disabled={busy} onClick={save}>
            {busy ? "Saving…" : n === 1 ? "Save it" : `Save all ${n}`}
          </Button>
          <Button variant="outline" size="lg" disabled={busy} onClick={takePhoto}>Take another photo</Button>
          <Button variant="outline" size="lg" disabled={busy} onClick={() => picker.current?.click()}>Add a file</Button>
          <Button variant="ghost" size="lg" disabled={busy} onClick={() => pending.forEach((p) => drop(p.id))}>
            Start over
          </Button>
        </div>
        {problem}
      </div>
    );
  }

  if (step.at === "pick") {
    return (
      <div className="flex flex-col gap-4">
        <p className="text-sm text-muted-foreground">
          Take a photo of each page of {dogName}&apos;s paperwork, or of the owner&apos;s phone screen. If they
          emailed it, choose the files instead. You can mix both. The copy is kept with {dogName}&apos;s records.
        </p>
        {inputs}
        <div className="flex flex-wrap gap-3">
          <Button size="lg" onClick={takePhoto}>Take a photo</Button>
          <Button variant="outline" size="lg" onClick={() => picker.current?.click()}>Choose files</Button>
          <Button variant="outline" size="lg" onClick={() => setStep({ at: "typed" })}>Type the dates in</Button>
          <Button variant="ghost" size="lg" onClick={onClose}>{cancelLabel}</Button>
        </div>
        <p className="-mt-2 text-sm text-muted-foreground">
          No copy to keep? <span className="font-medium text-foreground">Type the dates in</span> without one;
          a manager verifies them later.
        </p>
        {problem}
      </div>
    );
  }

  if (step.at === "typed") {
    return <PaperworkForm dogId={dogId} dogName={dogName} groomerId={groomerId} onSaved={onChanged} onClose={onClose}
                          closeLabel={closeLabel} />;
  }

  if (step.at === "later") {
    return (
      <div className="flex flex-col gap-3">
        <p className="font-medium text-ok">Saved for later.</p>
        <p className="text-sm text-muted-foreground">
          It&apos;s on the manager&apos;s list under &ldquo;Paperwork to check&rdquo;. Until someone checks it,
          {" "}{dogName}&apos;s vaccinations stay as they are on the card.
        </p>
        <Button variant="outline" size="lg" className="self-start" onClick={onClose}>Close</Button>
      </div>
    );
  }

  if (step.at === "choose") {
    const { copy } = step;
    return (
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-2">
          <CopyPages documentId={copy.document_id} small />
          <p className="text-sm text-muted-foreground">
            <span className="font-medium text-ok">Copy saved</span>
            {` · ${copy.page_count} ${copy.page_count === 1 ? "page" : "pages"}`}
            {copy.resized && ` · shrunk from ${mb(copy.original_bytes)} to ${mb(copy.saved_bytes)} to save space`}
            {" · "}
            <button className="underline-offset-2 hover:underline" disabled={busy} onClick={() => remove(copy.document_id)}>
              Blurry or wrong? Remove it
            </button>
          </p>
        </div>
        {problem}
        <p className="font-medium">Who checks it?</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <button
            className="flex flex-col gap-1 rounded-[var(--radius)] border-2 border-primary/40 bg-card p-4 text-left hover:border-primary hover:bg-muted"
            onClick={() => setStep({ at: "check", documentId: copy.document_id })}>
            <span className="text-lg font-semibold">I&apos;ll check it now</span>
            <span className="text-sm text-muted-foreground">
              Read the pages and type in the dates. They count as verified straight away, under your name.
            </span>
          </button>
          <button
            className="flex flex-col gap-1 rounded-[var(--radius)] border-2 border-border bg-card p-4 text-left hover:border-primary hover:bg-muted"
            onClick={() => setStep({ at: "later" })}>
            <span className="text-lg font-semibold">Check it later</span>
            <span className="text-sm text-muted-foreground">
              Too busy, or it needs a careful look. It goes on the manager&apos;s list in the Admin view.
            </span>
          </button>
        </div>
      </div>
    );
  }

  // Checking: the pages beside the form.
  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 lg:grid-cols-2">
        <CopyPages documentId={step.documentId} />
        <PaperworkForm dogId={dogId} dogName={dogName} groomerId={groomerId} documentId={step.documentId}
                       onSaved={onChanged} onClose={() => done(step.documentId)} closeLabel={closeLabel ?? "Done checking"} />
      </div>
      {problem}
      <div className="flex flex-wrap gap-x-6 gap-y-2 text-sm text-muted-foreground">
        <button className="underline-offset-2 hover:underline" disabled={busy} onClick={onClose}>
          Not finished? Leave it on the list to check later
        </button>
        <button className="underline-offset-2 hover:underline" disabled={busy} onClick={() => remove(step.documentId)}>
          Blurry or wrong? Remove this copy and take it again
        </button>
      </div>
    </div>
  );
}

/** A saved copy's pages, in order. Tap a page to open it full size. */
export function CopyPages({ documentId, small = false }: { documentId: string; small?: boolean }) {
  const [info, setInfo] = useState<{ mime_type: string; page_count: number } | null>(null);
  useEffect(() => {
    api.paperworkInfo(documentId).then(setInfo).catch(() => setInfo({ mime_type: "", page_count: 0 }));
  }, [documentId]);
  if (!info) return <p className="text-sm text-muted-foreground">Loading the pages…</p>;

  // A PDF filed before copies had pages: show the file itself.
  if (info.page_count === 0) {
    return (
      <a href={paperworkUrl(documentId)} target="_blank" rel="noreferrer"
         className="flex h-24 w-20 items-center justify-center rounded-[var(--radius)] border border-border bg-muted text-sm font-medium">
        PDF ↗
      </a>
    );
  }
  const pages = Array.from({ length: info.page_count }, (_, i) => i + 1);

  if (small) {
    return (
      <div className="flex flex-wrap gap-2">
        {pages.map((n) => (
          <a key={n} href={pageUrl(documentId, n)} target="_blank" rel="noreferrer">
            <img src={pageUrl(documentId, n)} alt={`Page ${n}`}
                 className="h-24 w-auto rounded-[var(--radius)] border border-border bg-muted" />
          </a>
        ))}
      </div>
    );
  }
  return (
    <div className="flex max-h-[75vh] flex-col gap-4 overflow-y-auto rounded-[var(--radius)] border border-border bg-muted p-2">
      {pages.map((n) => (
        <a key={n} href={pageUrl(documentId, n)} target="_blank" rel="noreferrer" className="flex flex-col gap-1">
          {pages.length > 1 && <span className="text-xs font-medium text-muted-foreground">Page {n} of {pages.length}</span>}
          <img src={pageUrl(documentId, n)} alt={`Page ${n} of the owner's paperwork`}
               className="w-full rounded-[var(--radius)] border border-border bg-card object-contain" />
        </a>
      ))}
      <span className="px-1 text-xs text-muted-foreground">Tap a page to open it full size ↗</span>
    </div>
  );
}
