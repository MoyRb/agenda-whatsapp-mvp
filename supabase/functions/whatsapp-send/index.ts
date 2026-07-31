import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// E.164 strict: + followed by 8–15 digits, first digit non-zero
const PHONE_E164_REGEX = /^\+[1-9]\d{7,14}$/;

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const aBytes = enc.encode(a);
  const bBytes = enc.encode(b);
  const len = Math.max(aBytes.length, bBytes.length);
  let diff = aBytes.length ^ bBytes.length; // non-zero if lengths differ
  for (let i = 0; i < len; i++) {
    diff |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }
  return diff === 0;
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

serve(async (req: Request) => {
  // 1. Validate HTTP method
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // 2. Validate required env vars before any external call
  const internalSecret = Deno.env.get("INTERNAL_FUNCTION_SECRET") ?? "";
  const accessToken = Deno.env.get("WHATSAPP_ACCESS_TOKEN") ?? "";
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
  const apiVersion = Deno.env.get("META_GRAPH_API_VERSION") ?? "";

  if (internalSecret.length < 16) {
    console.error("[whatsapp-send] INTERNAL_FUNCTION_SECRET missing or too short");
    return jsonResponse({ error: "Server misconfiguration" }, 500);
  }
  if (!accessToken || !phoneNumberId || !apiVersion) {
    console.error("[whatsapp-send] Missing required WhatsApp/Meta env vars");
    return jsonResponse({ error: "Server misconfiguration" }, 500);
  }

  // 3. Validate internal secret via dedicated header (not Authorization)
  const providedSecret = req.headers.get("x-internal-secret") ?? "";
  if (!timingSafeEqual(providedSecret, internalSecret)) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  // 4. Parse and validate JSON body
  let body: { to?: unknown };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const to = body.to;
  if (typeof to !== "string" || !PHONE_E164_REGEX.test(to)) {
    return jsonResponse(
      { error: "Field 'to' must be E.164 format: + followed by 8–15 digits, first digit non-zero" },
      400,
    );
  }

  // 5. Call Meta Graph API with 15-second timeout
  const metaUrl =
    `https://graph.facebook.com/${apiVersion}/${phoneNumberId}/messages`;

  const payload = {
    messaging_product: "whatsapp",
    to,
    type: "template",
    template: {
      name: "hello_world",
      language: { code: "en_US" },
    },
  };

  let metaRes: Response;
  try {
    metaRes = await fetch(metaUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (err) {
    const isTimeout = err instanceof DOMException && err.name === "TimeoutError";
    console.error(
      "[whatsapp-send] Meta API fetch error:",
      isTimeout ? "timeout after 15s" : (err as Error).message,
    );
    return jsonResponse(
      { error: isTimeout ? "Meta API timeout" : "Failed to reach Meta API" },
      502,
    );
  }

  // 6. Handle Meta API errors — log only status/code/type/message, never tokens
  if (!metaRes.ok) {
    let errorCode: unknown = null;
    let errorType: unknown = null;
    let errorMessage = `Meta API returned status ${metaRes.status}`;

    try {
      const metaError = await metaRes.json();
      const e = metaError?.error;
      if (e) {
        errorCode = e.code ?? null;
        errorType = e.type ?? null;
        errorMessage = typeof e.message === "string" ? e.message : errorMessage;
      }
    } catch {
      // ignore parse failure
    }

    console.error("[whatsapp-send] Meta API error:", {
      status: metaRes.status,
      code: errorCode,
      type: errorType,
      message: errorMessage,
    });

    return jsonResponse(
      { error: "Provider error", detail: errorMessage },
      502,
    );
  }

  // 7. Parse success response
  let metaData: { messages?: Array<{ id: string }> };
  try {
    metaData = await metaRes.json();
  } catch {
    console.error("[whatsapp-send] Could not parse Meta success response");
    return jsonResponse({ error: "Invalid response from Meta API" }, 502);
  }

  const messageId = metaData?.messages?.[0]?.id ?? null;

  return jsonResponse(
    { success: true, message_id: messageId, recipient: to },
    200,
  );
});
