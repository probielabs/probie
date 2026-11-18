# Security

## Scope

`src/ProbiePermit.sol` and `src/ProbieFactory.sol`, as deployed on Robinhood Chain. The addresses are in
[`deployments/robinhood.json`](deployments/robinhood.json).

## The hard cap

The owner's AllowanceModule allowance (the ceiling) limits what a permit can move per UTC day. That check lives in
Safe's audited AllowanceModule, not in Probie's code, so a bug in Probie can at worst spend up to the ceiling. Set the
ceiling to what you can lose in a day.

## Status

Probie's own contracts have not had an external audit. They are covered by unit, integration, fuzz and invariant
tests against the real Safe 1.4.1 contracts and the exact AllowanceModule 0.1.1 source, plus a fork test against
the live deployment. See `test/`.

## Known limits

- **Transfer nonce.** The AllowanceModule keeps a `uint16` nonce per (Safe, delegate, token). Plan on 65,534
  transfers per permit, then open a new permit and move the ceiling to it.
- **Fake Safes.** The factory accepts any caller as the Safe. A contract that only pretends to be a Safe can open a
  permit whose `Paid` events move nothing. No funds are at risk; dashboards should filter as the README describes.

## Reporting a vulnerability

Please don't open a public issue. Send a direct message to [@ProbieLabs](https://x.com/ProbieLabs) on X with a
description and, if you can, a Foundry test that reproduces it. We aim to answer within 48 hours.
