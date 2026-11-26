import { createRemoteJWKSet, jwtVerify } from "jose";
import type { Config } from "../../bootstrap/config";
import { DomainError } from "../../shared/errors";

export interface Session {
  userId: string;
  sessionId: string;
}

// Verifies the Supabase access token: signature via JWKS, issuer, audience, expiry.
// Owner binding is checked by the caller against the DB singleton owner.
export class SessionVerifier {
  private readonly jwks;
  private readonly issuer: string;

  constructor(cfg: Config) {
    this.issuer = `${cfg.supabaseUrl}/auth/v1`;
    this.jwks = createRemoteJWKSet(new URL(`${this.issuer}/.well-known/jwks.json`));
  }

  async verify(authorization: string | undefined): Promise<Session> {
    const token = authorization?.startsWith("Bearer ") ? authorization.slice(7) : undefined;
    if (!token) throw new DomainError("UNAUTHENTICATED");
    try {
      const { payload } = await jwtVerify(token, this.jwks, { issuer: this.issuer, audience: "authenticated" });
      const sid = payload["session_id"];
      if (typeof payload.sub !== "string" || typeof sid !== "string") throw new Error("claims");
      return { userId: payload.sub, sessionId: sid };
    } catch {
      throw new DomainError("UNAUTHENTICATED");
    }
  }
}
