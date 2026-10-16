"use client";

import { useEffect, useState, type ReactNode } from "react";
import { Choice, Field } from "@/components/check-in/profile-fields";
import { Problem } from "@/components/check-in/walk-in-form";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { api, Refusal, type StaffForm, type StaffMember } from "@/lib/api";
import { formatDate } from "@/lib/utils";

const ROLES = [{ value: "groomer", label: "Groomer" }, { value: "manager", label: "Manager" }] as const;
const ROLE_NAME = { groomer: "Groomer", manager: "Manager" } as const;

/**
 * The staff list, from Admin (section 34): who works here, and who used to.
 * A manager adds someone, changes their name, email or role, marks them as no
 * longer working here (or back again), and resets another manager's Admin
 * access when their phone is lost. Nobody is deleted.
 */
export function StaffList({ groomerId, onChanged }: { groomerId: string; onChanged?: () => void }) {
  const [staff, setStaff] = useState<StaffMember[] | null>(null);
  // The one thing open: "new" (adding someone), or "change", "leave" or "reset" and whose.
  const [open, setOpen] = useState<string | null>(null);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const load = () => api.staff().then(setStaff).catch((e) => setError(String(e.message ?? e)));
  useEffect(() => { load(); }, []);

  async function act(f: () => Promise<unknown>, said: string) {
    setRefusal(null); setError(null); setDone(null);
    try {
      await f();
      setDone(said); setOpen(null); load(); onChanged?.();
    } catch (e) {
      if (e instanceof Refusal) setRefusal(e); else setError(String((e as Error).message ?? e));
    }
  }

  if (!staff) return error ? <Problem refusal={null} error={error} /> : <p className="text-muted-foreground">Loading…</p>;

  const working = staff.filter((s) => s.working_here);
  const gone = staff.filter((s) => !s.working_here);

  const show = (what: string | null) => { setOpen(what); setDone(null); setRefusal(null); setError(null); };

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <CardHeader>
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <CardTitle>Staff · {working.length} working here</CardTitle>
              <p className="text-sm text-muted-foreground">
                Everyone who can sign in at the counter. A manager also opens Admin.
              </p>
            </div>
            {open !== "new" && <Button onClick={() => show("new")}>Add a staff member</Button>}
          </div>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          {open === "new" && (
            <StaffEditor title="New staff member" saveLabel="Add to the staff list"
                         onSave={(f) => act(() => api.addStaff(f), `${f.name.trim()} is on the staff list.`)}
                         onCancel={() => show(null)} />
          )}
          <ul className="flex flex-col divide-y divide-border">
            {working.map((s) => (
              <li key={s.id} className="flex flex-col gap-3 py-3">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <span className="min-w-0">
                    <span className="font-medium">{s.name}</span>
                    {s.id === groomerId && <span className="text-muted-foreground"> (you)</span>}{" "}
                    <Badge>{ROLE_NAME[s.role]}</Badge>
                    <span className="block text-sm text-muted-foreground">{s.email}</span>
                    {s.role === "manager" && (
                      <span className="block text-sm text-muted-foreground">
                        {s.admin_set_up ? "Admin set up" : "Admin not set up yet: they set it up the next time they open Admin"}
                      </span>
                    )}
                    {s.booked_ahead > 0 && (
                      <span className="block text-sm text-muted-foreground">
                        {s.booked_ahead === 1 ? "1 groom" : `${s.booked_ahead} grooms`} booked ahead
                      </span>
                    )}
                  </span>
                  {!open?.endsWith(s.id) && (
                    <span className="flex flex-wrap gap-2">
                      <Button variant="outline" size="sm" onClick={() => show(`change:${s.id}`)}>Change</Button>
                      {s.role === "manager" && s.id !== groomerId && (
                        <Button variant="outline" size="sm" onClick={() => show(`reset:${s.id}`)}>Reset Admin access</Button>
                      )}
                      <Button variant="danger" size="sm" onClick={() => show(`leave:${s.id}`)}>No longer works here</Button>
                    </span>
                  )}
                </div>
                {open === `change:${s.id}` && (
                  <StaffEditor title={`Change ${s.name}`} saveLabel="Save changes" start={s}
                               onSave={(f) => act(() => api.changeStaff(s.id, f), `${f.name.trim()} is saved.`)}
                               onCancel={() => show(null)} />
                )}
                {open === `leave:${s.id}` && (
                  <Confirm title={`Mark ${s.name} as no longer working here?`} yes="Yes, they no longer work here"
                           onYes={() => act(() => api.staffLeft(s.id), `${s.name} is marked as no longer working here.`)}
                           onCancel={() => show(null)}>
                    {s.name} comes off the Welcome screen and the list of groomers a booking can go to. Their name
                    stays on every past groom and record.
                    {s.role === "manager" && " Their passkeys and PIN are removed."}
                  </Confirm>
                )}
                {open === `reset:${s.id}` && (
                  <Confirm title={`Reset ${s.name}'s Admin access?`} yes="Yes, reset Admin access"
                           onYes={() => act(() => api.resetAdminAccess(s.id),
                                            `${s.name}'s Admin access is reset. They set it up again the next time they open Admin.`)}
                           onCancel={() => show(null)}>
                    For a lost or replaced phone, or a forgotten PIN. Every passkey and the PIN {s.name} uses to open
                    Admin are removed, and Admin locks for them. The next time {s.name} opens Admin, they set up a new
                    passkey or PIN themselves. Do this with {s.name} in the shop, ready to set it up straight away.
                  </Confirm>
                )}
              </li>
            ))}
          </ul>
          <Problem refusal={refusal} error={error} />
          {done && !refusal && !error && <p role="status" className="text-sm text-ok">{done}</p>}
        </CardContent>
      </Card>

      {gone.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>No longer working here · {gone.length}</CardTitle>
            <p className="text-sm text-muted-foreground">
              Kept so their name stays on past grooms and records. They can&apos;t sign in or be booked.
            </p>
          </CardHeader>
          <CardContent>
            <ul className="flex flex-col divide-y divide-border">
              {gone.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-3 py-2.5">
                  <span className="min-w-0">
                    <span className="font-medium">{s.name}</span>
                    <span className="text-muted-foreground"> · {ROLE_NAME[s.role]}</span>
                    <span className="block text-sm text-muted-foreground">
                      {s.email}{s.left_at && ` · left ${formatDate(s.left_at.slice(0, 10))}`}
                    </span>
                  </span>
                  <Button variant="outline" size="sm"
                          onClick={() => act(() => api.staffBack(s.id), `${s.name} is working here again.`)}>
                    Working here again
                  </Button>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

/** A question before a change that matters, with its two answers side by side. */
function Confirm({ title, yes, onYes, onCancel, children }: {
  title: string; yes: string; onYes: () => void; onCancel: () => void; children: ReactNode;
}) {
  return (
    <div className="flex flex-col gap-3 rounded-[var(--radius)] border border-primary/40 p-4">
      <p className="font-semibold">{title}</p>
      <p className="text-sm">{children}</p>
      <div className="flex flex-wrap gap-2">
        <Button onClick={onYes}>{yes}</Button>
        <Button variant="outline" onClick={onCancel}>Cancel</Button>
      </div>
    </div>
  );
}

function StaffEditor({ title, saveLabel, start, onSave, onCancel }: {
  title: string; saveLabel: string; start?: StaffMember;
  onSave: (f: StaffForm) => void; onCancel: () => void;
}) {
  const [name, setName] = useState(start?.name ?? "");
  const [email, setEmail] = useState(start?.email ?? "");
  const [role, setRole] = useState<StaffForm["role"] | null>(start?.role ?? null);
  const ready = name.trim() !== "" && email.trim() !== "" && role !== null;

  return (
    <form className="flex flex-col gap-3 rounded-[var(--radius)] border border-primary/40 p-4"
          onSubmit={(e) => { e.preventDefault(); if (ready) onSave({ name, email, role: role! }); }}>
      <p className="font-semibold">{title}</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Name" note="As it shows on the Welcome screen.">
          <Input value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" />
        </Field>
        <Field label="Email">
          <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="off" />
        </Field>
      </div>
      <Field label="Role" group note="A manager also opens Admin.">
        <Choice options={[...ROLES]} value={role} onChange={setRole} />
      </Field>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" disabled={!ready}>{saveLabel}</Button>
        <Button type="button" variant="outline" onClick={onCancel}>Cancel</Button>
      </div>
    </form>
  );
}
