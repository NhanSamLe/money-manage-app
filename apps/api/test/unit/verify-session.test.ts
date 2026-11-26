import { SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import type { Config } from "../../src/bootstrap/config";
import { SessionVerifier } from "../../src/modules/auth/verify-session";

const base: Config = {
  supabaseUrl: "https://x.supabase.co",
  publishableKey: "pk",
  serviceRoleKey: "sk",
  bootstrapSecret: "b".repeat(32),
  ownerEmail: "o@example.test",
  dbTimeoutMs: 1000,
};
const SECRET = "legacy-shared-secret-at-least-32-chars!!";
const sign = (claims: Record<string, unknown>, opts: { iss?: string; aud?: string; exp?: string } = {}) =>
  new SignJWT(claims)
    .setProtectedHeader({ alg: "HS256" })
    .setSubject("user-1")
    .setIssuer(opts.iss ?? "https://x.supabase.co/auth/v1")
    .setAudience(opts.aud ?? "authenticated")
    .setExpirationTime(opts.exp ?? "1h")
    .sign(new TextEncoder().encode(SECRET));

describe("session verifier (HS256 fallback)", () => {
  it("accepts a valid legacy token only when the secret is configured", async () => {
    const t = await sign({ session_id: "s1" });
    await expect(new SessionVerifier({ ...base, jwtSecret: SECRET }).verify(`Bearer ${t}`)).resolves.toEqual({ userId: "user-1", sessionId: "s1" });
    await expect(new SessionVerifier(base).verify(`Bearer ${t}`)).rejects.toMatchObject({ code: "UNAUTHENTICATED" });
  });

  it("rejects wrong audience, issuer, expiry, missing session and malformed headers", async () => {
    const v = new SessionVerifier({ ...base, jwtSecret: SECRET });
    for (const t of [
      await sign({ session_id: "s" }, { aud: "anon" }),
      await sign({ session_id: "s" }, { iss: "https://evil.example/auth/v1" }),
      await sign({ session_id: "s" }, { exp: "-1h" }),
      await sign({}),
    ]) {
      await expect(v.verify(`Bearer ${t}`)).rejects.toMatchObject({ code: "UNAUTHENTICATED" });
    }
    await expect(v.verify(undefined)).rejects.toMatchObject({ code: "UNAUTHENTICATED" });
    await expect(v.verify("Bearer not-a-jwt")).rejects.toMatchObject({ code: "UNAUTHENTICATED" });
  });
});
