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
 * A list with headings (groupLabels) opens folded: just the headings, in bold,
 * each opening with a tap. The group of what is already chosen opens by
 * itself. Typing searches every group and shows the matches unfolded.
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
  const [unfolded, setUnfolded] = useState<Set<string>>(new Set());
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLUListElement>(null);

  const searching = typed && value.trim() !== "";
  const matches = useMemo(() => {
    const q = value.trim().toLowerCase();
    return searching ? options.filter((o) => o.name.toLowerCase().includes(q)) : options;
  }, [options, value, searching]);
  const groups = useMemo(() => [...new Set(options.map((o) => o.group ?? ""))], [options]);
  const folding = !!groupLabels && !searching;
  // The choices the arrow keys walk through: only those in unfolded groups.
  const shown = useMemo(
    () => (folding ? matches.filter((o) => unfolded.has(o.group ?? "")) : matches),
    [matches, folding, unfolded]);

  const isChosen = (o: ListOption) => o.name.toLowerCase() === value.trim().toLowerCase();

  function show() {
    const chosen = options.find(isChosen);
    const openGroups = new Set(chosen ? [chosen.group ?? ""] : []);
    setTyped(false);
    setUnfolded(openGroups);
    setActive(chosen ? (groupLabels ? options.filter((o) => openGroups.has(o.group ?? "")) : options).indexOf(chosen) : -1);
    setOpen(true);
  }

  function toggle(group: string) {
    setUnfolded((u) => {
      const next = new Set(u);
      if (next.has(group)) next.delete(group); else next.add(group);
      return next;
    });
    setActive(-1);
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
          {groupLabels
            ? groups.map((g) => {
                const items = matches.filter((o) => (o.group ?? "") === g);
                if (items.length === 0) return null;
                const isOpen = !folding || unfolded.has(g);
                return (
                  <li key={g} role="none">
                    <div
                      role={folding ? "button" : "presentation"}
                      aria-expanded={folding ? isOpen : undefined}
                      onClick={folding ? () => toggle(g) : undefined}
                      className={cn(
                        "flex items-center gap-2 px-3 py-2 text-xs font-bold uppercase tracking-wide text-foreground",
                        folding && "cursor-pointer hover:bg-muted",
                      )}
                    >
                      {folding && (
                        <span aria-hidden className={cn("inline-block text-primary transition-transform", isOpen && "rotate-90")}>▸</span>
                      )}
                      {groupLabels[g] ?? g}
                      {folding && <span className="ml-auto font-normal normal-case tracking-normal text-muted-foreground">{items.length}</span>}
                    </div>
                    {isOpen && (
                      <ul role="group" aria-label={groupLabels[g] ?? g}>
                        {items.map((o) => (
                          <OptionRow key={o.name} id={id} option={o} index={shown.indexOf(o)} active={active}
                                  chosen={isChosen(o)} onHover={setActive} onPick={pick} indent />
                        ))}
                      </ul>
                    )}
                  </li>
                );
              })
            : shown.map((o, i) => (
                <OptionRow key={o.name} id={id} option={o} index={i} active={active}
                        chosen={isChosen(o)} onHover={setActive} onPick={pick} />
              ))}
          {matches.length === 0 && (
            <li className="px-3 py-2 text-muted-foreground">Nothing on the list contains &ldquo;{value.trim()}&rdquo;.</li>
          )}
        </ul>
      )}
    </div>
  );
}

function OptionRow({ id, option, index, active, chosen, onHover, onPick, indent = false }: {
  id: string; option: ListOption; index: number; active: number; chosen: boolean;
  onHover: (i: number) => void; onPick: (name: string) => void; indent?: boolean;
}) {
  return (
    <li
      id={`${id}-${index}`}
      data-index={index}
      role="option"
      aria-selected={chosen}
      onMouseEnter={() => onHover(index)}
      onClick={() => onPick(option.name)}
      className={cn(
        "flex cursor-pointer items-center justify-between gap-2 py-2 pr-3",
        indent ? "pl-8" : "pl-3",
        index === active && "bg-muted",
        chosen && "font-semibold text-primary",
      )}
    >
      {option.name}
      {chosen && <span aria-hidden>✓</span>}
    </li>
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
