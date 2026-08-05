import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * Crea un cliente Supabase con la clave de service_role.
 *
 * Estrategia de resolución de clave (en orden):
 *   1. SUPABASE_SECRET_KEYS (JSON con propiedad "default") — inyectado por Supabase Runtime v2
 *   2. SUPABASE_SERVICE_ROLE_KEY — compatibilidad legacy / local dev
 *
 * La función nunca imprime el contenido de las variables de entorno.
 */
export function getServiceRoleClient() {
  const url = Deno.env.get("SUPABASE_URL");

  let key: string | undefined;

  const secretKeysRaw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (secretKeysRaw) {
    try {
      const parsed = JSON.parse(secretKeysRaw);
      if (typeof parsed?.default === "string" && parsed.default.length > 0) {
        key = parsed.default;
      }
    } catch {
      // JSON inválido — no imprimir contenido ni la clave
      console.error(JSON.stringify({ event: "supabase_secret_keys_parse_error" }));
    }
  }

  if (!key) {
    key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  }

  if (!url || !key) {
    throw new Error("Missing Supabase URL or service role key");
  }

  return createClient(url, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}
