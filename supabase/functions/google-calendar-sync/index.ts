/**
 * google-calendar-sync
 *
 * Worker de sincronización Google Calendar.
 * Requiere x-internal-secret en todas las peticiones.
 *
 * POST body: { business_id: string, appointment_id: string }
 *
 * Siempre retorna HTTP 200 para errores de negocio/Calendar.
 * HTTP 500 solo si hay error de infraestructura inesperado antes del claim.
 *
 * Variables requeridas:
 *   INTERNAL_FUNCTION_SECRET, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,
 *   GOOGLE_TOKEN_ENDPOINT (default: https://oauth2.googleapis.com/token),
 *   GOOGLE_CALENDAR_API_BASE_URL (default: https://www.googleapis.com/calendar/v3),
 *   SUPABASE_URL, SUPABASE_SECRET_KEYS | SUPABASE_SERVICE_ROLE_KEY
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { getServiceRoleClient } from "../_shared/supabase-client.ts";
import {
  buildEventPayload,
  classifyCalendarResponse,
  classifyTokenError,
  deriveEventId,
  getCalendarEvent,
  insertCalendarEvent,
  refreshAccessToken,
  type TokenError,
} from "../_shared/google-calendar.ts";

serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", {
      status: 405,
      headers: { Allow: "POST" },
    });
  }

  // ---------------------------------------------------------------------------
  // Autenticación: x-internal-secret (timing-safe)
  // ---------------------------------------------------------------------------
  const internalSecret = Deno.env.get("INTERNAL_FUNCTION_SECRET");
  if (!internalSecret) {
    console.error(JSON.stringify({ event: "missing_internal_secret_env" }));
    return new Response("Internal Server Error", { status: 500 });
  }
  const providedSecret = req.headers.get("x-internal-secret") ?? "";
  if (!timingSafeStringEqual(providedSecret, internalSecret)) {
    return new Response("Unauthorized", { status: 401 });
  }

  // ---------------------------------------------------------------------------
  // Parsear body
  // ---------------------------------------------------------------------------
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const b = body as Record<string, unknown>;
  const businessId = typeof b.business_id === "string" ? b.business_id : "";
  const appointmentId = typeof b.appointment_id === "string" ? b.appointment_id : "";

  if (!isValidUUID(businessId) || !isValidUUID(appointmentId)) {
    return new Response(
      JSON.stringify({ error: "business_id and appointment_id must be valid UUIDs" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  // ---------------------------------------------------------------------------
  // Cliente Supabase (service_role)
  // ---------------------------------------------------------------------------
  let supabase;
  try {
    supabase = getServiceRoleClient();
  } catch {
    console.error(JSON.stringify({ event: "supabase_client_init_error", businessId }));
    return new Response("Internal Server Error", { status: 500 });
  }

  // ---------------------------------------------------------------------------
  // 1. Reclamar job (SELECT FOR UPDATE SKIP LOCKED)
  // ---------------------------------------------------------------------------
  const { data: claimData, error: claimError } = await supabase.rpc(
    "claim_calendar_sync_job",
    { p_business_id: businessId, p_appointment_id: appointmentId },
  );

  if (claimError) {
    console.error(JSON.stringify({ event: "claim_job_error", businessId }));
    return new Response("Internal Server Error", { status: 500 });
  }

  const claimRows = Array.isArray(claimData) ? claimData : [];
  if (claimRows.length === 0) {
    // Job ya reclamado por otro worker, no existe, o no elegible
    console.log(JSON.stringify({
      event: "job_not_claimed",
      appointmentIdSuffix: appointmentId.slice(-8),
    }));
    return new Response(JSON.stringify({ skipped: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { job_id: jobId, attempts } = claimRows[0] as {
    job_id: string;
    appointment_id: string;
    attempts: number;
  };
  const jobSuffix = jobId.slice(-8);
  const apptSuffix = appointmentId.slice(-8);

  // ---------------------------------------------------------------------------
  // 2. Obtener datos del appointment
  // ---------------------------------------------------------------------------
  const { data: syncData, error: syncDataError } = await supabase.rpc(
    "get_appointment_sync_data",
    { p_business_id: businessId, p_appointment_id: appointmentId },
  );

  if (syncDataError || !Array.isArray(syncData) || syncData.length === 0) {
    console.error(JSON.stringify({ event: "get_sync_data_error", jobSuffix, apptSuffix }));
    await failJob(supabase, jobId, businessId, "get_sync_data_error", false);
    return ok();
  }

  const appt = syncData[0] as {
    appt_status: string;
    starts_at: string;
    ends_at: string;
    calendar_event_id: string | null;
    service_name: string;
    business_timezone: string;
    extras_names: string[];
  };

  // ---------------------------------------------------------------------------
  // 3. Verificar que appointment sigue pending
  // ---------------------------------------------------------------------------
  if (appt.appt_status !== "pending") {
    console.log(JSON.stringify({
      event: "appointment_not_pending",
      jobSuffix,
      apptSuffix,
      apptStatus: appt.appt_status,
    }));
    await failJob(supabase, jobId, businessId, "appointment_not_pending", false);
    return ok();
  }

  // ---------------------------------------------------------------------------
  // 4. Verificar si ya tiene calendar_event_id (sincronizado previamente)
  // ---------------------------------------------------------------------------
  if (appt.calendar_event_id) {
    console.log(JSON.stringify({
      event: "appointment_already_synced",
      jobSuffix,
      apptSuffix,
    }));
    await supabase.rpc("complete_calendar_sync_job", {
      p_job_id: jobId,
      p_business_id: businessId,
      p_calendar_event_id: appt.calendar_event_id,
    });
    return ok();
  }

  // ---------------------------------------------------------------------------
  // 5. Obtener conexión con Google Calendar (refresh_token del Vault)
  // ---------------------------------------------------------------------------
  const { data: connData, error: connError } = await supabase.rpc(
    "get_calendar_connection_for_sync",
    { p_business_id: businessId },
  );

  if (connError) {
    const err = connError as { code?: string; message?: string };
    if (err.code === "P0001") {
      console.log(JSON.stringify({ event: "no_active_calendar_connection", jobSuffix }));
      await failJob(supabase, jobId, businessId, "no_active_calendar_connection", false);
      return ok();
    }
    console.error(JSON.stringify({ event: "get_connection_error", jobSuffix }));
    await failJob(supabase, jobId, businessId, "get_connection_error", true);
    return ok();
  }

  const connRows = Array.isArray(connData) ? connData : [];
  if (connRows.length === 0) {
    await failJob(supabase, jobId, businessId, "no_active_calendar_connection", false);
    return ok();
  }

  const conn = connRows[0] as {
    connection_id: string;
    calendar_id: string;
    google_account_email: string | null;
    refresh_token: string;
  };

  // ---------------------------------------------------------------------------
  // 6. Refrescar access token
  // ---------------------------------------------------------------------------
  const clientId = Deno.env.get("GOOGLE_CLIENT_ID") ?? "";
  const clientSecret = Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "";
  const tokenEndpoint = Deno.env.get("GOOGLE_TOKEN_ENDPOINT") ??
    "https://oauth2.googleapis.com/token";
  const apiBase = Deno.env.get("GOOGLE_CALENDAR_API_BASE_URL") ??
    "https://www.googleapis.com/calendar/v3";

  if (!clientId || !clientSecret) {
    console.error(JSON.stringify({ event: "missing_google_client_env", jobSuffix }));
    await failJob(supabase, jobId, businessId, "missing_google_client_env", false);
    return ok();
  }

  let accessToken: string;
  try {
    accessToken = await refreshAccessToken({
      refreshToken: conn.refresh_token,
      clientId,
      clientSecret,
      tokenEndpoint,
    });
  } catch (tokenErr) {
    const te = tokenErr as TokenError;
    console.log(JSON.stringify({
      event: "token_refresh_failed",
      jobSuffix,
      apptSuffix,
      errorKind: te.kind,
      errorCode: te.code,
    }));
    if (te.kind === "permanent" && te.code === "invalid_grant") {
      // Revocar conexión
      await supabase.rpc("update_calendar_connection_status", {
        p_business_id: businessId,
        p_status: "revoked",
      });
    }
    await failJob(
      supabase,
      jobId,
      businessId,
      te.code,
      te.kind === "retryable",
    );
    return ok();
  }

  // ---------------------------------------------------------------------------
  // 7. Construir payload y event ID determinístico
  // ---------------------------------------------------------------------------
  const eventId = deriveEventId(appointmentId);
  const payload = buildEventPayload({
    appointmentId,
    businessId,
    serviceName: appt.service_name,
    extrasNames: appt.extras_names ?? [],
    startsAt: appt.starts_at,
    endsAt: appt.ends_at,
    timezone: appt.business_timezone,
  });

  // ---------------------------------------------------------------------------
  // 8. Insertar evento en Google Calendar
  // ---------------------------------------------------------------------------
  const { httpStatus, data: calData } = await insertCalendarEvent({
    accessToken,
    calendarId: conn.calendar_id,
    eventId,
    payload,
    apiBase,
    timeout: 10_000,
  });

  // httpStatus=0 → timeout/network
  const effectiveStatus = httpStatus === 0 ? 0 : httpStatus;
  const result = httpStatus === 0
    ? { kind: "retryable" as const, code: "calendar_timeout" }
    : classifyCalendarResponse(httpStatus, calData);

  console.log(JSON.stringify({
    event: "calendar_insert_result",
    jobSuffix,
    apptSuffix,
    httpStatus: effectiveStatus,
    resultKind: result.kind,
  }));

  if (result.kind === "synced") {
    await supabase.rpc("complete_calendar_sync_job", {
      p_job_id: jobId,
      p_business_id: businessId,
      p_calendar_event_id: result.eventId || eventId,
    });
    return ok();
  }

  if (result.kind === "needs_reconcile") {
    // 409: GET para verificar si el evento ya existe con los mismos IDs
    const { found, data: existingEvent } = await getCalendarEvent({
      accessToken,
      calendarId: conn.calendar_id,
      eventId,
      apiBase,
    });

    if (found) {
      const ev = existingEvent as Record<string, unknown>;
      const priv = (ev.extendedProperties as Record<string, unknown> | undefined)
        ?.private as Record<string, unknown> | undefined;
      const matches =
        priv?.appointment_id === appointmentId &&
        priv?.business_id === businessId;

      if (matches) {
        await supabase.rpc("complete_calendar_sync_job", {
          p_job_id: jobId,
          p_business_id: businessId,
          p_calendar_event_id: eventId,
        });
        return ok();
      }
    }

    // 409 pero GET 404 o mismatch → retryable
    await failJob(supabase, jobId, businessId, "calendar_409_no_reconcile", true);
    return ok();
  }

  if (result.kind === "retryable") {
    await failJob(supabase, jobId, businessId, result.code, true);
    return ok();
  }

  // permanent
  await failJob(supabase, jobId, businessId, result.code, false);
  return ok();
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function ok(): Response {
  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

async function failJob(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  jobId: string,
  businessId: string,
  errorCode: string,
  isRetryable: boolean,
): Promise<void> {
  await supabase.rpc("fail_calendar_sync_job", {
    p_job_id: jobId,
    p_business_id: businessId,
    p_error_code: errorCode,
    p_is_retryable: isRetryable,
  });
}

function isValidUUID(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
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
