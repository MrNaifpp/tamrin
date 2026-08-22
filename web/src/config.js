// Which Supabase project the web client talks to.
//
// Mirrors Sirr/core/supabase/SupabaseEnvironment.swift, which currently pins
// every build — production included — to the development sandbox while the
// waitlist migration is still catching up. The web app must sit on the same
// database as the app it mirrors, so it is pinned here too and moves when the
// iOS constant moves.
//
// The anon key is public by design: it ships in the iOS binary already, and
// RLS plus the SECURITY DEFINER RPCs are what actually protect the data.
export const SUPABASE_HOST = 'kpcdinxusxycenfnitjc.supabase.co'
export const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwY2Rpbnh1c3h5Y2VuZm5pdGpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk3ODc0MTUsImV4cCI6MjA4NTM2MzQxNX0.yKbHhYVZbvgU8QdCyYNrvG8rC7KtX5cqXPGpedHMJ_g'

export const SUPABASE_URL = `https://${SUPABASE_HOST}`

/// Where the iOS build lives, for the «حمّل التطبيق» affordances that stand in
/// for the organizer tools the web version deliberately does not carry.
export const APP_STORE_URL = 'https://apps.apple.com/sa/app/id6753312610'
