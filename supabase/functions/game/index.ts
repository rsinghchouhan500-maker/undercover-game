import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function projectKey(keyMapName: string, legacyName: string): string {
  const keyMapValue = Deno.env.get(keyMapName);
  if (keyMapValue) {
    const keys = JSON.parse(keyMapValue) as Record<string, unknown>;
    if (typeof keys.default === 'string' && keys.default) return keys.default;
  }
  const legacyValue = Deno.env.get(legacyName);
  if (legacyValue) return legacyValue;
  throw new Error(`Supabase did not provide ${keyMapName} or ${legacyName}.`);
}

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (request.method !== 'POST') return Response.json({ error: 'Use POST.' }, { status: 405, headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const publishableKey = projectKey('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY');
    const secretKey = projectKey('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY');
    const authorization = request.headers.get('Authorization');
    if (!authorization?.startsWith('Bearer ')) throw new Error('Sign in to your player session and try again.');
    const token = authorization.slice(7);
    const authClient = createClient(url, publishableKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: { user }, error: authError } = await authClient.auth.getUser(token);
    if (authError || !user) return Response.json({ error: 'Your player session expired. Refresh and rejoin.' }, { status: 401, headers: cors });
    const body = await request.json();
    if (!body || typeof body.action !== 'string' || !body.data || typeof body.data !== 'object') throw new Error('Invalid game action.');
    const admin = createClient(url, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data, error } = await admin.rpc('run_undercover_action', { p_user: user.id, p_action: body.action, p_data: body.data });
    if (error) throw new Error(error.message.replace(/^.*?ERROR:\s*/, ''));
    return Response.json(data, { headers: { ...cors, 'Cache-Control': 'no-store' } });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Something went wrong. Please try again.';
    return Response.json({ error: message }, { status: 400, headers: cors });
  }
});
