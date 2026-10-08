// The browser's half of a passkey: ask the device (fingerprint, face, its PIN,
// or a phone scanned from a QR code) to make or use a passkey, and turn the
// answer into JSON for the backend. The backend's library does the checking.
//
// The options and answers travel as JSON with binary parts in base64url; the
// browser's API wants and gives ArrayBuffers. These are the conversions.

const toBytes = (b64url: string) => {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(b64url.length / 4) * 4, "=");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
};
const toB64url = (buf: ArrayBuffer | null | undefined) =>
  buf ? btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "") : null;

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const descriptors = (list: Json[] | undefined) =>
  (list ?? []).map((c) => ({ ...c, id: toBytes(c.id) })) as unknown as PublicKeyCredentialDescriptor[];

/** Whether this browser can use passkeys at all. */
export const passkeysSupported = () => typeof window !== "undefined" && !!window.PublicKeyCredential;

/** Make a new passkey from the backend's registration options. */
export async function makePasskey(options: Json): Promise<Json> {
  const cred = await navigator.credentials.create({
    publicKey: {
      ...options,
      challenge: toBytes(options.challenge),
      user: { ...options.user, id: toBytes(options.user.id) },
      excludeCredentials: descriptors(options.excludeCredentials),
    } as unknown as PublicKeyCredentialCreationOptions,
  }) as PublicKeyCredential | null;
  if (!cred) throw new Error("No passkey was made.");
  const r = cred.response as AuthenticatorAttestationResponse;
  return {
    id: cred.id, rawId: toB64url(cred.rawId), type: cred.type,
    response: {
      clientDataJSON: toB64url(r.clientDataJSON), attestationObject: toB64url(r.attestationObject),
      transports: r.getTransports?.() ?? [],
    },
    clientExtensionResults: cred.getClientExtensionResults(),
    authenticatorAttachment: cred.authenticatorAttachment,
  };
}

/** Sign the backend's challenge with one of this manager's passkeys. */
export async function signWithPasskey(options: Json): Promise<Json> {
  const cred = await navigator.credentials.get({
    publicKey: {
      ...options,
      challenge: toBytes(options.challenge),
      allowCredentials: descriptors(options.allowCredentials),
    } as unknown as PublicKeyCredentialRequestOptions,
  }) as PublicKeyCredential | null;
  if (!cred) throw new Error("No passkey was used.");
  const r = cred.response as AuthenticatorAssertionResponse;
  return {
    id: cred.id, rawId: toB64url(cred.rawId), type: cred.type,
    response: {
      clientDataJSON: toB64url(r.clientDataJSON), authenticatorData: toB64url(r.authenticatorData),
      signature: toB64url(r.signature), userHandle: toB64url(r.userHandle),
    },
    clientExtensionResults: cred.getClientExtensionResults(),
    authenticatorAttachment: cred.authenticatorAttachment,
  };
}

/** A cancelled or timed-out prompt, said plainly. */
export function passkeyProblem(e: unknown): string {
  if (e instanceof DOMException && (e.name === "NotAllowedError" || e.name === "AbortError")) {
    return "The passkey prompt was closed or timed out. Try again when you're ready.";
  }
  if (e instanceof DOMException && e.name === "InvalidStateError") {
    return "This device already has a passkey for you.";
  }
  if (e instanceof DOMException && e.name === "SecurityError") {
    return "Passkeys only work at http://localhost:3000 (or the shop's own https address).";
  }
  return e instanceof Error ? e.message : String(e);
}
