// Robinhood Chain: the live addresses, the ABI pieces the Worker reads, and the viem clients.
import { createPublicClient, createWalletClient, fallback, http, isAddressEqual, parseAbi, parseEventLogs, type Address, type Hex, type Log } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { robinhood } from 'viem/chains';

export const FACTORY = '0xe475F59873Eb3EAfCf42b70dF64DcABd071715CB';
export const FACTORY_BLOCK = 116847264n;
// the show agent's permit: probie #2's, L2, no payees, $10/day ceiling (19 Nov 2026, tx 0xba60c55d…718c), signed by a
// new agent key. It may pay someone new up to $10 a day, so the show can be won. Probie #1's permits stay idle with their
// records: 0x9247C1Bb5eAe63A9384A2E4CC4Aa02bd7E585E15 (L2, paid $10, then locked) and 0xF9e98d1E…1511 (L0).
export const SHOW_PERMIT = '0xaC2E81809d11e8117DD946d2C941857f411b94Ec';
export const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168';
// The board rules (../README.md, "Board indexing"): a real Safe is a SafeProxy 1.4.1 whose masterCopy() is a Safe 1.4.1 singleton
export const SAFE_PROXY_CODEHASH = '0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c';
export const SAFE_SINGLETONS = ['0x41675C099F32341bf84BFc5382aF534df5C7461a', '0x29fcB43b46531BcA003ddC8FCB67FFE91900C762'];
export const EXPLORER = 'https://robinhoodchain.blockscout.com';
// $PROBIE burned for shots in the show: sent to the dead address, or to address(0) by a burn()
export const DEAD = '0x000000000000000000000000000000000000dEaD';
const ZERO = '0x0000000000000000000000000000000000000000';

export const ABI = parseAbi([
  'function pay(address to, uint256 amount) returns (bool)',
  'function status() view returns ((uint8 level, uint256 cleanDays, uint256 daysToNextLevel, uint256 dailyLimit, uint256 spentToday, uint256 newPayeeCap, uint256 newSpentToday, uint256 ceilingLeft, uint64 pausedUntil, uint32 strikes, bool frozen))',
  'event PermitCreated(address indexed safe, address indexed permit, address indexed agent, uint8 startLevel)',
  'event Paid(address indexed to, uint256 amount, uint8 level, bool newPayee)',
  'event Strike(address indexed to, uint256 amount, uint8 reason, uint8 level, uint32 strikes)',
  'event LevelChanged(uint8 from, uint8 to)',
  'event Transfer(address indexed from, address indexed to, uint256 value)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)',
  'function check(address to, uint256 amount) view returns (uint8)',
  'error NotAgent()',
  'error IsFrozen()',
  'error BadAddress()',
  'error BadAmount()',
  'error NoCeiling()',
  'error BadCeiling()',
]);

// check() and Strike reason codes
export const REASONS = ['OK', 'OVER_LIMIT', 'OVER_CEILING', 'PAYEE_NOT_ALLOWED', 'NEW_PAYEES_PAUSED', 'OVER_NEW_PAYEE_CAP'] as const;

// RPC_URL is a comma-separated list, tried in order. Robinhood Chain's public RPC can answer Cloudflare's egress
// with 429s, so a provider with higher limits may go first. Some RPCs want a browser-like User-Agent.
function transport(env: Env) {
  return fallback(env.RPC_URL.split(',').map(u => http(u.trim(), { timeout: 15_000, fetchOptions: { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; probie)' } } })));
}

export const reader = (env: Env) => createPublicClient({ chain: robinhood, transport: transport(env) });

export function agent(env: Env) {
  const account = privateKeyToAccount(env.SHOW_AGENT_KEY as Hex); // throws on a missing or malformed key
  return { account, wallet: createWalletClient({ account, chain: robinhood, transport: transport(env) }) };
}

// What one transaction burned of `token`: its Transfer logs to the dead address or address(0), summed, with the
// first sender. Logs from any other contract are ignored, so a look-alike token burns nothing here.
export function burnedIn(logs: readonly Pick<Log, 'address' | 'topics' | 'data'>[], token: Address) {
  let amount = 0n, from: Address | null = null;
  const mine = logs.filter(l => isAddressEqual(l.address, token)) as Log[];
  for (const l of parseEventLogs({ abi: ABI, eventName: 'Transfer', logs: mine })) {
    if (!isAddressEqual(l.args.to, DEAD) && !isAddressEqual(l.args.to, ZERO)) continue;
    amount += l.args.value;
    from ??= l.args.from;
  }
  return { amount, from };
}
