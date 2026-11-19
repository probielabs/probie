// The board: every permit from the official factory, indexed from chain events into D1 once a minute.
// The rules (../README.md, "Board indexing"): only factory permits; the Safe must be a SafeProxy 1.4.1 whose masterCopy() is a
// Safe 1.4.1 singleton; volume and payees count only USDG Transfer logs in the same transaction as a Paid.
import { decodeAbiParameters, getAddress, isAddressEqual, keccak256, parseAbi, type Address } from 'viem';
import { ABI, FACTORY, FACTORY_BLOCK, SAFE_PROXY_CODEHASH, SAFE_SINGLETONS, USDG, reader } from './chain';

const SPAN = 2000n; // blocks per eth_getLogs: some RPC providers answer at most 2,000
const MAX_CALLS = 30; // RPC calls per run, well under the Free plan's 50 subrequests
// one topic-only query per range: the factory's PermitCreated and every permit's events; unknown senders are dropped
const EVENTS = parseAbi([
  'event PermitCreated(address indexed safe, address indexed permit, address indexed agent, uint8 startLevel)',
  'event Paid(address indexed to, uint256 amount, uint8 level, bool newPayee)',
  'event Strike(address indexed to, uint256 amount, uint8 reason, uint8 level, uint32 strikes)',
  'event LevelChanged(uint8 from, uint8 to)',
]);

type Pub = ReturnType<typeof reader>;
const getLogs = (pub: Pub, fromBlock: bigint, toBlock: bigint) => pub.getLogs({ events: EVENTS, fromBlock, toBlock });
type Ev = Awaited<ReturnType<typeof getLogs>>[number];

