// type -> Arabic notification copy. This is the ONLY place push wording lives.
export function copyFor(
  type: string,
  eventName: string,
): { title: string; body: string } | null {
  switch (type) {
    case "payment_submitted":
      return { title: "طلب دفع جديد", body: `طلب دفع جديد لحدث ${eventName}` };
    default:
      return null;
  }
}
