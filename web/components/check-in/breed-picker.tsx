"use client";

import { useEffect, useId, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/utils";

/**
 * A breed box with a real dropdown. Opening it shows the whole list, scrolled
 * to the breed already chosen and highlighted; typing narrows the list to the
 * names containing what was typed. Arrow keys move, Enter picks, Escape
 * closes. A name that is not on the list can still be typed: the form's "Did
 * you mean" handles it.
 *
 * (The browser's own suggestion list was used before. It only ever shows names
 * matching what is already in the box, so changing a chosen breed showed that
 * one breed and nothing else.)
 */
export function BreedPicker({ label, value, onChange, breeds, autoFocus }: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  breeds: string[];
  autoFocus?: boolean;
}) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState(false);          // narrowing, or the whole list?
  const [active, setActive] = useState(-1);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLUListElement>(null);

  const shown = useMemo(() => {
    const q = value.trim().toLowerCase();
    return typed && q ? breeds.filter((b) => b.toLowerCase().includes(q)) : breeds;
  }, [breeds, value, typed]);

  function show() {
    setTyped(false);
    setActive(breeds.findIndex((b) => b.toLowerCase() === value.trim().toLowerCase()));
    setOpen(true);
  }

  function pick(name: string) {
    onChange(name);
    setOpen(false);
  }

  // Keep the highlighted breed in view: centred when the list opens, just
  // inside the edge as the arrow keys move.
  const opened = useRef(false);
  useEffect(() => {
    if (!open) { opened.current = false; return; }
    const el = list.current?.querySelector<HTMLElement>(`[data-index="${active}"]`);
    el?.scrollIntoView({ block: opened.current ? "nearest" : "center" });
    opened.current = true;
  }, [open, active, shown]);

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!open) { show(); return; }
      const step = e.key === "ArrowDown" ? 1 : -1;
      setActive((a) => Math.max(0, Math.min(shown.length - 1, a + step)));
    } else if (e.key === "Enter" && open && shown[active]) {
      e.preventDefault();
      pick(shown[active]);
    } else if (e.key === "Escape" && open) {
      e.preventDefault();
      setOpen(false);
    }
  }

  return (
    <div className="relative">
      <input
        ref={input}
        role="combobox"
        aria-label={label}
        aria-expanded={open}
        aria-controls={`${id}-list`}
        aria-autocomplete="list"
        aria-activedescendant={open && active >= 0 ? `${id}-${active}` : undefined}
        autoComplete="off"
        autoFocus={autoFocus}
        value={value}
        onChange={(e) => { onChange(e.target.value); setTyped(true); setActive(0); setOpen(true); }}
        onClick={() => { if (!open) show(); }}
        onBlur={() => setOpen(false)}
        onKeyDown={onKeyDown}
        className="flex h-11 w-full rounded-[var(--radius)] border border-border bg-card pl-3 pr-10 text-base placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      />
      <button
        type="button"
        tabIndex={-1}
        aria-label={open ? "Close the breed list" : "Show every breed"}
        onMouseDown={(e) => e.preventDefault()}          // keep the box focused
        onClick={() => { if (open) setOpen(false); else { show(); input.current?.focus(); } }}
        className="absolute inset-y-0 right-0 grid w-10 place-items-center text-muted-foreground hover:text-foreground"
      >
        <svg viewBox="0 0 20 20" className={cn("size-4 transition-transform", open && "rotate-180")} fill="currentColor" aria-hidden>
          <path d="M5.2 7.5a.75.75 0 0 1 1.06.02L10 11.4l3.74-3.88a.75.75 0 1 1 1.08 1.04l-4.28 4.44a.75.75 0 0 1-1.08 0L5.18 8.56a.75.75 0 0 1 .02-1.06Z" />
        </svg>
      </button>

      {open && (
        <ul
          ref={list}
          id={`${id}-list`}
          role="listbox"
          onMouseDown={(e) => e.preventDefault()}          // a click picks before the box loses focus
          className="absolute z-20 mt-1 max-h-64 w-full overflow-y-auto rounded-[var(--radius)] border border-border bg-card py-1 text-sm shadow-lg"
        >
          {shown.map((b, i) => {
            const chosen = b.toLowerCase() === value.trim().toLowerCase();
            return (
              <li
                key={b}
                id={`${id}-${i}`}
                data-index={i}
                role="option"
                aria-selected={chosen}
                onMouseEnter={() => setActive(i)}
                onClick={() => pick(b)}
                className={cn(
                  "flex cursor-pointer items-center justify-between gap-2 px-3 py-2",
                  i === active && "bg-muted",
                  chosen && "font-semibold text-primary",
                )}
              >
                {b}
                {chosen && <span aria-hidden>✓</span>}
              </li>
            );
          })}
          {shown.length === 0 && (
            <li className="px-3 py-2 text-muted-foreground">No breed on the list contains &ldquo;{value.trim()}&rdquo;.</li>
          )}
        </ul>
      )}
    </div>
  );
}
