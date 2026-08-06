/**
 * Módulo compartido: Google Calendar API helpers
 *
 * Exports:
 *   - deriveEventId
 *   - refreshAccessToken
 *   - insertCalendarEvent
 *   - getCalendarEvent
 *   - buildEventPayload
 *   - classifyTokenError
 *   - classifyCalendarResponse
 *   - TokenError, CalendarResult, GoogleEventPayload
 *
 * SEGURIDAD: nunca loguear access_token, refresh_token ni teléfonos.
 */

// ---------------------------------------------------------------------------
// Tipos
// ---------------------------------------------------------------------------

export type TokenError =
  | { kind: "permanent"; code: string }
  | { kind: "retryable"; code: string };

export type CalendarResult =
  | { kind: "synced"; eventId: string }
  | { kind: "retryable"; code: string }
  | { kind: "permanent"; code: string }
  | { kind: "needs_reconcile" };

export interface GoogleEventPayload {
  id: string;
  summary: string;
  description: string;
  start: { dateTime: string; timeZone: string };
  end: { dateTime: string; timeZone: string };
  extendedProperties: {
    private: { appointment_id: string; business_id: string };
  };
}

// ---------------------------------------------------------------------------
// deriveEventId
// UUID hex sin guiones → 32 chars [0-9a-f] ⊆ [a-v0-9] (válido para Google)
// ---------------------------------------------------------------------------

export function deriveEventId(appointmentId: string): string {
  return appointmentId.replaceAll("-", "");
}

// ---------------------------------------------------------------------------
// buildEventPayload
// SIN teléfono, SIN conferenceData, SIN attendees.
// ---------------------------------------------------------------------------

export function buildEventPayload(opts: {
  appointmentId: string;
  businessId: string;
  serviceName: string;
  extrasNames: string[];
  startsAt: string;
  endsAt: string;
  timezone: string;
}): GoogleEventPayload {
  const extrasLabel = opts.extrasNames.length > 0
    ? opts.extrasNames.join(", ")
    : "Ninguno";

  const description = [
    `ID: ${opts.appointmentId}`,
    `Servicio: ${opts.serviceName}`,
    `Extras: ${extrasLabel}`,
    `Origen: WhatsApp Flow`,
  ].join("\n");

  return {
    id: deriveEventId(opts.appointmentId),
    summary: `Cita - ${opts.serviceName}`,
    description,
    start: { dateTime: opts.startsAt, timeZone: opts.timezone },
    end: { dateTime: opts.endsAt, timeZone: opts.timezone },
    extendedProperties: {
      private: {
        appointment_id: opts.appointmentId,
        business_id: opts.businessId,
      },
    },
  };
}

// ---------------------------------------------------------------------------
// classifyTokenError
// ---------------------------------------------------------------------------

export function classifyTokenError(httpStatus: number, body: unknown): TokenError {
  if (httpStatus === 400) {
    const error = (body as Record<string, unknown>)?.error;
    if (error === "invalid_grant") {
      return { kind: "permanent", code: "invalid_grant" };
    }
    return { kind: "retryable", code: "token_400_other" };
  }
  return { kind: "retryable", code: `token_${httpStatus}` };
}

// ---------------------------------------------------------------------------
// classifyCalendarResponse
// ---------------------------------------------------------------------------

