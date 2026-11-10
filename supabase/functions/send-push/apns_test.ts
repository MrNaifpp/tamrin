import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { PROVIDER_TOKEN_MAX_AGE_SECONDS, sharedProviderToken } from "./apns.ts";

const NOW = 1_800_000_000;

// A store holding one token, recording what the code asked of it.
function fixture(stored: { token: string; issuedAt: number } | null, claimAnswer?: string | null) {
  const calls = { minted: [] as number[], claimed: [] as [string, number][] };
  const opts = {
    nowSeconds: NOW,
    mint: (now: number) => {
      calls.minted.push(now);
      return Promise.resolve(`minted@${now}`);
    },
    read: () => Promise.resolve(stored),
    claim: (token: string, issuedAt: number) => {
      calls.claimed.push([token, issuedAt]);
      return Promise.resolve(claimAnswer === undefined ? token : claimAnswer);
    },
  };
  return { opts, calls };
}

Deno.test("reuses a stored token younger than the max age", async () => {
  const { opts, calls } = fixture({ token: "stored", issuedAt: NOW - PROVIDER_TOKEN_MAX_AGE_SECONDS + 1 });
  assertEquals(await sharedProviderToken(opts), "stored");
  assertEquals(calls.minted, []);
  assertEquals(calls.claimed, []);
});

Deno.test("max age sits inside Apple's 20 to 60 minute window", () => {
  assertEquals(PROVIDER_TOKEN_MAX_AGE_SECONDS > 20 * 60, true);
  assertEquals(PROVIDER_TOKEN_MAX_AGE_SECONDS < 60 * 60, true);
});

Deno.test("makes and claims a new token once the stored one reaches the max age", async () => {
  const { opts, calls } = fixture({ token: "stored", issuedAt: NOW - PROVIDER_TOKEN_MAX_AGE_SECONDS });
  assertEquals(await sharedProviderToken(opts), `minted@${NOW}`);
  assertEquals(calls.minted, [NOW]);
  assertEquals(calls.claimed, [[`minted@${NOW}`, NOW]]);
});

Deno.test("makes and claims a new token when none is stored", async () => {
  const { opts, calls } = fixture(null);
  assertEquals(await sharedProviderToken(opts), `minted@${NOW}`);
  assertEquals(calls.claimed, [[`minted@${NOW}`, NOW]]);
});

Deno.test("uses the token another call claimed first", async () => {
  const { opts } = fixture(null, "theirs");
  assertEquals(await sharedProviderToken(opts), "theirs");
});

Deno.test("falls back to its own token when the store cannot be used", async () => {
  const { opts } = fixture(null, null);
  assertEquals(await sharedProviderToken(opts), `minted@${NOW}`);
});
