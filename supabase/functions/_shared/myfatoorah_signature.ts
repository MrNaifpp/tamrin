// MyFatoorah webhook signature (Webhook V2). The `MyFatoorah-Signature` header
// is base64(HMAC-SHA256(secret, "k1=v1,k2=v2,…")) over a fixed, per-event list
// of fields. The order is MyFatoorah's, not alphabetical; nulls are "".

export type SignatureField = [string, string | number | null | undefined];

// deno-lint-ignore no-explicit-any
type Json = any;

export function paymentSignatureFields(data: Json): SignatureField[] {
  return [
    ["Invoice.Id", data?.Invoice?.Id],
    ["Invoice.Status", data?.Invoice?.Status],
    ["Transaction.Status", data?.Transaction?.Status],
    ["Transaction.PaymentId", data?.Transaction?.PaymentId],
    ["Invoice.ExternalIdentifier", data?.Invoice?.ExternalIdentifier],
  ];
}

export function refundSignatureFields(data: Json): SignatureField[] {
  return [
    ["Refund.Id", data?.Refund?.Id],
    ["Refund.Status", data?.Refund?.Status],
    ["Amount.ValueInBaseCurrency", data?.Amount?.ValueInBaseCurrency],
    ["ReferencedInvoice.Id", data?.ReferencedInvoice?.Id],
  ];
}

export function fieldsString(fields: SignatureField[]): string {
  return fields.map(([k, v]) => `${k}=${v ?? ""}`).join(",");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifySignature(
  secret: string,
  fields: SignatureField[],
  header: string | null,
): Promise<boolean> {
  if (!secret || !header) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(fieldsString(fields))),
  );
  const expected = btoa(String.fromCharCode(...mac));
  return constantTimeEqual(expected, header.trim());
}
