// Worker "probie": the live show's API under /api/. In production the same Worker also serves the site's static
// build, which is not in this repo.
//   POST /api/show/message  chat with the show agent; a real pay() attempt when the agent calls its tool
//   GET  /api/show/feed     the latest attempts, without IP hashes
//   GET  /api/board         every factory permit that passes the board rules, from the cron indexer
//   GET  /api/token         the $PROBIE contract once it is live (TOKEN_ADDRESS), the burn terms and the burns so far
//   POST /api/show/burn     a burn transaction's hash: its $PROBIE burned becomes shots past the free message caps
//   GET  /api/show/status   the show permit's state from the chain: the bounty left today, or the lock after a strike
//   GET  /api/show/check?amount=N  the permit's own check(): would it let the show agent pay a stranger $N right now
import Anthropic from '@anthropic-ai/sdk';
import { isAddress, isAddressEqual, type Address, type Hex } from 'viem';
import { talkClaude, talkMock, reasonName, type Pay } from './agent';
import { board, index } from './board';
import { ABI, DEAD, EXPLORER, SHOW_PERMIT, burnedIn, reader } from './chain';

export { Show } from './show';

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers } });

export default {
  async fetch(req, env, ctx): Promise<Response> {
    const { pathname } = new URL(req.url);
    try {
      if (pathname === '/api/show/message' && req.method === 'POST') return await message(req, env, ctx);
      if (pathname === '/api/show/feed' && req.method === 'GET') return json({ tries: await feed(env) }, 200, { 'cache-control': 'public, max-age=5' });
      if (pathname === '/api/board' && req.method === 'GET') return json({ permits: await board(env) }, 200, { 'cache-control': 'public, max-age=20' });
      if (pathname === '/api/token' && req.method === 'GET') return json(await tokenInfo(env), 200, { 'cache-control': 'public, max-age=30' });
      if (pathname === '/api/show/burn' && req.method === 'POST') return await claimBurn(req, env);
      if (pathname === '/api/show/status' && req.method === 'GET') return json(await showStatus(env), 200, { 'cache-control': 'public, max-age=10' });
      if (pathname === '/api/show/check' && req.method === 'GET') return await askPermit(req, env);
      return json({ error: 'not_found' }, 404);
    } catch (e) {
      console.error(JSON.stringify({ at: pathname, error: String((e as Error)?.message ?? e).slice(0, 500) }));
      return json({ error: 'busy' }, 503);
    }
  },
  async scheduled(_c, env, ctx) {
    ctx.waitUntil(index(env).catch(e => console.error(JSON.stringify({ at: 'index', error: String((e as Error)?.message ?? e).slice(0, 500) }))));
  },
} satisfies ExportedHandler<Env>;

async function message(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const raw = await req.text();
  if (raw.length > 4096) return json({ error: 'bad_request' }, 413);
  let body: { text?: unknown; wallet?: unknown; turnstileToken?: unknown } | null = null;
  try { body = JSON.parse(raw); } catch {}
  const text = typeof body?.text === 'string' ? body.text.trim() : '';
  const wallet = typeof body?.wallet === 'string' && body.wallet.trim() ? body.wallet.trim() : null;
  if (!text || text.length > 500) return json({ error: 'bad_request' }, 400);
  if (wallet !== null && !isAddress(wallet, { strict: false })) return json({ error: 'bad_wallet' }, 400);

  const ip = req.headers.get('cf-connecting-ip') ?? '0.0.0.0';
  if (!(await human(env, body?.turnstileToken, ip))) return json({ error: 'verify' }, 403);
  const show = env.SHOW.getByName('show');
  const ipHash = await hash(env.IP_SALT ?? 'dev', ip);
  const take = await show.take(ipHash);
  if (!take.ok) return json({ error: take.why === 'visitor' ? 'slow_down' : 'resting', retryAfter: take.retryAfter, burn: live(env) !== null }, take.why === 'visitor' ? 429 : 503, { 'retry-after': String(take.retryAfter) });

  const pay: Pay = (to, amount) => show.pay(to, String(amount));
  const t0 = Date.now();
  let turn;
  try {
    turn = env.ANTHROPIC_API_KEY
      ? await talkClaude(new Anthropic({ apiKey: env.ANTHROPIC_API_KEY, maxRetries: 1, timeout: 30_000 }), text, wallet, pay)
      : await talkMock(text, wallet, pay);
  } catch (e) {
    console.error(JSON.stringify({ at: 'model', error: String((e as Error)?.message ?? e).slice(0, 500) }));
    return json({ error: 'busy' }, 503);
  }
  if (turn.usd) ctx.waitUntil(show.spend(turn.usd));
  console.log(JSON.stringify({ at: 'turn', mode: turn.mode, ms: Date.now() - t0, usd: Number(turn.usd.toFixed(5)), tool: turn.tool, outcome: turn.outcome?.kind ?? null, calls: turn.calls }));

  const o = turn.outcome;
  // an attempt the chain settled: a strike, or (since level 2) a real payment. Only these keep their tx in D1, so the
  // feed can tell a payment (reason NULL) from a strike; a tx that never confirmed is in the 'pay' log line instead.
  const tx = o?.kind === 'strike' || o?.kind === 'paid' ? o.tx : null;
  const attempt = tx && (o?.kind === 'strike' || o?.kind === 'paid')
    ? { blocked: o.kind === 'strike', reason: o.kind === 'strike' ? reasonName(o.reason) : null, strikes: o.kind === 'strike' ? o.strikes : null, txHash: tx, explorerUrl: `${EXPLORER}/tx/${tx}` }
    : null;
  ctx.waitUntil(env.DB.prepare(
    'INSERT INTO messages (ts, ip_hash, text, reply, tool, to_addr, amount, tx, reason, strikes, mode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
  ).bind(Date.now(), ipHash, text.slice(0, 500), turn.reply ?? '', turn.tool ? 1 : 0, turn.to?.slice(0, 64) ?? null, turn.amount,
    tx, o?.kind === 'strike' ? o.reason : null, o?.kind === 'strike' ? o.strikes : null, turn.mode).run());
  return json({ reply: turn.reply, attempt, ...(take.shotsLeft !== undefined ? { shotsLeft: take.shotsLeft } : {}) });
}

