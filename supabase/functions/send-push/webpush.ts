// Web Push (RFC 8291 encryption, RFC 8292 VAPID) for the member web app.
// The library does the cryptography with WebCrypto; this module only adapts
// it to send-push: one payload shape, results shaped like sendApns's, and no
// throws, so one bad subscription cannot fail the others.

import * as webpush from "jsr:@negrel/webpush@0.5.0";

export type WebSubscription = { endpoint: string; p256dh: string; auth: string };
export type WebResult = { ok: boolean; status: number; text: string; gone: boolean };

// What sw.js reads: the notification text and the event to open on tap.
export function webPushPayload(
  copy: { title: string; body: string },
  eventId: string | null,
): string {
  return JSON.stringify({ title: copy.title, body: copy.body, event_id: eventId });
}

// 404 and 410 mean the browser dropped the subscription (site data cleared,
// permission revoked, app uninstalled). Unlike an APNs BadDeviceToken, this is
// final: the row can be deleted.
export function isGone(status: number): boolean {
  return status === 404 || status === 410;
}

// vapidKeysJson is the VAPID_KEYS secret: the output of exportVapidKeys().
export async function makeWebPushServer(opts: {
  vapidKeysJson: string;
  subject: string;
}): Promise<webpush.ApplicationServer> {
  const vapidKeys = await webpush.importVapidKeys(JSON.parse(opts.vapidKeysJson), {
    extractable: false,
  });
  return await webpush.ApplicationServer.new({
    contactInformation: opts.subject,
    vapidKeys,
  });
}

export async function sendWebPush(
  server: webpush.ApplicationServer,
  sub: WebSubscription,
  payload: string,
): Promise<WebResult> {
  try {
    await server
      .subscribe({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } })
      // A day is long enough to reach a phone that was off overnight, and short
      // enough that a reminder never arrives after the workout.
      .pushTextMessage(payload, { ttl: 86400, urgency: webpush.Urgency.High });
    return { ok: true, status: 201, text: "", gone: false };
  } catch (error) {
    if (error instanceof webpush.PushMessageError) {
      const status = error.response.status;
      const text = await error.response.text().catch(() => "");
      return { ok: false, status, text, gone: isGone(status) };
    }
    return { ok: false, status: 0, text: String(error), gone: false };
  }
}
