// One Durable Object, "show": the message caps, the daily model spend cap, and the show agent's transactions, one
// at a time so two visitors never race for the same nonce.
// A single global instance; shard the visitor caps by IP hash if the show ever outgrows one object.
import { DurableObject } from 'cloudflare:workers';
import { isAddressEqual, parseEventLogs, type Address } from 'viem';
import { ABI, SHOW_PERMIT, agent, reader } from './chain';
import type { PayOutcome } from './agent';

const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const SHOTS_KEEP = 30 * DAY; // unused shots last a month after the visitor's last claim or shot
const end = (now: number, w: number) => Math.floor(now / w) * w + w; // fixed windows (UTC hours and days)

export type Take = { ok: true; shotsLeft?: number } | { ok: false; why: 'visitor' | 'resting'; retryAfter: number };

export class Show extends DurableObject<Env> {
  #queue: Promise<unknown> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS counters (k TEXT PRIMARY KEY, n REAL NOT NULL, exp INTEGER NOT NULL)');
    // one row per claimed burn transaction: the primary key is what stops a second claim of the same burn
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS burns (tx TEXT PRIMARY KEY, ts INTEGER NOT NULL, ip TEXT NOT NULL, shots INTEGER NOT NULL, amount TEXT NOT NULL, from_addr TEXT NOT NULL)');
  }

  #get(k: string): number {
    return this.ctx.storage.sql.exec<{ n: number }>('SELECT n FROM counters WHERE k = ?', k).toArray()[0]?.n ?? 0;
  }

  #add(k: string, n: number, exp: number) {
    this.ctx.storage.sql.exec('INSERT INTO counters (k, n, exp) VALUES (?, ?, ?) ON CONFLICT(k) DO UPDATE SET n = n + excluded.n, exp = max(exp, excluded.exp)', k, n, exp);
  }

  // One visitor message: checked against every cap, counted only when all pass. Synchronous SQL, so atomic.
  // Past a free cap, one burned shot still gets the message through; the daily model budget holds for everyone.
  take(ip: string): Take {
    const now = Date.now();
    this.ctx.storage.sql.exec('DELETE FROM counters WHERE exp < ?', now);
    const w = end(now, 10 * MIN), h = end(now, HOUR), d = end(now, DAY);
    if (this.#get(`usd:${d}`) >= Number(this.env.DAILY_USD)) return { ok: false, why: 'resting', retryAfter: Math.ceil((d - now) / 1000) };
    const free: [string, number, number, 'visitor' | 'resting'][] = [
      [`v10:${ip}:${w}`, 5, w, 'visitor'], // about 5 messages per 10 minutes per visitor
      [`vd:${ip}:${d}`, 30, d, 'visitor'], // and 30 a day
      [`h:${h}`, Number(this.env.HOURLY_MESSAGES), h, 'resting'], // every visitor together, per hour
    ];
    const full = free.find(([k, cap]) => this.#get(k) >= cap);
    if (!full) {
      for (const [k, , e] of free) this.#add(k, 1, e);
      return { ok: true };
    }
    const shots = this.#get(`shots:${ip}`);
    if (shots >= 1) {
      this.#add(`shots:${ip}`, -1, now + SHOTS_KEEP);
      return { ok: true, shotsLeft: shots - 1 };
    }
    return { ok: false, why: full[3], retryAfter: Math.ceil((full[2] - now) / 1000) };
  }

  // Burn claims: a few per visitor per 10 minutes, checked before the Worker asks the chain about the transaction.
  claimGate(ip: string): Take {
    const now = Date.now(), w = end(now, 10 * MIN), k = `c10:${ip}:${w}`;
    if (this.#get(k) >= 10) return { ok: false, why: 'visitor', retryAfter: Math.ceil((w - now) / 1000) };
    this.#add(k, 1, w);
    return { ok: true };
  }

  // A verified burn becomes shots for this visitor, once per transaction.
  claim(tx: string, ip: string, shots: number, amount: string, from: string): { ok: true; shots: number } | { ok: false } {
    const r = this.ctx.storage.sql.exec('INSERT OR IGNORE INTO burns (tx, ts, ip, shots, amount, from_addr) VALUES (?, ?, ?, ?, ?, ?)',
      tx, Date.now(), ip, shots, amount, from);
    if (r.rowsWritten === 0) return { ok: false };
    this.#add(`shots:${ip}`, shots, Date.now() + SHOTS_KEEP);
    return { ok: true, shots: this.#get(`shots:${ip}`) };
  }

  burnStats() {
    const rows = this.ctx.storage.sql.exec<{ amount: string; shots: number }>('SELECT amount, shots FROM burns').toArray();
    return { claims: rows.length, shots: rows.reduce((a, r) => a + r.shots, 0), burned: String(rows.reduce((a, r) => a + BigInt(r.amount), 0n)) };
  }

  spend(usd: number) {
    const d = end(Date.now(), DAY);
    this.#add(`usd:${d}`, usd, d);
  }

  pay(to: Address, amount: string): Promise<PayOutcome> {
    const run = this.#queue.then(() => this.#pay(to, BigInt(amount)));
    this.#queue = run.catch(() => {});
    return run;
  }

  async #pay(to: Address, amount: bigint): Promise<PayOutcome> {
    const now = Date.now(), h = end(now, HOUR), d = end(now, DAY);
    if (this.#get(`tx:${h}`) >= Number(this.env.TX_HOURLY) || this.#get(`txd:${d}`) >= Number(this.env.TX_DAILY)) return { kind: 'paused' };
    let hash: `0x${string}` | undefined;
    try {
      const pub = reader(this.env);
      const { account, wallet } = agent(this.env);
      // the dry run catches a revert before any gas is spent. Since level 2 (18 Nov 2026) a payment the permit allows is
      // sent for real: that is the show's bounty, and the permit itself caps it ($10 a day to someone new).
      const sim = await pub.simulateContract({ address: SHOW_PERMIT, abi: ABI, functionName: 'pay', args: [to, amount], account });
      hash = await wallet.writeContract(sim.request);
      this.#add(`tx:${h}`, 1, h);
      this.#add(`txd:${d}`, 1, d);
      const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 250, timeout: 30_000 });
      const fee = r.gasUsed * r.effectiveGasPrice;
      console.log(JSON.stringify({ at: 'pay', tx: hash, status: r.status, gasUsed: String(r.gasUsed), gasPrice: String(r.effectiveGasPrice), feeWei: String(fee) }));
      if (r.status !== 'success') return { kind: 'error', message: 'the transaction reverted', tx: hash };
      const logs = parseEventLogs({ abi: ABI, logs: r.logs.filter(l => isAddressEqual(l.address, SHOW_PERMIT)) });
      for (const l of logs) {
        if (l.eventName === 'Strike') return { kind: 'strike', tx: hash, reason: l.args.reason, strikes: l.args.strikes, gasUsed: String(r.gasUsed), feeWei: String(fee) };
        if (l.eventName === 'Paid') return { kind: 'paid', tx: hash };
      }
      return { kind: 'error', message: 'no Strike or Paid event in the receipt', tx: hash };
    } catch (e) {
      // viem errors carry the request, never the key
      console.error(JSON.stringify({ at: 'pay', tx: hash ?? null, error: String((e as Error)?.message ?? e).slice(0, 500) }));
      return { kind: 'error', message: hash ? 'the chain did not confirm it in time' : 'the chain could not take it right now', ...(hash ? { tx: hash } : {}) };
    }
  }
}
