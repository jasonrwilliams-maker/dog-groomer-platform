"use client";

import { useEffect, useId, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/utils";

/** One choice in a list, and the heading it sits under (if the list has headings). */
export type ListOption = { name: string; group?: string };

/**
 * A box with a real dropdown, for picking from a shop list (breeds,
 * allergies). Opening it shows the whole list, scrolled to what is already
 * chosen and highlighted; typing narrows it to the names containing what was
 * typed. Arrow keys move, Enter picks, Escape closes. A name not on the list
 * can still be typed: NotOnList, below, handles it.
 *
 * (The browser's own suggestion list was used for breeds at first. It only
 * shows names matching what is already in the box, so changing a chosen breed
 * showed that one breed and nothing else.)
 */
export function ListPicker({ label, value, onChange, options, groupLabels, autoFocus, placeholder }: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  options: ListOption[];
  /** Headings to show above each group, by group key. */
  groupLabels?: Record<string, string>;
  autoFocus?: boolean;
  placeholder?: string;
}) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState(false);          // narrowing, or the whole list?
  const [active, setActive] = useState(-1);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLUListElement>(null);

  const shown = useMemo(() => {
    const q = value.trim().toLowerCase();
    return typed && q ? options.filter((o) => o.name.toLowerCase().includes(q)) : options;
  }, [options, value, typed]);

  function show() {
    setTyped(false);
    setActive(options.findIndex((o) => o.name.toLowerCase() === value.trim().toLowerCase()));
    setOpen(true);
  }

  function pick(name: string) {
    onChange(name);
    setOpen(false);
  }

  // Keep the highlighted choice in view: centred when the list opens, just
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
      pick(shown[active].name);
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
        placeholder={placeholder}
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
        aria-label={open ? `Close the ${label.toLowerCase()} list` : `Show the whole ${label.toLowerCase()} list`}
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
          {shown.map((o, i) => {
            const chosen = o.name.toLowerCase() === value.trim().toLowerCase();
            const heading = groupLabels && o.group && o.group !== shown[i - 1]?.group ? groupLabels[o.group] : null;
            return (
              <li key={o.name} role="none">
                {heading && (
                  <div role="presentation" className="px-3 pt-2 pb-1 text-xs font-semibold uppercase tracking-wide text-primary">
                    {heading}
                  </div>
                )}
                <div
                  id={`${id}-${i}`}
                  data-index={i}
                  role="option"
                  aria-selected={chosen}
                  onMouseEnter={() => setActive(i)}
                  onClick={() => pick(o.name)}
                  className={cn(
                    "flex cursor-pointer items-center justify-between gap-2 px-3 py-2",
                    i === active && "bg-muted",
                    chosen && "font-semibold text-primary",
                  )}
                >
                  {o.name}
                  {chosen && <span aria-hidden>✓</span>}
                </div>
              </li>
            );
          })}
          {shown.length === 0 && (
            <li className="px-3 py-2 text-muted-foreground">Nothing on the list contains &ldquo;{value.trim()}&rdquo;.</li>
          )}
        </ul>
      )}
    </div>
  );
}

/**
 * "Did you mean…?" — shown once the typing stops on a name that is not on the
 * list. Nothing shows for a name that is. `onNew` offers adding it as new;
 * without it, the groomer picks from the list.
 */
export function NotOnList({ value, known, suggest, what, onPick, onNew }: {
  value: string;
  known: string[];
  suggest: (q: string) => Promise<{ name: string }[]>;
  /** "breed list", "allergy list". */
  what: string;
  onPick: (name: string) => void;
  onNew?: () => void;
}) {
  const [near, setNear] = useState<{ name: string }[] | null>(null);
  useEffect(() => {
    setNear(null);
    const t = setTimeout(() => { suggest(value).then(setNear).catch(() => setNear(null)); }, 350);
    return () => clearTimeout(t);
  }, [value, suggest]);

  const onList = known.some((k) => k.toLowerCase() === value.trim().toLowerCase());
  if (onList || near === null) return null;

  return (
    <div className="flex flex-col gap-2 rounded-[var(--radius)] border border-warn/30 bg-warn-soft p-3 text-sm">
      <p className="font-medium text-warn">&ldquo;{value}&rdquo; isn&apos;t on the {what}.</p>
      {near.length > 0 && (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-muted-foreground">Did you mean</span>
          {near.map((b) => (
            <button key={b.name} type="button" onClick={() => onPick(b.name)}
                    className="rounded-full border border-primary/40 bg-card px-3 py-1 font-medium hover:bg-muted">
              {b.name}
            </button>
          ))}
        </div>
      )}
      {onNew && (
        <button type="button" onClick={onNew}
                className="self-start text-muted-foreground underline underline-offset-2 hover:text-foreground">
          No, it&apos;s one the list doesn&apos;t have
        </button>
      )}
    </div>
  );
}
