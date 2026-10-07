"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Camera, wantsLiveCamera } from "@/components/check-in/camera";
import { PaperworkForm } from "@/components/check-in/paperwork-form";
import { api, paperworkUrl, type ReceivedCopy } from "@/lib/api";

type Step =
  | { at: "pick" }
  | { at: "camera" }
  | { at: "choose"; copy: ReceivedCopy }
  | { at: "check"; documentId: string; mimeType: string }
  | { at: "later" }
  | { at: "typed" };

const mb = (bytes: number) => bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)} MB` : `${Math.round(bytes / 1024)} KB`;

/**
 * The owner's paperwork, from the counter: a photo (or the PDF they emailed)
 * is kept with the dog first, then the groomer chooses to check it now or
 * leave it for a manager. Opened on a copy already waiting (`resume`), it goes
 * straight to checking.
 */
export function PaperworkIntake({
  dogId, dogName, groomerId, resume, onChanged, onClose, cancelLabel = "Cancel", closeLabel,
}: {
  dogId: string;
  dogName: string;
  groomerId: string;
  resume?: { documentId: string; mimeType: string };
  onChanged: () => void;
  onClose: () => void;
  /** The way out before any copy is taken. */
  cancelLabel?: string;
  /** The way out once the dates are in. */
  closeLabel?: string;
}) {
  const [step, setStep] = useState<Step>(resume ? { at: "check", ...resume } : { at: "pick" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const camera = useRef<HTMLInputElement>(null);
  const picker = useRef<HTMLInputElement>(null);

  async function send(file: File | undefined) {
    if (!file) return;
    setStep({ at: "pick" });
    setBusy(true); setError(null);
    try {
      const copy = await api.sendPaperwork(dogId, groomerId, file);
      setStep({ at: "choose", copy });
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
      if (camera.current) camera.current.value = "";
      if (picker.current) picker.current.value = "";
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

  const problem = error && <p role="alert" className="text-sm text-stop">{error}</p>;

  // Two inputs: on a tablet, capture opens the camera app; the other offers files.
  const inputs = (
    <>
      <input ref={camera} type="file" accept="image/*" capture="environment" className="hidden"
             onChange={(e) => send(e.target.files?.[0])} />
      <input ref={picker} type="file" accept="image/*,application/pdf,.heic" className="hidden"
             onChange={(e) => send(e.target.files?.[0])} />
    </>
  );

  if (step.at === "camera") {
    return (
      <>
        {inputs}
        <Camera onPhoto={send} onCancel={() => setStep({ at: "pick" })} onChooseFile={() => picker.current?.click()} />
      </>
    );
  }

  if (step.at === "pick") {
    return (
      <div className="flex flex-col gap-4">
        <p className="text-sm text-muted-foreground">
          Take a photo of {dogName}&apos;s paperwork, or of the owner&apos;s phone screen. If they emailed it, choose
          the file instead. The copy is kept with {dogName}&apos;s records.
        </p>
        {inputs}
        <div className="flex flex-wrap gap-3">
          <Button size="lg" disabled={busy}
                  onClick={() => wantsLiveCamera() ? setStep({ at: "camera" }) : camera.current?.click()}>
            {busy ? "Saving…" : "Take a photo"}
          </Button>
          <Button variant="outline" size="lg" disabled={busy} onClick={() => picker.current?.click()}>
            Choose a file
          </Button>
          <Button variant="outline" size="lg" disabled={busy} onClick={() => setStep({ at: "typed" })}>
            Type the dates in
          </Button>
          <Button variant="ghost" size="lg" disabled={busy} onClick={onClose}>{cancelLabel}</Button>
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
        <div className="flex flex-wrap items-center gap-4">
          <CopyPreview documentId={copy.document_id} mimeType={copy.mime_type} small />
          <p className="text-sm text-muted-foreground">
            <span className="block font-medium text-ok">Copy saved.</span>
            {/* Only when it was actually made smaller, not just re-saved. */}
            {copy.saved_size && copy.original_size && copy.saved_size[0] < copy.original_size[0]
              ? `Shrunk from ${mb(copy.original_bytes)} to ${mb(copy.saved_bytes)} to save space.`
              : `${mb(copy.saved_bytes)}.`}
          </p>
        </div>
        <p className="font-medium">Who checks it?</p>
        <div className="grid gap-3 sm:grid-cols-2">
          <button
            className="flex flex-col gap-1 rounded-[var(--radius)] border-2 border-primary/40 bg-card p-4 text-left hover:border-primary hover:bg-muted"
            onClick={() => setStep({ at: "check", documentId: copy.document_id, mimeType: copy.mime_type })}>
            <span className="text-lg font-semibold">I&apos;ll check it now</span>
            <span className="text-sm text-muted-foreground">
              Read the photo and type in the dates. They count as verified straight away, under your name.
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

  // Checking: the photo beside the form.
  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 lg:grid-cols-2">
        <CopyPreview documentId={step.documentId} mimeType={step.mimeType} />
        <PaperworkForm dogId={dogId} dogName={dogName} groomerId={groomerId} documentId={step.documentId}
                       onSaved={onChanged} onClose={() => done(step.documentId)} closeLabel={closeLabel ?? "Done checking"} />
      </div>
      {problem}
      <button className="self-start text-sm text-muted-foreground underline-offset-2 hover:underline"
              disabled={busy} onClick={onClose}>
        Not finished? Leave it on the list to check later
      </button>
    </div>
  );
}

/** The copy as it was saved. Tap to open it full size. */
export function CopyPreview({ documentId, mimeType, small = false }: {
  documentId: string; mimeType: string; small?: boolean;
}) {
  const url = paperworkUrl(documentId);
  if (mimeType === "application/pdf") {
    return small ? (
      <a href={url} target="_blank" rel="noreferrer"
         className="flex h-24 w-20 items-center justify-center rounded-[var(--radius)] border border-border bg-muted text-sm font-medium">
        PDF ↗
      </a>
    ) : (
      <div className="flex flex-col gap-1">
        <object data={url} type="application/pdf" className="h-[70vh] w-full rounded-[var(--radius)] border border-border">
          <a href={url} target="_blank" rel="noreferrer" className="underline">Open the PDF</a>
        </object>
        <a href={url} target="_blank" rel="noreferrer" className="text-sm text-muted-foreground hover:underline">Open full size ↗</a>
      </div>
    );
  }
  return (
    <a href={url} target="_blank" rel="noreferrer" className="flex flex-col gap-1">
      <img src={url} alt="The owner's paperwork"
           className={small ? "h-24 w-auto rounded-[var(--radius)] border border-border"
                            : "max-h-[70vh] w-full rounded-[var(--radius)] border border-border bg-muted object-contain"} />
      {!small && <span className="text-sm text-muted-foreground">Tap to open full size ↗</span>}
    </a>
  );
}