export async function index(env: Env) {
  const pub = reader(env);
  let calls = 1;
  const head = await pub.getBlockNumber({ cacheTime: 0 });
  const cur = await env.DB.prepare("SELECT v FROM meta WHERE k = 'cursor'").first<string>('v');
  let from = cur ? BigInt(cur) + 1n : FACTORY_BLOCK;
  const known = new Map<string, { safe: Address; ok: number }>();
  for (const r of (await env.DB.prepare('SELECT permit, safe, ok FROM permits').all<{ permit: string; safe: Address; ok: number }>()).results) {
    known.set(r.permit.toLowerCase(), { safe: r.safe, ok: r.ok });
  }
  const times = new Map<bigint, number>();
  const tsOf = async (l: Ev) => {
    const raw = (l as { blockTimestamp?: bigint | string }).blockTimestamp; // some RPC nodes put it on every log
    if (raw && BigInt(raw) > 0n) return Number(BigInt(raw)); // an anvil fork reports 0
    if (!times.has(l.blockNumber)) { times.set(l.blockNumber, Number((await pub.getBlock({ blockNumber: l.blockNumber })).timestamp)); calls++; }
    return times.get(l.blockNumber)!;
  };

  while (from <= head && calls < MAX_CALLS) {
    let to = from + SPAN - 1n > head ? head : from + SPAN - 1n;
    let logs: Ev[];
    for (;;) {
      try {
        logs = await getLogs(pub, from, to);
        calls++;
        break;
      } catch (e) {
        calls++; // too many logs (10,000 cap) or a failed call: halve the range and try again
        if (to === from || calls >= MAX_CALLS) throw e;
        to = from + (to - from) / 2n;
      }
    }
    const stmts: D1PreparedStatement[] = [];
    for (const l of logs) {
      if (l.removed || !l.args) continue;
      const ts = await tsOf(l);
      if (l.eventName === 'PermitCreated') {
        if (!isAddressEqual(l.address, FACTORY)) continue;
        const { safe, permit, agent, startLevel } = l.args as { safe: Address; permit: Address; agent: Address; startLevel: number };
        const ok = (await realSafe(pub, safe)) ? 1 : 0;
        calls += 2;
        known.set(permit.toLowerCase(), { safe, ok });
        stmts.push(env.DB.prepare('INSERT OR IGNORE INTO permits (permit, safe, agent, start_level, block, tx, ok, last_ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
          .bind(permit, safe, agent, startLevel, Number(l.blockNumber), l.transactionHash, ok, ts));
        continue;
      }
      const p = known.get(l.address.toLowerCase());
      if (!p) continue; // not a factory permit
      const permit = getAddress(l.address); // rows hold checksummed addresses; logs carry lowercase ones
      stmts.push(env.DB.prepare('UPDATE permits SET last_ts = MAX(COALESCE(last_ts, 0), ?) WHERE permit = ?').bind(ts, permit));
      if (l.eventName === 'Paid' && p.ok) {
        const { to: payee, amount } = l.args as { to: Address; amount: bigint };
        const receipt = await pub.getTransactionReceipt({ hash: l.transactionHash });
        calls++;
        const moved = receipt.logs.some(t => isAddressEqual(t.address, USDG) && t.topics[0] === TRANSFER
          && sameAddr(t.topics[1], p.safe) && sameAddr(t.topics[2], payee) && BigInt(t.data) === amount);
        if (moved) {
          stmts.push(env.DB.prepare('INSERT OR IGNORE INTO payments (tx, log_index, permit, payee, amount, ts) VALUES (?, ?, ?, ?, ?, ?)')
            .bind(l.transactionHash, l.logIndex, permit, getAddress(payee), Number(amount), ts));
        }
      }
    }
    stmts.push(env.DB.prepare("INSERT INTO meta (k, v) VALUES ('cursor', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v").bind(String(to)));
    await env.DB.batch(stmts); // the rows and the cursor move together
    from = to + 1n;
  }
  await refresh(env, pub);
}

const TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const sameAddr = (topic: string | undefined, a: Address) => !!topic && isAddressEqual(`0x${topic.slice(26)}`, a);

async function realSafe(pub: Pub, safe: Address) {
  const code = await pub.getCode({ address: safe });
  if (!code || keccak256(code) !== SAFE_PROXY_CODEHASH) return false;
  // masterCopy() (0xa619486e) is answered by the proxy itself: a code-hash check alone lets a proxy point at a fake singleton
  const { data } = await pub.call({ to: safe, data: '0xa619486e' });
  if (!data || data.length < 66) return false;
  const [singleton] = decodeAbiParameters([{ type: 'address' }], data);
  return SAFE_SINGLETONS.some(s => isAddressEqual(s as Address, singleton));
}

// The current level, clean days, strikes and frozen flag come from status(): LevelChanged nets out within one call.
async function refresh(env: Env, pub: Pub) {
  const rows = (await env.DB.prepare('SELECT permit FROM permits WHERE ok = 1').all<{ permit: Address }>()).results;
  if (!rows.length) return;
  const res = await pub.multicall({ contracts: rows.map(r => ({ address: r.permit, abi: ABI, functionName: 'status' as const })), allowFailure: true });
  const now = Math.floor(Date.now() / 1000);
  const stmts = res.flatMap((x, i) => x.status !== 'success' ? [] : [env.DB.prepare(
    'UPDATE permits SET level = ?, clean_days = ?, strikes = ?, frozen = ?, status_at = ? WHERE permit = ?',
  ).bind(x.result.level, Number(x.result.cleanDays), x.result.strikes, x.result.frozen ? 1 : 0, now, rows[i].permit)]);
  if (stmts.length) await env.DB.batch(stmts);
}

export async function board(env: Env) {
  const { results } = await env.DB.prepare(`
    SELECT p.permit, p.safe, p.level, p.clean_days AS cleanDays, p.strikes, p.frozen, p.last_ts AS lastActivity,
      p.status_at AS statusAt, COALESCE(SUM(y.amount), 0) AS volume, COUNT(DISTINCT y.payee) AS payees
    FROM permits p LEFT JOIN payments y ON y.permit = p.permit
    WHERE p.ok = 1 AND p.status_at IS NOT NULL
    GROUP BY p.permit ORDER BY p.last_ts DESC LIMIT 200`).all<Record<string, number | string>>();
  return results.map(r => ({ ...r, frozen: !!r.frozen, volume: Number(r.volume) / 1e6 }));
}
