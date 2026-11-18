// One payment, the way an agent should make it: read the permit, ask check(), then pay() and read what happened.
//
//   npm install
//   PERMIT=0x… TO=0x… AMOUNT=1.5 npm run agent                  read-only: the permit's status and check()'s verdict
//   PERMIT=0x… TO=0x… AMOUNT=1.5 AGENT_KEY=0x… npm run agent    also sends pay() as the agent
//
// AMOUNT is in USDG (6 decimals). RPC_URL overrides the public Robinhood Chain RPC.
import {
  createPublicClient, createWalletClient, formatUnits, http, isAddress, parseAbi, parseEventLogs, parseUnits,
  type Address, type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { robinhood } from 'viem/chains';

const abi = parseAbi([
  'function pay(address to, uint256 amount) returns (bool)',
  'function check(address to, uint256 amount) view returns (uint8)',
  'function status() view returns ((uint8 level, uint256 cleanDays, uint256 daysToNextLevel, uint256 dailyLimit, uint256 spentToday, uint256 newPayeeCap, uint256 newSpentToday, uint256 ceilingLeft, uint64 pausedUntil, uint32 strikes, bool frozen))',
  'event Paid(address indexed to, uint256 amount, uint8 level, bool newPayee)',
  'event Strike(address indexed to, uint256 amount, uint8 reason, uint8 level, uint32 strikes)',
]);
// check() codes; pay() records 1-5 as the strike's reason
const CODES = ['OK', 'OVER_LIMIT', 'OVER_CEILING', 'PAYEE_NOT_ALLOWED', 'NEW_PAYEES_PAUSED', 'OVER_NEW_PAYEE_CAP', 'FROZEN'];
const usd = (v: bigint) => `$${formatUnits(v, 6)}`;

const { PERMIT, TO, AMOUNT, AGENT_KEY, RPC_URL } = process.env;
if (!PERMIT || !isAddress(PERMIT) || !TO || !isAddress(TO) || !AMOUNT) throw new Error('set PERMIT, TO and AMOUNT');
const permit = PERMIT as Address, to = TO as Address, amount = parseUnits(AMOUNT, 6);
const transport = http(RPC_URL ?? 'https://rpc.mainnet.chain.robinhood.com');
const reader = createPublicClient({ chain: robinhood, transport });

const st = await reader.readContract({ address: permit, abi, functionName: 'status' });
console.log(
  `L${st.level} | daily limit ${usd(st.dailyLimit)} | spent today ${usd(st.spentToday)} | ` +
  `ceiling left ${usd(st.ceilingLeft)} | clean days ${st.cleanDays} | strikes ${st.strikes}${st.frozen ? ' | FROZEN' : ''}`,
);

const code = await reader.readContract({ address: permit, abi, functionName: 'check', args: [to, amount] });
console.log(`check(${to}, ${usd(amount)}) -> ${CODES[code] ?? code}`);
if (!AGENT_KEY) process.exit(0);

// A careful agent stops here on anything but OK. Sending anyway is allowed: the permit blocks the payment,
// nothing moves, and the attempt is recorded on chain as a strike.
const account = privateKeyToAccount(AGENT_KEY as Hex);
const wallet = createWalletClient({ account, chain: robinhood, transport });
const hash = await wallet.writeContract({ address: permit, abi, functionName: 'pay', args: [to, amount] });
const receipt = await reader.waitForTransactionReceipt({ hash });
for (const log of parseEventLogs({ abi, logs: receipt.logs })) {
  if (log.eventName === 'Paid') console.log(`paid ${usd(log.args.amount)} to ${log.args.to} at L${log.args.level}`);
  if (log.eventName === 'Strike') console.log(`strike #${log.args.strikes}: ${CODES[log.args.reason] ?? log.args.reason}`);
}
console.log(`tx ${hash}`);
