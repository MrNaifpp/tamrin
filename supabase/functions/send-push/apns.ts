// Builds the APNs provider JWT (ES256) and sends an alert push over HTTP/2.

function b64url(bytes: Uint8Array): string {
  const s = btoa(String.fromCharCode(...bytes));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function makeApnsJwt(opts: {
  keyId: string;
  teamId: string;
  authKeyPem: string;
  nowSeconds: number;
}): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(opts.authKeyPem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64url(new TextEncoder().encode(
    JSON.stringify({ alg: "ES256", kid: opts.keyId }),
  ));
  const payload = b64url(new TextEncoder().encode(
    JSON.stringify({ iss: opts.teamId, iat: opts.nowSeconds }),
  ));
  const signingInput = `${header}.${payload}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

// Apple wants one provider token reused for 20 to 60 minutes, and answers 429
// TooManyProviderTokenUpdates when it changes more often. Every outbox row is
// its own send-push call, so a token minted per call meant one new token per
// recipient of a group push. Instead every call shares the token stored in the
// database and a new one is made once it is this old.
export const PROVIDER_TOKEN_MAX_AGE_SECONDS = 50 * 60;

export async function sharedProviderToken(opts: {
  nowSeconds: number;
  mint: (nowSeconds: number) => Promise<string>;
  read: () => Promise<{ token: string; issuedAt: number } | null>;
  // Stores the token unless a fresh one is already there, and answers with
  // whichever token is stored. A burst that finds the old token expired then
  // still ends up on one token. null when the store cannot be used.
  claim: (token: string, issuedAt: number) => Promise<string | null>;
}): Promise<string> {
  const stored = await opts.read();
  if (stored && opts.nowSeconds - stored.issuedAt < PROVIDER_TOKEN_MAX_AGE_SECONDS) {
    return stored.token;
  }
  const minted = await opts.mint(opts.nowSeconds);
  return (await opts.claim(minted, opts.nowSeconds)) ?? minted;
}

export async function sendApns(opts: {
  host: string; // https://api.sandbox.push.apple.com
  deviceToken: string;
  topic: string; // bundle id
  jwt: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
}): Promise<{ ok: boolean; status: number; text: string }> {
  const res = await fetch(`${opts.host}/3/device/${opts.deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${opts.jwt}`,
      "apns-topic": opts.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title: opts.title, body: opts.body }, sound: "default" },
      ...opts.data,
    }),
  });
  const text = await res.text();
  return { ok: res.ok, status: res.status, text };
}
