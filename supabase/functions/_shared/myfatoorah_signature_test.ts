import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  fieldsString,
  paymentSignatureFields,
  refundSignatureFields,
  verifySignature,
} from "./myfatoorah_signature.ts";

async function sign(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return btoa(String.fromCharCode(...mac));
}

const paymentData = {
  Invoice: { Id: "6409988", Status: "PAID", ExternalIdentifier: "asdqwd-f13sdf-fasjkz" },
  Transaction: { Status: "SUCCESS", PaymentId: "07076409988323998875" },
};

Deno.test("payment fields order", () => {
  assertEquals(
    fieldsString(paymentSignatureFields(paymentData)),
    "Invoice.Id=6409988,Invoice.Status=PAID,Transaction.Status=SUCCESS,Transaction.PaymentId=07076409988323998875,Invoice.ExternalIdentifier=asdqwd-f13sdf-fasjkz",
  );
});

Deno.test("refund fields order", () => {
  assertEquals(
    fieldsString(refundSignatureFields({
      Refund: { Id: "111147", Status: "REFUNDED" },
      Amount: { ValueInBaseCurrency: 30 },
      ReferencedInvoice: { Id: "5620277" },
    })),
    "Refund.Id=111147,Refund.Status=REFUNDED,Amount.ValueInBaseCurrency=30,ReferencedInvoice.Id=5620277",
  );
});

Deno.test("null becomes empty", () => {
  const s = fieldsString(paymentSignatureFields({
    ...paymentData,
    Invoice: { ...paymentData.Invoice, ExternalIdentifier: null },
  }));
  assertEquals(s.endsWith(",Invoice.ExternalIdentifier="), true);
});

Deno.test("valid signature passes, tampered field fails, missing header fails", async () => {
  const fields = paymentSignatureFields(paymentData);
  const header = await sign("s3cret", fieldsString(fields));
  assertEquals(await verifySignature("s3cret", fields, header), true);

  const tampered = paymentSignatureFields({
    ...paymentData,
    Invoice: { ...paymentData.Invoice, Status: "FAILED" },
  });
  assertEquals(await verifySignature("s3cret", tampered, header), false);
  assertEquals(await verifySignature("other", fields, header), false);
  assertEquals(await verifySignature("s3cret", fields, null), false);
  assertEquals(await verifySignature("", fields, header), false);
});
