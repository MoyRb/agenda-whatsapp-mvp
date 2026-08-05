import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase-client.ts";

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
          messages?: Array<{
            from?: string;
            id?: string;
            type?: string;
            interactive?: {
              type?: string;
              nfm_reply?: {
                response_json?: string;
                name?: string;
              };
            };
          }>;
          statuses?: Array<{ recipient_id?: string; id?: string; status?: string }>;
        };
      }>;
    }>;
  };

  const entries = Array.isArray(data.entry) ? data.entry : [];
  let hasInfrastructureError = false;

  for (const entry of entries) {
    const wabaId = entry.id ?? "";
    const changes = Array.isArray(entry.changes) ? entry.changes : [];

    for (const change of changes) {
      const value = change.value;
      if (!value) continue;

      const phoneNumberId = value.metadata?.phone_number_id ?? "";

      if (Array.isArray(value.messages)) {
        for (const msg of value.messages) {
          if (msg.type === "interactive" && msg.interactive?.type === "nfm_reply") {
            const infraErr = await processFlowResponse(msg, wabaId, phoneNumberId);
            if (infraErr) hasInfrastructureError = true;
          } else if (msg.type === "interactive") {
            logInteractiveMessage(msg, wabaId, phoneNumberId);
          } else {
            console.log(JSON.stringify({
              type: "message",
              wabaId,
              phoneNumberId,
              messageId: msg.id ?? "",
              messageType: msg.type ?? "",
              from: maskPhone(msg.from ?? ""),
            }));
          }
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

  // Paso 8 — Return 500 solo si hay error de infraestructura (timeout / conexión BD)
  if (hasInfrastructureError) {
    return new Response("Service Unavailable", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// processFlowResponse — Persiste un nfm_reply como cita en Supabase
//
// Retorna true si ocurrió un error de infraestructura (timeout / BD caída).
// Retorna false en todos los demás casos (éxito, error de negocio, datos inválidos).
// ---------------------------------------------------------------------------
async function processFlowResponse(
  msg: {
    from?: string;
    id?: string;
    interactive?: {
      type?: string;
      nfm_reply?: { response_json?: string; name?: string };
    };
  },
  wabaId: string,
  phoneNumberId: string,
): Promise<boolean> {
  const messageId = msg.id ?? "";

  // 1. Validar msg.id no vacío
  if (!messageId) {
    console.warn(JSON.stringify({ event: "missing_message_id", wabaId, phoneNumberId }));
    return false;
  }

  // 2. Normalizar teléfono del cliente
  const normalizedPhone = normalizeToE164(msg.from ?? "");
  if (!normalizedPhone) {
    console.warn(JSON.stringify({
      event: "invalid_customer_phone",
      wabaId,
      phoneNumberId,
      messageId,
    }));
    return false;
  }

  // 3. Parsear response_json de forma segura
  const rawJson = msg.interactive?.nfm_reply?.response_json ?? "";
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawJson);
  } catch {
    console.warn(JSON.stringify({
      event: "flow_response_parse_error",
      wabaId,
      phoneNumberId,
      messageId,
    }));
    return false;
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    console.warn(JSON.stringify({
      event: "flow_response_invalid",
      wabaId,
      phoneNumberId,
      messageId,
    }));
    return false;
  }

  // Extraer solo claves conocidas; ignorar claves desconocidas
  const r = parsed as Record<string, unknown>;
  const serviceCode     = typeof r["service_id"]       === "string" ? r["service_id"]       : "";
  const extraCodes      = Array.isArray(r["extra_ids"])
    ? (r["extra_ids"] as unknown[]).filter((x): x is string => typeof x === "string")
    : [];
  const appointmentDate = typeof r["appointment_date"] === "string" ? r["appointment_date"] : "";
  const appointmentTime = typeof r["appointment_time"] === "string" ? r["appointment_time"] : "";
  const flowVersion     = typeof r["flow_version"]     === "string" ? r["flow_version"]     : "";

  // 4. Validar flow_version — error de cliente, no de infraestructura
  if (flowVersion !== "appointment-booking-static-v1") {
    console.warn(JSON.stringify({
      event: "invalid_flow_version",
      wabaId,
      phoneNumberId,
      messageId,
    }));
    return false;
  }

  // 5. Validar formato de fecha (YYYY-MM-DD) para evitar errores de tipo en la RPC
  if (!/^\d{4}-\d{2}-\d{2}$/.test(appointmentDate)) {
    console.warn(JSON.stringify({
      event: "invalid_appointment_date_format",
      wabaId,
      phoneNumberId,
      messageId,
    }));
    return false;
  }

  // 6. Llamar RPC con timeout de 8s
  let supabase;
  try {
    supabase = getServiceRoleClient();
  } catch {
    console.error(JSON.stringify({ event: "supabase_client_init_error", wabaId, phoneNumberId, messageId }));
    return true; // error de infraestructura
  }

  const rpcCall = supabase.rpc("create_whatsapp_flow_appointment", {
    p_phone_number_id:       phoneNumberId,
    p_customer_phone_e164:   normalizedPhone,
    p_customer_display_name: null,
    p_service_code:          serviceCode,
    p_extra_codes:           extraCodes.length > 0 ? extraCodes : null,
    p_appointment_date:      appointmentDate,
    p_appointment_time:      appointmentTime,
    p_flow_version:          flowVersion,
    p_external_reference:    messageId,
  });

  const timeoutPromise = new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error("booking_timeout")), 8_000)
  );

  try {
    const result = await Promise.race([rpcCall, timeoutPromise]);

    if (result.error) {
      const err = result.error as { code?: string; message?: string };
      if (err.code === "P0001") {
        // Error de negocio — loguear solo el token, sin datos del usuario
        console.warn(JSON.stringify({
          event: "booking_rejected",
          wabaId,
          phoneNumberId,
          messageId,
          reason: err.message ?? "unknown",
        }));
        return false; // no es error de infraestructura
      }
      // Otro error de BD (ej. constraint violation inesperado) → infra error
      console.error(JSON.stringify({
        event: "booking_db_error",
        wabaId,
        phoneNumberId,
        messageId,
        errorCode: err.code ?? "unknown",
      }));
      return true;
    }

    // Éxito — loguear solo el sufijo del appointment_id (últimos 8 chars)
    const rows = Array.isArray(result.data) ? result.data : [];
    if (rows.length > 0) {
      const row = rows[0] as {
        appointment_id: string;
        created_new: boolean;
        status: string;
      };
      const apptSuffix = (row.appointment_id ?? "").slice(-8);
      console.log(JSON.stringify({
        event: "booking_created",
        wabaId,
        phoneNumberId,
        messageId,
        appointmentIdSuffix: apptSuffix,
        createdNew: row.created_new,
        status: row.status,
      }));
    }
    return false;

  } catch (e) {
    const isTimeout = e instanceof Error && e.message === "booking_timeout";
    console.error(JSON.stringify({
      event: isTimeout ? "booking_timeout" : "booking_unexpected_error",
      wabaId,
      phoneNumberId,
      messageId,
    }));
    return true; // error de infraestructura
  }
}

// ---------------------------------------------------------------------------
// logInteractiveMessage — Log sanitizado para mensajes interactivos no-nfm_reply
// ---------------------------------------------------------------------------
function logInteractiveMessage(
  msg: {
    from?: string;
    id?: string;
    interactive?: {
      type?: string;
      nfm_reply?: { response_json?: string; name?: string };
    };
  },
  wabaId: string,
  phoneNumberId: string,
): void {
  const interactiveType = msg.interactive?.type ?? "";

  console.log(JSON.stringify({
    type: "interactive_other",
    wabaId,
    phoneNumberId,
    messageId: msg.id ?? "",
    interactiveType,
    from: maskPhone(msg.from ?? ""),
  }));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Normaliza un número de teléfono a formato E.164.
 * Meta puede enviar el número sin el prefijo '+'.
 * Retorna null si el formato es inválido.
 */
function normalizeToE164(raw: string): string | null {
  if (!/^\+?\d+$/.test(raw)) return null;
  const normalized = raw.startsWith("+") ? raw : "+" + raw;
  if (!/^\+[1-9]\d{7,14}$/.test(normalized)) return null;
  return normalized;
}

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
