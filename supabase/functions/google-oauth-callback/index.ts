/**
 * google-oauth-callback
 *
 * Callback público de Google OAuth 2.0.
 * Valida el state (HMAC), consume el token de la BD (single-use),
 * intercambia el code por tokens y guarda el refresh_token en Vault.
 *
 * GET ?code=&state= | GET ?error=&state=
 *
 * Variables requeridas:
 *   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_OAUTH_REDIRECT_URI,
 *   GOOGLE_OAUTH_STATE_SECRET, GOOGLE_TOKEN_ENDPOINT (opcional, default Google)
 *   SUPABASE_URL, SUPABASE_SECRET_KEYS | SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase-client.ts";

serve(async (req: Request) => {
  if (req.method !== "GET") {
    return new Response("Method Not Allowed", {
      status: 405,
      headers: { Allow: "GET" },
    });
  }

  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const error = url.searchParams.get("error");
  const stateToken = url.searchParams.get("state") ?? "";

  // Usuario denegó acceso
  if (error === "access_denied") {
    return new Response(
      JSON.stringify({ error: "access_denied" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  if (!code || !stateToken) {
    return new Response(
      JSON.stringify({ error: "missing_code_or_state" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const stateSecret = Deno.env.get("GOOGLE_OAUTH_STATE_SECRET");
  const clientId = Deno.env.get("GOOGLE_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET");
  const redirectUri = Deno.env.get("GOOGLE_OAUTH_REDIRECT_URI");
  const tokenEndpoint = Deno.env.get("GOOGLE_TOKEN_ENDPOINT") ??
    "https://oauth2.googleapis.com/token";

  if (!stateSecret || !clientId || !clientSecret || !redirectUri) {
    console.error(JSON.stringify({ event: "missing_google_oauth_env" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  // ---------------------------------------------------------------------------
  // Verificar HMAC del state token
  // state_token = payloadBase64Url + "." + signatureBase64Url
  // Separar en el ÚLTIMO punto
  // ---------------------------------------------------------------------------
  const lastDot = stateToken.lastIndexOf(".");
  if (lastDot === -1) {
    return new Response("Unauthorized", { status: 401 });
  }
  const payloadBase64Url = stateToken.slice(0, lastDot);
  const signatureBase64Url = stateToken.slice(lastDot + 1);

  const hmacKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(stateSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );

  let signatureBytes: Uint8Array;
  try {
    signatureBytes = base64urlDecode(signatureBase64Url);
  } catch {
    return new Response("Unauthorized", { status: 401 });
  }

  const valid = await crypto.subtle.verify(
    "HMAC",
    hmacKey,
    signatureBytes,
    new TextEncoder().encode(payloadBase64Url),
  );
  if (!valid) {
    return new Response("Unauthorized", { status: 401 });
  }

  // ---------------------------------------------------------------------------
  // Consumir state de la BD (valida single-use + expiración)
  // ---------------------------------------------------------------------------
  const stateHash = await sha256hex(stateToken);

  let supabase;
  try {
    supabase = getServiceRoleClient();
  } catch {
    console.error(JSON.stringify({ event: "supabase_client_init_error" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  const { data: revokeData, error: revokeError } = await supabase.rpc(
    "revoke_oauth_state",
    { p_state_hash: stateHash },
  );
  if (revokeError) {
    const err = revokeError as { code?: string; message?: string };
    if (err.code === "P0001") {
      return new Response(
        JSON.stringify({ error: err.message ?? "oauth_state_invalid" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }
    console.error(JSON.stringify({ event: "revoke_oauth_state_db_error" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  const rows = Array.isArray(revokeData) ? revokeData : [];
  if (rows.length === 0) {
    return new Response(
      JSON.stringify({ error: "oauth_state_not_found" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }
  const { business_id: businessId } = rows[0] as { business_id: string };

  // ---------------------------------------------------------------------------
  // Intercambio de code por tokens
  // ---------------------------------------------------------------------------
  const tokenBody = new URLSearchParams({
    code,
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });

  let tokenResponse: Response;
  try {
    tokenResponse = await fetch(tokenEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: tokenBody.toString(),
    });
  } catch {
    console.error(JSON.stringify({ event: "token_exchange_network_error" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  let tokenData: unknown;
  try {
    tokenData = await tokenResponse.json();
  } catch {
    tokenData = {};
  }

  if (!tokenResponse.ok) {
    console.error(JSON.stringify({ event: "token_exchange_failed", httpStatus: tokenResponse.status }));
    return new Response("Internal Server Error", { status: 500 });
  }

  const td = tokenData as Record<string, unknown>;
  const refreshToken = td.refresh_token;
  const email = td.email ?? null;

  if (typeof refreshToken !== "string" || !refreshToken) {
    return new Response(
      JSON.stringify({ error: "no_refresh_token_in_response" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---------------------------------------------------------------------------
  // Guardar conexión (Vault)
  // ---------------------------------------------------------------------------
  const { error: storeError } = await supabase.rpc(
    "store_google_calendar_connection",
    {
      p_business_id: businessId,
      p_calendar_id: "primary",
      p_google_account_email: typeof email === "string" ? email : null,
      p_refresh_token: refreshToken,
      p_scopes: "https://www.googleapis.com/auth/calendar.events.owned",
    },
  );

  if (storeError) {
    console.error(JSON.stringify({ event: "store_connection_error" }));
    return new Response("Internal Server Error", { status: 500 });
  }

  // NUNCA incluir tokens en la respuesta
  return new Response(
    JSON.stringify({ success: true, business_id: businessId, calendar_id: "primary" }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function base64urlDecode(input: string): Uint8Array {
  const base64 = input.replaceAll("-", "+").replaceAll("_", "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
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
