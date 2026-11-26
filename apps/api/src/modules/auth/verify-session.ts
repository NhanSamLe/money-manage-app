import { createRemoteJWKSet, decodeProtectedHeader, jwtVerify } from "jose";
import type { Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";

export interface Session {
  userId: string;
  sessionId: string;
}

// Verifies the Supabase access token: signature via JWKS (asymmetric keys), issuer, audience, expiry.
// Legacy projects that sign with a shared HS256 secret are supported only when SUPABASE_JWT_SECRET is configured.
// Owner binding is checked by the caller against the DB singleton owner.
export class SessionVerifier {
  private readonly jwks;
  private readonly issuer: string;
  private readonly hmacKey: Uint8Array | undefined;

  constructor(cfg: Config) {
    this.issuer = `${cfg.supabaseUrl}/auth/v1`;
    this.jwks = createRemoteJWKSet(new URL(`${this.issuer}/.well-known/jwks.json`));
    this.hmacKey = cfg.jwtSecret ? new TextEncoder().encode(cfg.jwtSecret) : undefined;
  }

  async verify(authorization: string | undefined): Promise<Session> {
    const token = authorization?.startsWith("Bearer ") ? authorization.slice(7) : undefined;
    if (!token) throw new DomainError("UNAUTHENTICATED");
    try {
      const opts = { issuer: this.issuer, audience: "authenticated" };
      const alg = decodeProtectedHeader(token).alg;
      let payload;
      if (alg === "HS256") {
        if (!this.hmacKey) throw new Error("hs256 not configured");
        ({ payload } = await jwtVerify(token, this.hmacKey, { ...opts, algorithms: ["HS256"] }));
      } else {
        ({ payload } = await jwtVerify(token, this.jwks, opts));
      }
      const sid = payload["session_id"];
      if (typeof payload.sub !== "string" || typeof sid !== "string") throw new Error("claims");
      return { userId: payload.sub, sessionId: sid };
    } catch {
      throw new DomainError("UNAUTHENTICATED");
    }
  }
}
