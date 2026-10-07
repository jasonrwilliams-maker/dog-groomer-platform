"use client";

import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";

/**
 * Whether "Take a photo" should open the camera inside the page. A tablet or
 * phone opens its own camera app from a file input (sharper, with autofocus);
 * a computer ignores that and shows the file picker, so it gets the webcam here.
 */
export function wantsLiveCamera(): boolean {
  return typeof window !== "undefined"
    && !!navigator.mediaDevices?.getUserMedia
    && !window.matchMedia("(pointer: coarse)").matches;
}

/** The webcam, live: take a picture, look at it, use it or take another. */
export function Camera({ onPhoto, onCancel, onChooseFile }: {
  onPhoto: (file: File) => void;
  onCancel: () => void;
  /** Where to go when there is no camera to use. */
  onChooseFile: () => void;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const stream = useRef<MediaStream | null>(null);
  const [ready, setReady] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [shot, setShot] = useState<{ file: File; url: string } | null>(null);
  const [snapping, setSnapping] = useState(false);

  useEffect(() => {
    let cancelled = false;
    // Ask for the sharpest picture the camera has; it gives what it can.
    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: "environment", width: { ideal: 3840 }, height: { ideal: 2160 } }, audio: false })
      .then((s) => {
        if (cancelled) { s.getTracks().forEach((t) => t.stop()); return; }
        stream.current = s;
        if (video.current) video.current.srcObject = s;
      })
      .catch((e: DOMException) => {
        setProblem(e.name === "NotAllowedError"
          ? "The browser wasn't allowed to use the camera. Allow it in the address bar, or choose a file instead."
          : e.name === "NotFoundError"
            ? "This computer has no camera. Choose a file instead."
            : `The camera couldn't start (${e.message || e.name}). Choose a file instead.`);
      });
    return () => {
      cancelled = true;
      stream.current?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  useEffect(() => () => { if (shot) URL.revokeObjectURL(shot.url); }, [shot]);

  function snap() {
    const v = video.current;
    if (!v || !v.videoWidth) return;
    setSnapping(true);
    const canvas = document.createElement("canvas");
    canvas.width = v.videoWidth;
    canvas.height = v.videoHeight;
    canvas.getContext("2d")!.drawImage(v, 0, 0);
    canvas.toBlob((blob) => {
      setSnapping(false);
      if (!blob) return;
      const file = new File([blob], `camera-${Date.now()}.jpg`, { type: "image/jpeg" });
      setShot({ file, url: URL.createObjectURL(blob) });
    }, "image/jpeg", 0.92);
  }

  if (problem) {
    return (
      <div className="flex flex-col gap-3">
        <p role="alert" className="text-sm text-stop">{problem}</p>
        <div className="flex flex-wrap gap-3">
          <Button size="lg" onClick={onChooseFile}>Choose a file</Button>
          <Button variant="ghost" size="lg" onClick={onCancel}>Back</Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="overflow-hidden rounded-[var(--radius)] border border-border bg-black">
        {shot && <img src={shot.url} alt="The picture just taken" className="max-h-[60vh] w-full object-contain" />}
        {/* Kept running behind the preview, so Retake is instant. */}
        <video ref={video} autoPlay playsInline muted onLoadedMetadata={() => setReady(true)}
               className={shot ? "hidden" : "max-h-[60vh] w-full object-contain"} />
      </div>
      <p className="text-sm text-muted-foreground">
        {shot ? "Can you read every date? If not, take it again."
              : "Hold the paperwork (or the phone screen) flat and close, so the dates fill the picture."}
      </p>
      <div className="flex flex-wrap gap-3">
        {shot ? (
          <>
            <Button size="lg" onClick={() => onPhoto(shot.file)}>Use this photo</Button>
            <Button variant="outline" size="lg" onClick={() => setShot(null)}>Retake</Button>
          </>
        ) : (
          <Button size="lg" disabled={!ready || snapping} onClick={snap}>
            {!ready ? "Starting the camera…" : snapping ? "Taking…" : "Take the picture"}
          </Button>
        )}
        <Button variant="ghost" size="lg" onClick={onCancel}>Cancel</Button>
      </div>
    </div>
  );
}
