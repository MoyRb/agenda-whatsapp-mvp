import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

serve(async (req: Request) => {
  const method = req.method;

  if (method === "GET") {
    return handleVerification(req);
  } else if (method === "POST") {
    return handleEvent(req);
  } else {
    return new Response("Method Not Allowed", {
      status: 405,
      headers: { "Allow": "GET, POST" },
    });
  }
});

// ---------------------------------------------------------------------------
// GET — Handshake de verificación
// ---------------------------------------------------------------------------
function handleVerification(req: Request): Response {
  const verifyToken = Deno.env.get("WHATSAPP_VERIFY_TOKEN");
  if (!verifyToken) {
    console.error("Missing env var: WHATSAPP_VERIFY_TOKEN");
    return new Response("Forbidden", { status: 403 });
  }

  const url = new URL(req.url);
  const mode = url.searchParams.get("hub.mode") ?? "";
  const token = url.searchParams.get("hub.verify_token") ?? "";
  const challenge = url.searchParams.get("hub.challenge") ?? "";

  if (!mode || !token || !challenge) {
    return new Response("Forbidden", { status: 403 });
  }

  if (mode !== "subscribe") {
    return new Response("Forbidden", { status: 403 });
  }

  if (!timingSafeStringEqual(token, verifyToken)) {
    return new Response("Forbidden", { status: 403 });
  }

  return new Response(challenge, { status: 200 });
}

// ---------------------------------------------------------------------------
// POST — Recepción de eventos
// ---------------------------------------------------------------------------
async function handleEvent(req: Request): Promise<Response> {
  const appSecret = Deno.env.get("META_APP_SECRET");
  if (!appSecret) {
    console.error("Missing env var: META_APP_SECRET");
    return new Response("Internal Server Error", { status: 500 });
  }

  // Paso 1 — Límite de tamaño por Content-Length header
  const contentLength = parseInt(req.headers.get("content-length") ?? "0", 10);
  if (contentLength > 1_048_576) {
    return new Response("Payload Too Large", { status: 413 });
  }

  // Paso 2 — Leer bytes originales
  const rawBuffer = await req.arrayBuffer();
  if (rawBuffer.byteLength > 1_048_576) {
    return new Response("Payload Too Large", { status: 413 });
  }

  // Paso 3 — Validar formato del header de firma
  const sigHeader = req.headers.get("x-hub-signature-256") ?? "";
  if (!/^sha256=[0-9a-f]{64}$/.test(sigHeader)) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Paso 4 — Verificar HMAC con crypto.subtle.verify()
  const hexStr = sigHeader.slice(7);
  const sigBytes = hexToUint8Array(hexStr);

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify("HMAC", key, sigBytes, rawBuffer);
  if (!valid) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Paso 5 — Parsear JSON
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(rawBuffer));
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  // Paso 6 — Validar objeto
  if (
    typeof payload !== "object" ||
    payload === null ||
    (payload as Record<string, unknown>)["object"] !== "whatsapp_business_account"
  ) {
    console.warn({ event: "unexpected_object_type" });
    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Paso 7 — Procesar eventos en lotes
  const data = payload as {
    entry?: Array<{
      id?: string;
      changes?: Array<{
        value?: {
          metadata?: { phone_number_id?: string };
          messages?: Array<{ from?: string; id?: string; type?: string }>;
          statuses?: Array<{ recipient_id?: string; id?: string; status?: string }>;
        };
      }>;
    }>;
  };

  const entries = Array.isArray(data.entry) ? data.entry : [];
  for (const entry of entries) {
    const wabaId = entry.id ?? "";
    const changes = Array.isArray(entry.changes) ? entry.changes : [];

    for (const change of changes) {
      const value = change.value;
      if (!value) continue;

      const phoneNumberId = value.metadata?.phone_number_id ?? "";

      if (Array.isArray(value.messages)) {
        for (const msg of value.messages) {
          console.log(JSON.stringify({
            type: "message",
            wabaId,
            phoneNumberId,
            messageId: msg.id ?? "",
            messageType: msg.type ?? "",
            from: maskPhone(msg.from ?? ""),
          }));
        }
      } else if (Array.isArray(value.statuses)) {
        for (const stat of value.statuses) {
          console.log(JSON.stringify({
            type: "status",
            wabaId,
            phoneNumberId,
            messageId: stat.id ?? "",
            status: stat.status ?? "",
            recipient: maskPhone(stat.recipient_id ?? ""),
          }));
        }
      } else {
        console.log(JSON.stringify({ type: "other", wabaId, phoneNumberId }));
      }
    }
  }

  // Paso 8 — Return 200
  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function maskPhone(phone: string): string {
  if (!phone || phone.length <= 4) return "****";
  return "*".repeat(phone.length - 4) + phone.slice(-4);
}

function hexToUint8Array(hex: string): Uint8Array {
  const arr = new Uint8Array(hex.length / 2);
  for (let i = 0; i < arr.length; i++) {
    arr[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return arr;
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