async function feed(env: Env) {
  const { results } = await env.DB.prepare(
    'SELECT id, ts, to_addr AS "to", amount, tx, reason, strikes FROM messages WHERE tx IS NOT NULL ORDER BY id DESC LIMIT 8',
  ).all<{ id: number; ts: number; to: string; amount: number; tx: string; reason: number | null; strikes: number | null }>();
  return results.map(r => ({ ...r, blocked: r.reason !== null, reason: r.reason === null ? null : reasonName(r.reason), url: `${EXPLORER}/tx/${r.tx}` }));
}

// The token, once TOKEN_ADDRESS is set at launch; until then the burn route is closed and the site shows nothing.
const live = (env: Env) => (env.TOKEN_ADDRESS && isAddress(env.TOKEN_ADDRESS) ? (env.TOKEN_ADDRESS as Address) : null);
let decimals: number | undefined;
const tokenDecimals = async (env: Env, token: Address) =>
  (decimals ??= Number(await reader(env).readContract({ address: token, abi: ABI, functionName: 'decimals' })));
const perShot = (env: Env) => BigInt(env.BURN_PER_SHOT);

// open: a stranger can still be paid today; taken: today's new-payee room is spent; locked: a strike paused new payees
// "Ask the permit first": the permit's check() for a stranger (any address the show never approved; it approves none),
// read from the chain. Free, read-only, and the same verdict pay() would reach.
const STRANGER = '0x000000000000000000000000000000000000bEEF' as Address;
const VERDICT = ['OK', 'OVER_LIMIT', 'OVER_CEILING', 'PAYEE_NOT_ALLOWED', 'NEW_PAYEES_PAUSED', 'OVER_NEW_PAYEE_CAP', 'FROZEN'];
async function askPermit(req: Request, env: Env): Promise<Response> {
  const amount = Number(new URL(req.url).searchParams.get('amount'));
  if (!Number.isFinite(amount) || amount < 0.01 || amount > 1_000_000) return json({ error: 'bad_amount' }, 400);
  const units = BigInt(Math.round(amount * 100)) * 10_000n; // whole cents, in USDG's 6 decimals
  const code = Number(await reader(env).readContract({ address: SHOW_PERMIT, abi: ABI, functionName: 'check', args: [STRANGER, units] }));
  return json({ amount: Number(units) / 1e6, code, verdict: VERDICT[code] ?? `CODE_${code}` }, 200, { 'cache-control': 'public, max-age=10' });
}

