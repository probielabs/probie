# Integrate Probie

## For Safe owners: give your agent a permit

A permit is opened by your Safe itself, in one Safe transaction that runs four calls as a batch (a delegatecall to
`MultiSendCallOnly.multiSend`):

1. `safe.enableModule(AllowanceModule)`, skipped when the Safe already runs the module;
2. `factory.create(agent, startLevel, payees, salt)`: the Safe is `msg.sender`, so the permit belongs to it;
3. `AllowanceModule.addDelegate(permit)`, with `permit = factory.predict(safe, salt)`;
4. `AllowanceModule.setAllowance(permit, USDG, ceiling, 1440, resetBaseMin)`.

| Parameter | What to pass |
|---|---|
| `agent` | Your agent's address. The agent needs a little ETH for gas. |
| `startLevel` | 0, 1 or 2. |
| `payees` | The addresses the agent may pay from day one. It can be empty. |
| `salt` | Any `bytes32`. `factory.predict(safe, salt)` returns the permit's address before it exists. |
| `ceiling` | The most the agent may move per UTC day, in USDG with 6 decimals (`30000000` is $30). |
| `resetBaseMin` | Today's UTC midnight in minutes (`floor(now / 86400) * 1440`). With `resetTimeMin` 1440, the ceiling resets every UTC day. |

`script/ProbieSetup.sol` builds this batch and `script/SetupDemo.s.sol` runs it for a 1-of-1 Safe owned by a key.
Any tool that can sign a Safe transaction can send the same four calls.

The addresses are in [`deployments/robinhood.json`](../deployments/robinhood.json).

## For agents: pay through the permit

```solidity
interface IProbiePermit {
    function check(address to, uint256 amount) external view returns (uint8);
    function pay(address to, uint256 amount) external returns (bool);
}
```

1. Call `check(to, amount)` first. It is free, and it returns the verdict `pay()` would reach: `0` means the payment
   goes through, `1` to `5` are the strike reasons, `6` means frozen.
2. Call `pay(to, amount)` from the agent's key. It returns `true` and emits `Paid`, or returns `false` and emits
   `Strike`.
3. A careful agent stops on anything but `0`. An agent that has been talked into paying someone will still be
   stopped by the permit; the attempt is recorded, and nothing moves.

[`examples/agent.ts`](../examples/agent.ts) does all three with viem.

## For dashboards: read a permit

- `factory.PermitCreated(safe, permit, agent, startLevel)` lists every permit.
- On each permit: `Paid(to, amount, level, newPayee)`, `Strike(to, amount, reason, level, strikes)`,
  `LevelChanged(from, to)`, `PayeeSet(payee, approved)`, `FrozenSet(frozen)` and `AgentSet(agent)`.
- `status()` returns the level, clean days, days to the next level, the daily limit, spent today, the new-payee cap
  and spend, what is left of the ceiling, the end of a new-payee pause, the strike count, and whether it is frozen.

The factory accepts any caller as the Safe, so a contract that only pretends to be a Safe can open a permit whose
`Paid` events move nothing. Funds are never at risk, but a board should only show real Safes. The checks that tell
them apart are in the README, under "Board indexing".
