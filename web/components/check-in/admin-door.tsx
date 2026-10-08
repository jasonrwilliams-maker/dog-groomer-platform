"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Field } from "@/components/check-in/profile-fields";
import { Problem } from "@/components/check-in/walk-in-form";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  api, getAdminSession, onAdminLocked, Refusal, setAdminSession,
  type AdminAccess, type AdminSession, type Groomer, type Passkey,
} from "@/lib/api";
import { makePasskey, passkeyProblem, passkeysSupported, signWithPasskey } from "@/lib/passkey";
import { formatDate, formatTime } from "@/lib/utils";

const clock = (iso: string) => formatTime(new Date(iso).toTimeString().slice(0, 8));

/**
 * Admin, behind its door. Everyday screens only need a name; Admin needs the
 * manager to prove it is them: a passkey (fingerprint, face, or their phone)
 * or their PIN. It locks again by itself after a while, on "Lock Admin", or
 * when someone else signs in.
 */
export function AdminGate({ me, children }: { me: Groomer; children: ReactNode }) {
  const [session, setSession] = useState<AdminSession | null>(() => getAdminSession(me.id));

  useEffect(() => onAdminLocked(() => setSession(null)), []);
  // Lock on time, as the backend will.
  useEffect(() => {
    if (!session) return;
    const t = setTimeout(() => setAdminSession(null), new Date(session.expires_at).getTime() - Date.now());
    return () => clearTimeout(t);
  }, [session]);

  function opened(s: AdminSession) { setAdminSession(s); setSession(s); }
  async function lock() {
    await api.lockAdmin().catch(() => { /* locked here either way */ });
    setAdminSession(null);
  }

  if (!session) return <AdminDoor me={me} onOpen={opened} />;
  return (
    <div className="flex flex-col gap-4">
      <OpenBar session={session} me={me} onLock={lock} />
      {children}
    </div>
  );
}

function useBusy() {
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<Refusal | null>(null);
  const [error, setError] = useState<string | null>(null);
  const run = useCallback(async (f: () => Promise<void>) => {
    setBusy(true); setRefusal(null); setError(null);
    try { await f(); } catch (e) {
      if (e instanceof Refusal) setRefusal(e); else setError(passkeyProblem(e));
    } finally { setBusy(false); }
  }, []);
  return { busy, refusal, error, run };
}

function AdminDoor({ me, onOpen }: { me: Groomer; onOpen: (s: AdminSession) => void }) {
  const [access, setAccess] = useState<AdminAccess | null>(null);
  const [pin, setPin] = useState("");
  const [pin2, setPin2] = useState("");
  const { busy, refusal, error, run } = useBusy();
  const canPasskey = passkeysSupported();

  useEffect(() => { api.adminAccess(me.id).then(setAccess).catch(() => setAccess(null)); }, [me.id]);

  const withPasskey = () => run(async () => {
    const options = await api.passkeyOpeningOptions(me.id);
    onOpen(await api.openAdminWithPasskey(me.id, await signWithPasskey(options)));
  });
  const withPin = (e: React.FormEvent) => { e.preventDefault(); run(async () => onOpen(await api.openAdminWithPin(me.id, pin))); };
  const firstPasskey = () => run(async () => {
    const options = await api.passkeyRegistrationOptions(me.id);
    const done = await api.registerPasskey(me.id, await makePasskey(options), `${me.name}'s first passkey`);
    if (done.session) onOpen(done.session);
  });
  const firstPin = (e: React.FormEvent) => {
    e.preventDefault();
    run(async () => {
      const done = await api.setAdminPin(me.id, pin);
      if (done.session) onOpen(done.session);
    });
  };

  if (!access) return <p className="text-muted-foreground">Checking Admin…</p>;

  return (
    <Card className="mx-auto w-full max-w-lg">
      <CardHeader>
        <CardTitle>🔒 Admin is locked</CardTitle>
        <p className="text-lg font-semibold">
          {access.set_up ? `Prove it's you, ${me.name}` : `Set up how you open Admin, ${me.name}`}
        </p>
        <p className="text-sm text-muted-foreground">
          {access.set_up
            ? "Admin is for managers only. It locks again after 30 minutes, or when you lock it."
            : "This is the first time. Choose a passkey (your fingerprint, face or phone), a PIN, or both. After today, only you can change them."}
        </p>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {access.set_up ? (
          <>
            {access.passkeys > 0 && canPasskey && (
              <Button variant="go" size="lg" disabled={busy} onClick={withPasskey}>
                {busy ? "Waiting for your passkey…" : "Use my passkey"}
              </Button>
            )}
            {access.passkeys > 0 && (
              <p className="-mt-2 text-xs text-muted-foreground">
                Your fingerprint, face or device PIN. On a shop tablet, choose &ldquo;use a phone&rdquo; and scan the code with your own phone.
              </p>
            )}
            {access.has_pin && (
              <form onSubmit={withPin} className="flex flex-wrap items-end gap-2">
                <Field label={access.passkeys > 0 ? "Or your PIN" : "Your PIN"} className="w-40">
                  <Input type="password" inputMode="numeric" autoComplete="off" maxLength={8}
                         value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} />
                </Field>
                <Button type="submit" variant={access.passkeys > 0 ? "outline" : "default"} size="lg"
                        disabled={busy || pin.length < 4}>Open with PIN</Button>
              </form>
            )}
          </>
        ) : (
          <>
            {canPasskey && (
              <div className="flex flex-col gap-1">
                <Button variant="go" size="lg" disabled={busy} onClick={firstPasskey}>
                  {busy ? "Waiting for your device…" : "Set up a passkey"}
                </Button>
                <p className="text-xs text-muted-foreground">Recommended. Nothing to remember; your fingerprint or face never leaves your device.</p>
              </div>
            )}
            <form onSubmit={firstPin} className="flex flex-wrap items-end gap-2">
              <Field label={canPasskey ? "Or set a PIN" : "Set a PIN"} className="w-40">
                <Input type="password" inputMode="numeric" autoComplete="new-password" maxLength={8}
                       value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} />
              </Field>
              <Field label="Again" className="w-40">
                <Input type="password" inputMode="numeric" autoComplete="new-password" maxLength={8}
                       value={pin2} onChange={(e) => setPin2(e.target.value.replace(/\D/g, ""))} />
              </Field>
              <Button type="submit" variant="outline" size="lg" disabled={busy || pin.length < 4 || pin !== pin2}>Set PIN</Button>
            </form>
            <p className="-mt-2 text-xs text-muted-foreground">4 to 8 digits, typed twice.</p>
            {pin2.length >= pin.length && pin.length >= 4 && pin !== pin2 && (
              <p className="text-sm text-stop">The two PINs don&apos;t match.</p>
            )}
          </>
        )}
        <Problem refusal={refusal} error={error} />
      </CardContent>
    </Card>
  );
}

