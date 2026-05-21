## What
<!-- 1-3 lines: what this PR changes. -->

## Why
<!-- The motivation: bug, feature, audit finding, refactor. Link issue / ticket. -->

## How
<!-- Key design choices. Storage layout impact. Cross-contract effects. -->

## Test plan
- [ ] `forge fmt --check` passes
- [ ] `forge build --sizes` passes
- [ ] `forge test -vvv` passes
- [ ] New tests added for new behavior
- [ ] Edge cases covered (zero values, max values, revert paths)
- [ ] Slither produces no new medium/high findings

## Security checklist (smart-contract PRs)
- [ ] No new external calls without reentrancy protection
- [ ] No new `delegatecall` / assembly without explicit justification
- [ ] No storage layout changes to upgradeable contracts (or migration documented)
- [ ] Access control reviewed (owner / role / modifier)
- [ ] Events emitted for all state changes
- [ ] No hard-coded addresses, magic numbers, or unchecked oracle reads

## Deployment impact
<!-- Mainnet / testnet effects, migration steps, rollback plan. Leave "none" if pure refactor. -->

## Risks
<!-- What could break? What's mitigated, what's residual? -->
