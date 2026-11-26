// Spins up Postgres + PostgREST (docker) and a mock "Supabase gateway": JWKS, auth invite, and /rest/v1 proxy.
// The Worker code under test (Hono app, JWT verifier, RPC gateway) is the real production code.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { join } from "node:path";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import pg from "pg";

const ROOT = join(__dirname, "..", "..", "..", "..");
const COMPOSE = ["compose", "-f", join(ROOT, "e2e", "compose.yml")];
const JWT_SECRET = "e2e-jwt-secret-at-least-32-characters-long";
const DB_URL = "postgres://postgres:e2e@localhost:54330/postgres";
const REST_URL = "http://localhost:54331";

export interface Harness {
  baseUrl: string;
  db: pg.Client;
  mintUserJwt(userId: string, sessionId: string): Promise<string>;
  stop(): Promise<void>;
}

const docker = (args: string[]) => execFileSync("docker", [...COMPOSE, ...args], { stdio: "pipe", encoding: "utf8" });

async function waitFor(check: () => Promise<boolean>, what: string, ms = 90_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      if (await check()) return;
    } catch {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`timeout waiting for ${what}`);
}

export async function startHarness(): Promise<Harness> {
  docker(["down", "-v"]);
  docker(["up", "-d", "--wait", "db"]);
  let db!: pg.Client;
  await waitFor(async () => {
    const c = new pg.Client({ connectionString: DB_URL });
    await c.connect(); // a failed connect leaves the client unusable, so every attempt gets a fresh one
    db = c;
    return true;
  }, "postgres");

  const dir = join(ROOT, "supabase", "migrations");
  for (const f of readdirSync(dir).filter((n) => n.endsWith(".sql")).sort()) await db.query(readFileSync(join(dir, f), "utf8"));

  docker(["--profile", "rest", "up", "-d", "rest"]);
  const serviceJwt = await new SignJWT({ role: "service_role" })
    .setProtectedHeader({ alg: "HS256" })
    .setExpirationTime("2h")
    .sign(new TextEncoder().encode(JWT_SECRET));
  await waitFor(async () => (await fetch(`${REST_URL}/rpc/pf_get_setup_state`, { method: "POST", headers: { authorization: `Bearer ${serviceJwt}`, "content-type": "application/json" }, body: "{}" })).ok, "postgrest");

  const { publicKey, privateKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "e2e", alg: "RS256", use: "sig" };

  const server: Server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = Buffer.concat(chunks);
    if (url.pathname === "/auth/v1/.well-known/jwks.json") {
      res.setHeader("content-type", "application/json").end(JSON.stringify({ keys: [jwk] }));
      return;
    }
    if (url.pathname === "/auth/v1/invite" && req.method === "POST") {
      const { email } = JSON.parse(body.toString()) as { email: string };
      const r = await db.query("insert into auth.users(email, email_confirmed_at) values ($1, now()) returning id", [email]);
      res.setHeader("content-type", "application/json").end(JSON.stringify({ id: r.rows[0].id }));
      return;
    }
    if (url.pathname.startsWith("/rest/v1/")) {
      // Same translation Supabase's gateway does for secret keys: apikey -> service_role JWT.
      const upstream = await fetch(`${REST_URL}${url.pathname.slice("/rest/v1".length)}${url.search}`, {
        method: req.method ?? "GET",
        headers: { authorization: `Bearer ${serviceJwt}`, "content-type": "application/json" },
        body: req.method === "GET" ? null : new Uint8Array(body),
      });
      res.statusCode = upstream.status;
      res.setHeader("content-type", "application/json").end(await upstream.text());
      return;
    }
    res.statusCode = 404;
    res.end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  const baseUrl = `http://127.0.0.1:${port}`;

  return {
    baseUrl,
    db,
    mintUserJwt: (userId, sessionId) =>
      new SignJWT({ session_id: sessionId })
        .setProtectedHeader({ alg: "RS256", kid: "e2e" })
        .setSubject(userId)
        .setIssuer(`${baseUrl}/auth/v1`)
        .setAudience("authenticated")
        .setExpirationTime("1h")
        .sign(privateKey),
    stop: async () => {
      server.close();
      await db.end();
      docker(["--profile", "rest", "down", "-v"]);
    },
  };
}
