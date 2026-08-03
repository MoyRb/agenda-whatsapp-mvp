import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// E.164 strict: + followed by 8–15 digits, first digit non-zero
const PHONE_E164_REGEX = /^\+[1-9]\d{7,14}$/;

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const aBytes = enc.encode(a);
  const bBytes = enc.encode(b);
  const len = Math.max(aBytes.length, bBytes.length);
  let diff = aBytes.length ^ bBytes.length;
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
  // 1. Solo POST
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // 2. Validar variables de entorno obligatorias
  const internalSecret = Deno.env.get("INTERNAL_FUNCTION_SECRET") ?? "";
  const accessToken    = Deno.env.get("WHATSAPP_ACCESS_TOKEN") ?? "";
  const phoneNumberId  = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
  const apiVersion     = Deno.env.get("META_GRAPH_API_VERSION") ?? "";
  const envFlowId      = Deno.env.get("WHATSAPP_FLOW_ID") ?? "";

  if (internalSecret.length < 16) {
    console.error("[whatsapp-flow-send] INTERNAL_FUNCTION_SECRET missing or too short");
    return jsonResponse({ error: "Server misconfiguration" }, 500);
  }
  if (!accessToken || !phoneNumberId || !apiVersion) {
    console.error("[whatsapp-flow-send] Missing required WhatsApp/Meta env vars");
    return jsonResponse({ error: "Server misconfiguration" }, 500);
  }

  // 3. Autenticación por header x-internal-secret
  const providedSecret = req.headers.get("x-internal-secret") ?? "";
  if (!timingSafeEqual(providedSecret, internalSecret)) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  // 4. Parsear body JSON
  let body: { to?: unknown; flow_id?: unknown; flow_token?: unknown; mode?: unknown };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  // 5. Validar campo "to"
  const to = body.to;
  if (typeof to !== "string" || !PHONE_E164_REGEX.test(to)) {
    return jsonResponse(
      { error: "Field 'to' must be E.164 format: + followed by 8-15 digits, first digit non-zero" },
      400,
    );
  }

  // 6. Resolver flow_id: request tiene prioridad sobre variable de entorno
  const rawFlowId = typeof body.flow_id === "string" && body.flow_id.trim() !== ""
    ? body.flow_id.trim()
    : envFlowId;

  if (!rawFlowId) {
    return jsonResponse(
      { error: "flow_id is required (body field or WHATSAPP_FLOW_ID env var)" },
      400,
    );
  }

  // 7. Validar flow_token
  const flowToken = typeof body.flow_token === "string" && body.flow_token.trim() !== ""
    ? body.flow_token.trim()
    : "unused";

  // 8. Modo: "published" para produccion, "draft" para pruebas antes de publicar
  const mode = body.mode === "draft" ? "draft" : "published";

  // 9. Construir payload hacia Meta Graph API
  const metaUrl = `https://graph.facebook.com/${apiVersion}/${phoneNumberId}/messages`;

  const payload = {
    messaging_product: "whatsapp",
    to,
    type: "interactive",
    interactive: {
      type: "flow",
      header: {
        type: "text",
        text: "Reservacion de cita",
      },
      body: {
        text: "Completa el formulario para agendar tu cita.",
      },
      footer: {
        text: "Tu numero no se comparte.",
      },
      action: {
        name: "flow",
        parameters: {
          flow_message_version: "3",
          flow_token: flowToken,
          flow_id: rawFlowId,
          flow_cta: "Agendar cita",
          flow_action: "navigate",
          flow_action_payload: {
            screen: "SERVICE",
          },
          mode,
        },
      },
    },
  };

  // 10. Llamar Meta Graph API con timeout de 15 segundos
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
      "[whatsapp-flow-send] Meta API fetch error:",
      isTimeout ? "timeout after 15s" : (err as Error).message,
    );
    return jsonResponse(
      { error: isTimeout ? "Meta API timeout" : "Failed to reach Meta API" },
      502,
    );
  }

  // 11. Manejar errores de Meta — nunca loguear tokens
  if (!metaRes.ok) {
    let errorCode: unknown = null;
    let errorType: unknown = null;
    let errorMessage = `Meta API returned status ${metaRes.status}`;

    try {
      const metaError = await metaRes.json();
      const e = (metaError as { error?: { code?: unknown; type?: unknown; message?: unknown } }).error;
      if (e) {
        errorCode    = e.code ?? null;
        errorType    = e.type ?? null;
        errorMessage = typeof e.message === "string" ? e.message : errorMessage;
      }
    } catch {
      // ignorar fallo de parseo
    }

    console.error("[whatsapp-flow-send] Meta API error:", {
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

  // 12. Parsear respuesta exitosa
  let metaData: { messages?: Array<{ id: string }> };
  try {
    metaData = await metaRes.json();
  } catch {
    console.error("[whatsapp-flow-send] Could not parse Meta success response");
    return jsonResponse({ error: "Invalid response from Meta API" }, 502);
  }

  const messageId = (metaData?.messages?.[0]?.id) ?? null;

  return jsonResponse(
    { success: true, message_id: messageId, recipient: to, mode },
    200,
  );
});