// The scoreboard adds, over every permit the show's Safe has run (one at L0, then two at L2), the strikes and the USDG
// paid out (the board's indexed volume), plus all the $PROBIE sitting in the burn address.
async function showStatus(env: Env) {
  const r = reader(env), token = live(env);
  const [s, permits, dead] = await Promise.all([
    r.readContract({ address: SHOW_PERMIT, abi: ABI, functionName: 'status' }),
    board(env) as Promise<unknown> as Promise<{ permit: string; safe: string; strikes: number; volume: number }[]>,
    token ? r.readContract({ address: token, abi: ABI, functionName: 'balanceOf', args: [DEAD] }) : Promise.resolve(0n),
  ]);
  const usd = (v: bigint) => Number(v) / 1e6;
  const pausedUntil = Number(s.pausedUntil) * 1000;
  // locked: no stranger can be paid at all, so nothing is left to win, whatever today's new-payee room says
  const locked = s.frozen || pausedUntil > Date.now();
  const left = locked ? 0 : Math.max(0, Math.min(usd(s.newPayeeCap - s.newSpentToday), usd(s.ceilingLeft)));
  const state = locked ? 'locked' : left > 0 ? 'open' : 'taken';
  const safe = permits.find(p => isAddressEqual(p.permit as Address, SHOW_PERMIT))?.safe as Address | undefined;
  const ours = safe ? permits.filter(p => isAddressEqual(p.safe as Address, safe)) : [];
  // the current permit's strikes come live from the chain; the board indexes the others once a minute
  const strikesAll = ours.filter(p => !isAddressEqual(p.permit as Address, SHOW_PERMIT)).reduce((n, p) => n + Number(p.strikes), 0) + s.strikes;
  const paidOut = ours.reduce((n, p) => n + Number(p.volume), 0);
  return { state, level: s.level, left, cap: usd(s.newPayeeCap), pausedUntil: pausedUntil || null, strikes: s.strikes, strikesAll, paidOut, burned: Number(dead) / 1e18 };
}

async function tokenInfo(env: Env) {
  const token = live(env);
  if (!token) return { token: null };
  const [dec, stats] = await Promise.all([tokenDecimals(env, token), env.SHOW.getByName('show').burnStats()]);
  return { token, dead: DEAD, perShot: Number(perShot(env)), maxShots: Number(env.MAX_SHOTS_PER_CLAIM), claims: stats.claims, shots: stats.shots,
    burned: Number(BigInt(stats.burned) / 10n ** BigInt(dec)) };
}

// A visitor pastes the hash of their burn. It counts once, for whoever claims it first, and only for $PROBIE sent to
// the dead address or burned to address(0) in a transaction that succeeded.
async function claimBurn(req: Request, env: Env): Promise<Response> {
  const token = live(env);
  if (!token) return json({ error: 'not_live' }, 503);
  const raw = await req.text();
  if (raw.length > 1024) return json({ error: 'bad_request' }, 413);
  let body: { tx?: unknown } | null = null;
  try { body = JSON.parse(raw); } catch {}
  const tx = typeof body?.tx === 'string' ? body.tx.trim().toLowerCase() : '';
  if (!/^0x[0-9a-f]{64}$/.test(tx)) return json({ error: 'bad_tx' }, 400);
  const ipHash = await hash(env.IP_SALT ?? 'dev', req.headers.get('cf-connecting-ip') ?? '0.0.0.0');
  const show = env.SHOW.getByName('show');
  const gate = await show.claimGate(ipHash);
  if (!gate.ok) return json({ error: 'slow_down', retryAfter: gate.retryAfter }, 429, { 'retry-after': String(gate.retryAfter) });
  const receipt = await reader(env).getTransactionReceipt({ hash: tx as Hex }).catch(() => null);
  if (!receipt) return json({ error: 'not_found' }, 404); // not mined yet, or no such transaction
  const { amount, from } = receipt.status === 'success' ? burnedIn(receipt.logs, token) : { amount: 0n, from: null };
  const unit = perShot(env) * 10n ** BigInt(await tokenDecimals(env, token));
  const shots = Math.min(Number(amount / unit), Number(env.MAX_SHOTS_PER_CLAIM));
  if (shots < 1) return json({ error: 'not_burn', perShot: Number(perShot(env)) }, 422);
  const r = await show.claim(tx, ipHash, shots, String(amount), from ?? '');
  if (!r.ok) return json({ error: 'claimed' }, 409);
  console.log(JSON.stringify({ at: 'burn', tx, shots, amount: String(amount) }));
  return json({ got: shots, shots: r.shots });
}

// Turnstile siteverify: success, our action and one of our hostnames, or no. Fails closed without a secret.
async function human(env: Env, token: unknown, ip: string): Promise<boolean> {
  if (!env.TURNSTILE_SECRET || typeof token !== 'string' || !token || token.length > 2048) return false;
  const hosts = new Set(env.TURNSTILE_HOSTNAMES.split(',').map(h => h.trim()).filter(Boolean));
  try {
    const r = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      body: new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token, remoteip: ip }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!r.ok) return false;
    const v = (await r.json()) as { success?: boolean; action?: string; hostname?: string; metadata?: { result_with_testing_key?: boolean } };
    // the public test keys (local dev) answer for hostname example.com with no action; production never lists that host
    const action = v.action === 'show' || v.metadata?.result_with_testing_key === true;
    return v.success === true && action && hosts.has(v.hostname ?? '');
  } catch {
    return false;
  }
}

// An IP is never stored: only a salted HMAC of it, enough to count one visitor's messages.
async function hash(salt: string, ip: string) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(salt), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(ip)));
  return [...sig.slice(0, 12)].map(b => b.toString(16).padStart(2, '0')).join('');
}
