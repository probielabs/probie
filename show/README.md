# The live show's backend

The show at https://probielabs.com runs on this Cloudflare Worker. Anyone can chat with a demo agent, our probie, and
try to talk it into paying them. The agent has one tool, `pay`, and every call goes through its learner's permit on
Robinhood Chain: a payment the permit allows really goes out, and one it doesn't is blocked on chain and recorded as a
strike.

The agent's prompt is in [src/agent.ts](src/agent.ts) on purpose. Knowing it moves no limit: whatever the model is
talked into, the permit decides what leaves the Safe.

## One message, step by step

1. `POST /api/show/message` checks the Turnstile token, then the caps, all in one Durable Object
   ([src/show.ts](src/show.ts)): about 5 messages per 10 minutes and 30 a day per visitor, a shared hourly cap, and a
   daily model budget.
2. The agent answers with a Claude model ([src/agent.ts](src/agent.ts)) and may call `pay` once per message.
3. `runPay` is the trust boundary: nothing is sent without a valid address and an amount above 0.
4. The Durable Object sends one transaction at a time, so two visitors never race for a nonce. It dry-runs
   `pay(to, amount)` on the permit, sends it with the agent's key, and reads the receipt's `Paid` or `Strike` event.
5. The message, the reply and the attempt's transaction go into D1 ([schema.sql](schema.sql)). Visitors are counted by
   a salted HMAC of their IP; the IP is never stored.

## Routes

| Route | What it does |
|---|---|
| `POST /api/show/message` | Chat with the agent; a real `pay()` attempt when it calls its tool. |
| `GET /api/show/feed` | The latest attempts that reached the chain, with their transactions. |
| `GET /api/show/status` | The show permit's state: the bounty left today, or the lock after a strike. |
| `GET /api/show/check?amount=N` | The permit's own `check()`: would it let the agent pay a stranger $N right now. |
| `GET /api/board` | Every factory permit that passes the board rules, from the indexer. |
| `GET /api/token` | The $PROBIE contract, the burn terms and the burns so far. |
| `POST /api/show/burn` | A burn transaction's hash: its burned $PROBIE becomes extra messages past the free caps. |

## The board

Once a minute a cron job reads the factory's `PermitCreated` events and every permit's events into D1
([src/board.ts](src/board.ts)). It keeps only permits that pass the rules in
[the main README](../README.md#board-indexing).

## Burns

$PROBIE sent to the dead address, or burned to address(0), in a transaction that succeeded can be claimed once, by
whoever pastes its hash first. Every 10,000 whole tokens is one extra message past the free caps, up to 50 per burn.

## Run it

```shell
npm ci
npm run types   # wrangler types: the bindings and vars from wrangler.jsonc
npm run check   # offline: the Claude loop through the real SDK against a fake fetch, the tool's trust boundary, the burn maths
```

`npm run dev` serves it locally with the secrets in `.dev.vars` (listed in [wrangler.jsonc](wrangler.jsonc)),
Turnstile's test keys and `RPC_URL` pointed at an [anvil](https://getfoundry.sh) fork of Robinhood Chain. Without
`ANTHROPIC_API_KEY` the agent runs in mock mode: canned English replies, the same pay path. `node test/live.ts` runs
the real model once with a fake `pay`.

To run your own: create a D1 database, put its id in `wrangler.jsonc`, apply `schema.sql`, set the secrets, open a
permit for your agent's key ([docs/integrate.md](../docs/integrate.md)), point `SHOW_PERMIT` in
[src/chain.ts](src/chain.ts) at it, and run `npx wrangler deploy`.

## Addresses

The show's Safe, its current permit and the earlier ones are in
[deployments/robinhood.json](../deployments/robinhood.json).

MIT, like the rest of the repo.
