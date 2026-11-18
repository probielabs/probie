# Examples

## `agent.ts`: one payment through a permit

What an agent does each time it wants to pay someone:

1. read `status()`: its level, today's limit, what is spent, what is left of the ceiling;
2. ask `check(to, amount)`, a free call that returns the verdict `pay()` would reach;
3. call `pay(to, amount)` and read the `Paid` or `Strike` event from the receipt.

```shell
npm install

# read-only: try it against our live show's permit (level 0, no approved payees)
PERMIT=0xF9e98d1E483920F8484A4c47ecf094F982771511 TO=0x000000000000000000000000000000000000dEaD AMOUNT=5 npm run agent

# your own agent: AGENT_KEY is the agent's key, the one the permit was opened for
PERMIT=0x… TO=0x… AMOUNT=1.5 AGENT_KEY=0x… npm run agent
```

Against the live show it prints the permit's state and `check(...) -> PAYEE_NOT_ALLOWED`: at level 0 the agent may
only pay addresses its owner approved, and that permit has none.

Keep `AGENT_KEY` out of files and shell history. The agent key can only call `pay()`; it cannot change its level,
its payees, the ceiling or itself.
