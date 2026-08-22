// esm.sh's bundle of supabase-js opens with a Node `Buffer` import, which the
// browser has no answer for. The only use of it in the whole bundle is
// storage's toBase64:
//
//     typeof __Buffer$ < "u" ? __Buffer$.from(e).toString("base64") : btoa(e)
//
// so an undefined export sends it down the btoa branch — exactly what the
// browser build of supabase-js does on its own. Vendoring this shim, and
// pointing the bundle's import at it, is the one edit made to vendor/.
export const Buffer = undefined
