# Undercover

A real-time browser social-deduction game for 4–10 players. The browser never reads roles or secret words from the database. It calls the `game` Supabase Edge Function for every action; that function verifies the anonymous player session and invokes one locked Postgres action. Player secrets and ballots have row-level security enabled with no client read policies.

## Create the required accounts and backend

You need a Supabase account/project and a Vercel account. A GitHub account is also needed if you want Vercel's Git-based deployment. No player login is required.

1. Create a project in the [Supabase dashboard](https://supabase.com/dashboard). Save the database password somewhere private.
2. In **Authentication → Sign In / Providers**, enable **Anonymous Sign-ins**.
3. In **SQL Editor**, run the full migration file `supabase/migrations/202610290001_undercover.sql`.
4. Deploy `supabase/functions/game/index.ts` as an Edge Function named `game`. With the Supabase CLI, run `supabase login`, `supabase link --project-ref YOUR_PROJECT_REF`, then `supabase functions deploy game`. Supabase injects the project URL and legacy anon/service-role variables into hosted functions by default. Check **Edge Functions → Secrets** to confirm; the service-role key must remain server-side and must never go in Vercel or a browser.
5. In **Project Settings → API Keys**, copy the Project URL and publishable key (or legacy anon key). These are the two browser settings in `.env.example`; the publishable key is intended for browser use with the RLS policies in this project.

### Run locally

Requirements: Node.js 20.19+ or 22.12+ and npm.

1. Copy `.env.example` to `.env.local` and fill in `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`.
2. Run `npm install`, then `npm run dev` and open the local URL.

The frontend uses Vite and `@supabase/supabase-js`; game logic is in Postgres so votes and clue turns are serialized. Supabase Realtime sends room changes, and each tab refreshes its own private assignment through the Edge Function.

## Deploy publicly with Vercel

1. Create a [Vercel account](https://vercel.com/signup), then push this project folder to a GitHub repository.
2. Import the repository into Vercel. It detects Vite; use build command `npm run build` and output directory `dist`.
3. In **Project Settings → Environment Variables**, add `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` for Production (and Preview if desired), then redeploy so the build includes them.
4. Deploy. Vercel supplies a public `*.vercel.app` URL; a custom domain is optional.
5. Open the public URL in at least four separate browser profiles/devices to test room creation, joining, secret isolation, clues, both voting rounds, scoring, host handoff, disconnect, and rematch.

For local Supabase development instead of a hosted project, install the Supabase CLI, run `supabase start`, then `supabase db reset` and `supabase functions serve game`. Supabase CLI/Docker setup is optional.

## Game behavior

- Five-character room codes; four connected players are required to start, and rooms cap at ten.
- One undercover player receives no word. Everyone else receives the same word from the built-in word set.
- Clues are one word, one player at a time. The host opens discussion voting.
- The first tie starts a revote between tied players. A second tie ends the round without a winner or points.
- Finding the undercover gives every group player one point. If the undercover survives until only two players remain, the undercover gets one point.
- Connected players send a presence heartbeat every 15 seconds. The host transfers after the previous host is absent for 70 seconds; a player who leaves explicitly is removed from the current round.
- Scores and room membership persist for rematches. Rooms are not automatically deleted in this first version.

## Cost notes

The expected challenge setup can fit the Supabase Free tier and Vercel Hobby tier, each currently listed at $0/month. Supabase Free projects pause after one week of inactivity, so a dormant challenge deployment may need waking before a game. If you need an always-on backend, Supabase Pro currently starts at $25/month; Vercel Pro starts at $20/month. A custom domain is extra. Check provider pricing and terms before launch because plans can change.

## Security and limits

Only `uc_rooms` public room state and `uc_players` roster/score rows are readable to authenticated room members. `uc_secrets` and `uc_votes` deliberately have no client policies. Writes are performed by the server function and `run_undercover_action`; the service-role key is not sent to browsers. A real deployment should use a private Supabase project and review its Auth abuse protections and provider spend alerts before sharing widely.

This first version has no chat, timers, login, automatic room expiry, or identity recovery across a cleared browser session. A player who refreshes in the same tab is reconnected to their room. Abrupt disconnects become offline after 70 seconds; the remaining active players can continue clue turns and voting.
