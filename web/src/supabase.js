import { createClient } from '../vendor/supabase.js'
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js'

/// One client for the whole page. The session lives in localStorage and is
/// refreshed in the background, so a returning visitor lands on Home rather
/// than the code screen.
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    // Nothing in this app arrives through a link with tokens in it — sign-in
    // is a six-digit code — and leaving detection on makes the client try to
    // parse every invite URL it is opened with.
    detectSessionInUrl: false
  }
})
