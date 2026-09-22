// Moyasar REST client. HTTP Basic: the secret key is the username, the
// password is empty (docs: `curl … -u sk_test_xxx:`). Only ever runs inside an
// Edge Function; the secret never reaches the app.
export type MoyasarPayment = {
  id: string;
  status: string;
  amount: number;
  currency: string;
  /// Cumulative, in halalas. The only honest answer to "how much has gone
  /// back", because a partial refund leaves `status` saying "refunded" too.
  refunded?: number;
  source?: { type?: string; message?: string };
  metadata?: Record<string, unknown>;
  splits?: Array<{ recipient_id: string; amount: number }> | null;
};

export function basicAuthHeader(secretKey: string): string {
  return "Basic " + btoa(`${secretKey}:`);
}

export class MoyasarError extends Error {
  constructor(public status: number, public body: string) {
    super(`Moyasar ${status}: ${body.slice(0, 300)}`);
  }
}

export function makeMoyasarClient(
  secretKey: string,
  fetchImpl: typeof fetch = fetch,
  baseUrl = "https://api.moyasar.com/v1",
) {
  const headers = { Authorization: basicAuthHeader(secretKey), "Content-Type": "application/json" };

  async function call(
    method: "GET" | "POST",
    path: string,
    body?: Record<string, unknown>,
  ): Promise<MoyasarPayment> {
    const res = await fetchImpl(`${baseUrl}${path}`, {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await res.text();
    if (!res.ok) throw new MoyasarError(res.status, text);
    return JSON.parse(text) as MoyasarPayment;
  }

  return {
    fetchPayment: (id: string) => call("GET", `/payments/${encodeURIComponent(id)}`),
    capture: (id: string) => call("POST", `/payments/${encodeURIComponent(id)}/capture`),
    voidPayment: (id: string) => call("POST", `/payments/${encodeURIComponent(id)}/void`),
    // No amount means no body, which Moyasar documents as a refund in full.
    refund: (id: string, amount?: number) =>
      call("POST", `/payments/${encodeURIComponent(id)}/refund`,
           amount === undefined ? undefined : { amount }),
  };
}