/** Admin is open: for whom, until when, and the way to lock it or manage how it opens. */
function OpenBar({ session, me, onLock }: { session: AdminSession; me: Groomer; onLock: () => void }) {
  const [managing, setManaging] = useState(false);
  return (
    <div className="rounded-[var(--radius)] border border-ok/30 bg-ok-soft p-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm">
          <span className="font-semibold text-ok">🔓 Admin open for {session.name}</span>
          <span className="text-muted-foreground"> · locks at {clock(session.expires_at)}</span>
        </p>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => setManaging((m) => !m)}>
            {managing ? "Done" : "Passkeys and PIN"}
          </Button>
          <Button variant="outline" size="sm" onClick={onLock}>Lock Admin</Button>
        </div>
      </div>
      {managing && <ManageAccess me={me} />}
    </div>
  );
}

function ManageAccess({ me }: { me: Groomer }) {
  const [keys, setKeys] = useState<Passkey[] | null>(null);
  const [access, setAccess] = useState<AdminAccess | null>(null);
  const [label, setLabel] = useState("");
  const [pin, setPin] = useState("");
  const [done, setDone] = useState<string | null>(null);
  const { busy, refusal, error, run } = useBusy();

  const load = useCallback(() => {
    api.myPasskeys().then(setKeys).catch(() => setKeys([]));
    api.adminAccess(me.id).then(setAccess).catch(() => setAccess(null));
  }, [me.id]);
  useEffect(load, [load]);

  const add = () => run(async () => {
    const options = await api.passkeyRegistrationOptions(me.id);
    await api.registerPasskey(me.id, await makePasskey(options), label.trim() || `Passkey ${(keys?.length ?? 0) + 1}`);
    setLabel(""); setDone("Passkey added."); load();
  });
  const remove = (k: Passkey) => run(async () => { await api.removePasskey(k.id); setDone(`${k.label} removed.`); load(); });
  const savePin = (e: React.FormEvent) => {
    e.preventDefault();
    run(async () => { await api.setAdminPin(me.id, pin); setPin(""); setDone("PIN saved."); load(); });
  };

  return (
    <div className="mt-3 grid gap-4 border-t border-ok/20 pt-3 md:grid-cols-2">
      <section className="flex flex-col gap-2">
        <h4 className="text-sm font-semibold">Your passkeys</h4>
        {keys?.length === 0 && <p className="text-sm text-muted-foreground">None yet.</p>}
        <ul className="flex flex-col gap-2">
          {keys?.map((k) => (
            <li key={k.id} className="flex flex-wrap items-center justify-between gap-2 text-sm">
              <span>
                <span className="font-medium">{k.label}</span>
                <span className="block text-xs text-muted-foreground">
                  Added {formatDate(k.added_at.slice(0, 10))}
                  {k.last_used_at ? `, last used ${formatDate(k.last_used_at.slice(0, 10))}` : ", not used yet"}
                </span>
              </span>
              <Button variant="danger" size="sm" disabled={busy} onClick={() => remove(k)}>Remove</Button>
            </li>
          ))}
        </ul>
        {passkeysSupported() && (
          <div className="flex flex-wrap items-end gap-2">
            <Field label="Name it" className="w-48">
              <Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder={`${me.name}'s phone`} />
            </Field>
            <Button variant="outline" disabled={busy} onClick={add}>Add a passkey</Button>
          </div>
        )}
      </section>
      <section className="flex flex-col gap-2">
        <h4 className="text-sm font-semibold">{access?.has_pin ? "Change your PIN" : "Set a PIN"}</h4>
        <p className="text-xs text-muted-foreground">For when your phone is dead or not with you.</p>
        <form onSubmit={savePin} className="flex flex-wrap items-end gap-2">
          <Field label="New PIN (4 to 8 digits)" className="w-48">
            <Input type="password" inputMode="numeric" autoComplete="new-password" maxLength={8}
                   value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} />
          </Field>
          <Button type="submit" variant="outline" disabled={busy || pin.length < 4}>Save PIN</Button>
        </form>
      </section>
      <div className="md:col-span-2">
        <Problem refusal={refusal} error={error} />
        {done && !refusal && !error && <p className="text-sm text-ok">{done}</p>}
      </div>
    </div>
  );
}