export function classifyCalendarResponse(
  httpStatus: number,
  body: unknown,
): CalendarResult {
  if (httpStatus === 200 || httpStatus === 201) {
    const eventId = (body as Record<string, unknown>)?.id;
    return { kind: "synced", eventId: typeof eventId === "string" ? eventId : "" };
  }
  if (httpStatus === 409) {
    return { kind: "needs_reconcile" };
  }
  if (httpStatus === 403) {
    // Distinguir rate limit de permisos reales
    const errBody = body as Record<string, unknown> | null;
    const errObj = errBody?.error as Record<string, unknown> | undefined;
    const errors = Array.isArray(errObj?.errors)
      ? (errObj!.errors as Array<Record<string, unknown>>)
      : [];
    const reason = errors[0]?.reason as string | undefined;
    const rateLimitReasons = [
      "rateLimitExceeded",
      "userRateLimitExceeded",
      "quotaExceeded",
    ];
    if (reason && rateLimitReasons.includes(reason)) {
      return { kind: "retryable", code: "rate_limit" };
    }
    return { kind: "permanent", code: "forbidden" };
  }
  if (httpStatus === 404) {
    return { kind: "permanent", code: "calendar_not_found" };
  }
  if (httpStatus === 400) {
    return { kind: "permanent", code: "bad_request" };
  }
  if ([429, 500, 502, 503, 504].includes(httpStatus)) {
    return { kind: "retryable", code: `calendar_${httpStatus}` };
  }
  return { kind: "retryable", code: `calendar_${httpStatus}` };
}

// ---------------------------------------------------------------------------
// refreshAccessToken
// Lanza TokenError (no retorna string si falla).
// NUNCA loguear refreshToken, clientSecret ni el access_token resultante.
// ---------------------------------------------------------------------------

export async function refreshAccessToken(opts: {
  refreshToken: string;
  clientId: string;
  clientSecret: string;
  tokenEndpoint: string;
}): Promise<string> {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: opts.refreshToken,
    client_id: opts.clientId,
    client_secret: opts.clientSecret,
  });

  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), 10_000);

  let response: Response;
  try {
    response = await fetch(opts.tokenEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
      signal: controller.signal,
    });
  } catch {
    clearTimeout(timerId);
    throw { kind: "retryable", code: "token_endpoint_timeout" } as TokenError;
  }
  clearTimeout(timerId);

  let data: unknown;
  try {
    data = await response.json();
  } catch {
    data = {};
  }

  if (!response.ok) {
    throw classifyTokenError(response.status, data);
  }

  const accessToken = (data as Record<string, unknown>).access_token;
  if (typeof accessToken !== "string" || !accessToken) {
    throw { kind: "retryable", code: "token_no_access_token" } as TokenError;
  }

  return accessToken;
}

// ---------------------------------------------------------------------------
// insertCalendarEvent
// POST /calendars/{calendarId}/events?sendUpdates=none
// El event_id determinístico viene en el payload (campo id).
// ---------------------------------------------------------------------------

export async function insertCalendarEvent(opts: {
  accessToken: string;
  calendarId: string;
  eventId: string;
  payload: GoogleEventPayload;
  apiBase: string;
  timeout?: number;
}): Promise<{ httpStatus: number; data: unknown }> {
  const timeoutMs = opts.timeout ?? 10_000;
  const url = `${opts.apiBase}/calendars/${encodeURIComponent(opts.calendarId)}/events?sendUpdates=none`;

  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${opts.accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(opts.payload),
      signal: controller.signal,
    });
  } catch {
    clearTimeout(timerId);
    return { httpStatus: 0, data: { error: "network_timeout" } };
  }
  clearTimeout(timerId);

  let data: unknown;
  try {
    data = await response.json();
  } catch {
    data = {};
  }

  return { httpStatus: response.status, data };
}

// ---------------------------------------------------------------------------
// getCalendarEvent
// GET /calendars/{calendarId}/events/{eventId}
// Usado para reconciliar después de un 409.
// ---------------------------------------------------------------------------

export async function getCalendarEvent(opts: {
  accessToken: string;
  calendarId: string;
  eventId: string;
  apiBase: string;
}): Promise<{ found: boolean; data: unknown }> {
  const url = `${opts.apiBase}/calendars/${encodeURIComponent(opts.calendarId)}/events/${opts.eventId}`;

  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), 10_000);

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { "Authorization": `Bearer ${opts.accessToken}` },
      signal: controller.signal,
    });
  } catch {
    clearTimeout(timerId);
    return { found: false, data: { error: "network_timeout" } };
  }
  clearTimeout(timerId);

  if (response.status === 404) {
    return { found: false, data: {} };
  }

  let data: unknown;
  try {
    data = await response.json();
  } catch {
    data = {};
  }

  return { found: response.ok, data };
}
