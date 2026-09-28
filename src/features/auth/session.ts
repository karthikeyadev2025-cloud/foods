/**
 * Supabase raises an auth event every time it refreshes the access token, and
 * it refreshes on `visibilitychange` — so coming back to the tab after a minute
 * on WhatsApp fires TOKEN_REFRESHED for the SAME user.
 *
 * The handler used to drop the cached `me`, `permissions` and `setup` queries on
 * every such event. Dropping `me` puts useMe() back to pending, RequireAuth
 * swaps the whole <Outlet/> for a spinner, and every screen under it UNMOUNTS —
 * taking a half-typed bill with it. From the counter: "switch tabs, come back,
 * the bill is gone."
 *
 * The purge is right, but only for the reason it was written: a DIFFERENT user
 * must never see the previous one's data. So the question is not "did the
 * session change?" — it is "is this somebody else?".
 */
export function isDifferentUser(prevUid: string | null | undefined, nextUid: string | null | undefined): boolean {
  return (prevUid ?? null) !== (nextUid ?? null);
}
