"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { DogPhoto } from "@/components/ui/dog-photo";
import { Camera, wantsLiveCamera } from "@/components/check-in/camera";
import { api, dogPhotoUrl } from "@/lib/api";

/**
 * The dog's photo on its card, and the ways to change it: take one (the
 * tablet's camera, or the webcam on a computer), pick one from the device, or
 * take it off. A new photo replaces the old.
 */
export function DogPhotoEditor({ dogId, name, photo, groomerId, onChanged }: {
  dogId: string; name: string; photo: string | null; groomerId: string; onChanged: () => void;
}) {
  const camera = useRef<HTMLInputElement>(null);
  const picker = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [live, setLive] = useState(false);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  function upload(file: File | undefined) {
    if (!file) return;
    setBusy(true); setProblem(null); setLive(false);
    api.addDogPhoto(dogId, groomerId, file)
      .then(() => { setOpen(false); onChanged(); })
      .catch((e) => setProblem(String(e.message ?? e)))
      .finally(() => setBusy(false));
  }

  function remove() {
    if (!window.confirm(`Take ${name}'s photo off their profile?`)) return;
    setBusy(true); setProblem(null);
    api.removeDogPhoto(dogId, groomerId)
      .then(() => { setOpen(false); onChanged(); })
      .catch((e) => setProblem(String(e.message ?? e)))
      .finally(() => setBusy(false));
  }

  return (
    <div className="flex flex-col items-center gap-2">
      {photo ? (
        <a href={dogPhotoUrl(dogId, photo, "original")} target="_blank" rel="noreferrer" title={`See ${name}'s photo full size`}>
          <DogPhoto dogId={dogId} photo={photo} name={name} size="lg" />
        </a>
      ) : (
        <DogPhoto dogId={dogId} photo={null} name={name} size="lg" />
      )}

      {/* A tablet opens its own camera from capture=; a computer gets the webcam. */}
      <input ref={camera} type="file" accept="image/*" capture="environment" className="hidden"
             onChange={(e) => { upload(e.target.files?.[0]); e.target.value = ""; }} />
      <input ref={picker} type="file" accept="image/*,.heic" className="hidden"
             onChange={(e) => { upload(e.target.files?.[0]); e.target.value = ""; }} />

      {!open ? (
        <Button variant="outline" size="sm" disabled={busy} onClick={() => setOpen(true)}>
          {photo ? "Change photo" : "Add photo"}
        </Button>
      ) : (
        <div className="flex flex-col items-stretch gap-1.5">
          <Button variant="outline" size="sm" disabled={busy}
                  onClick={() => (wantsLiveCamera() ? setLive(true) : camera.current?.click())}>
            Take a photo
          </Button>
          <Button variant="outline" size="sm" disabled={busy} onClick={() => picker.current?.click()}>
            Choose a photo
          </Button>
          {photo && <Button variant="danger" size="sm" disabled={busy} onClick={remove}>Remove photo</Button>}
          <Button variant="ghost" size="sm" disabled={busy} onClick={() => { setOpen(false); setLive(false); }}>Cancel</Button>
        </div>
      )}
      {busy && <p className="text-xs text-muted-foreground">Saving…</p>}
      {problem && <p role="alert" className="max-w-40 text-center text-xs text-stop">{problem}</p>}

      {live && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-foreground/60 p-4">
          <div className="w-full max-w-2xl rounded-[var(--radius)] bg-card p-4 shadow-lg">
            <p className="mb-3 font-semibold">A photo of {name}</p>
            <Camera onPhoto={upload} onCancel={() => setLive(false)}
                    onChooseFile={() => { setLive(false); picker.current?.click(); }} />
          </div>
        </div>
      )}
    </div>
  );
}
