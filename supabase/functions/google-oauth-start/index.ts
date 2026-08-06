/**
 * google-oauth-start
 *
 * Genera la URL de autorización OAuth de Google para un negocio.
 * Protegida con x-internal-secret. Retorna {url} — no redirige.
 *
 * POST body: { business_id: string }
 *
 * Variables requeridas:
 *   INTERNAL_FUNCTION_SECRET, GOOGLE_CLIENT_ID, GOOGLE_OAUTH_REDIRECT_URI,
 *   GOOGLE_OAUTH_STATE_SECRET, SUPABASE_URL,
 *   SUPABASE_SECRET_KEYS | SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase-client.ts";

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", {
      status: 405,
      headers: { Allow: "POST" },
    });
  }

  // Validar x-internal-secret
  const internalSecret = Deno.env.get("INTERNAL_FUNCTION_SECRET");
  if (!internalSecret) {
    console.error(JSON.stringify({ event: "missing_internal_secret_env" }));
    return new Response("Internal Server Error", { status: 500 });
  }
  const providedSecret = req.headers.get("x-internal-secret") ?? "";
  if (!timingSafeStringEqual(providedSecret, internalSecret)) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Vars requeridas
  const clientId = Deno.env.get("GOOGLE_CLIENT_ID");
  const redirectUri = Deno.env.get("GOOGLE_OAUTH_REDIRECT_URI");
  const stateSecret = Deno.env.get("GOOGLE_OAUTH_STATE_SECRET");
  if (!clientId || !redirectUri || !stateSecret) {
    console.error(JSON.stringify({ event: "missing_google_oauth_env" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  // Parsear body
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const businessId =
    typeof (body as Record<string, unknown>)?.business_id === "string"
      ? ((body as Record<string, unknown>).business_id as string)
      : "";

  if (!isValidUUID(businessId)) {
    return new Response(
      JSON.stringify({ error: "business_id must be a valid UUID" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  // Construir state: payloadBase64Url + "." + signatureBase64Url
  const nonce = crypto.randomUUID();
  const exp = Date.now() + 600_000; // 10 minutos
  const payload = { business_id: businessId, nonce, exp };
  const payloadBase64Url = base64url(new TextEncoder().encode(JSON.stringify(payload)));

  // Firmar exactamente payloadBase64Url con HMAC-SHA256
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(stateSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBytes = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(payloadBase64Url),
  );
  const signatureBase64Url = base64url(new Uint8Array(signatureBytes));
  const stateToken = `${payloadBase64Url}.${signatureBase64Url}`;

  // Hash del state token para lookup en BD (no almacenamos el token crudo)
  const stateHash = await sha256hex(stateToken);

  // Persistir en BD
  const expiresAt = new Date(exp).toISOString();
  let supabase;
  try {
    supabase = getServiceRoleClient();
  } catch {
    console.error(JSON.stringify({ event: "supabase_client_init_error" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  const { error: rpcError } = await supabase.rpc("store_oauth_state", {
    p_business_id: businessId,
    p_state_hash: stateHash,
    p_nonce: nonce,
    p_expires_at: expiresAt,
  });

  if (rpcError) {
    const err = rpcError as { code?: string; message?: string };
    if (err.code === "P0001") {
      return new Response(
        JSON.stringify({ error: err.message ?? "store_oauth_state_failed" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }
    console.error(JSON.stringify({ event: "store_oauth_state_db_error" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  // Construir URL de autorización
  const authUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  authUrl.searchParams.set("client_id", clientId);
  authUrl.searchParams.set("redirect_uri", redirectUri);
  authUrl.searchParams.set("response_type", "code");
  authUrl.searchParams.set(
    "scope",
    "https://www.googleapis.com/auth/calendar.events.owned",
  );
  authUrl.searchParams.set("access_type", "offline");
  authUrl.searchParams.set("prompt", "consent");
  authUrl.searchParams.set("state", stateToken);

  return new Response(
    JSON.stringify({ url: authUrl.toString() }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function isValidUUID(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

function base64url(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

async function sha256hex(input: string): Promise<string> {
  const hashBuffer = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input),
  );
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeStringEqual(a: string, b: string): boolean {
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  let diff = aBytes.length ^ bBytes.length;
  const len = Math.max(aBytes.length, bBytes.length);
  for (let i = 0; i < len; i++) {
    diff |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }
  return diff === 0;
}
