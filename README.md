# CronBond

Permissionless bonded scheduled-execution registry on Base.

**Live:** https://bafybeie2hrgqdscsk5whxyfgoxlwkm5dpslgbdcmdas5ethhx73dn64vwe.ipfs.community.bgipfs.com/

## What It Does

CronBond lets anyone schedule a future contract call by bonding USDC. A keeper network executes the call at the scheduled time and earns the bond minus a small protocol fee. Use cases: vesting drips, treasury buybacks, subscription billing, auction settlement — built once, composed everywhere.

## Contracts

| Contract | Address | Chain |
|---|---|---|
| CronBond | [`0x13F4a48577899cd395bAc452a56bC3F8C9104383`](https://basescan.org/address/0x13F4a48577899cd395bAc452a56bC3F8C9104383) | Base |

- **USDC:** `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Base)
- **PROTOCOL_FEE_RECEIVER / Owner:** `0x8E9a2fa876CD2626F1CA2676132Fe638DE4ac3F1` (Safe on Base)
- **Verified on Basescan:** ✅

## Frontend Pages

| Page | Description |
|---|---|
| `/` | My Jobs — your registered jobs with cancel / reclaim actions |
| `/create` | Create Job — schedule a future call with USDC bond |
| `/keepers` | Keeper Queue — executable jobs sortable by bond size |
| `/stats` | Stats — protocol totals, leaderboards, recent activity |

## Default Parameters

| Parameter | Value |
|---|---|
| Min Bond | $1.00 USDC |
| Protocol Fee | 0.10% |
| Cancellation Fee | 5% (min $0.05) |
| Stale Window | 7 days after executeAt |
| Min Delay | 120 seconds |
| Max Delay | ~5 years |

## Owner Actions Required

The owner is the Safe wallet `0x8E9a2fa876CD2626F1CA2676132Fe638DE4ac3F1`. Ownership uses Ownable2Step — **the Safe must call `acceptOwnership()` on the CronBond contract** to finalize ownership transfer. Until accepted, the deployer retains owner privileges.

Owner can configure: `setMinBond`, `setProtocolFeeBps`, `setCancellationFeeBps`, `setCancellationFeeFloor`, `setStaleWindow`, `setMinDelay`, `setMaxDelay`, `pause`/`unpause`.

`withdrawProtocolFees()` is permissionless and always sends to the immutable `PROTOCOL_FEE_RECEIVER`.

## Development

```bash
# Install
yarn install

# Local development (fork Base)
yarn fork --network base   # Terminal 1
yarn deploy                # Terminal 2
yarn start                 # Terminal 3

# Tests (50 tests: unit + invariant + fuzz)
cd packages/foundry && forge test -vv

# Build for IPFS
cd packages/nextjs
NODE_OPTIONS="--require ./polyfill-localstorage.cjs" \
  NEXT_PUBLIC_IPFS_BUILD=true \
  yarn build
```

## Architecture

Single contract: `packages/foundry/contracts/CronBond.sol`

- `register(target, callData, executeAt, bondAmount, maxGas)` — bonds USDC, creates a job
- `execute(jobId)` — callable after executeAt; keeper earns bond minus fee (pull pattern)
- `cancel(jobId)` — registrant cancels before the lock window; partial refund
- `reclaimStale(jobId)` — registrant reclaims 7 days after executeAt if nobody executed
- `withdraw()` — pull USDC from pendingWithdrawals
- `withdrawProtocolFees()` — permissionless fee sweep to immutable receiver

## GitHub

https://github.com/clawdbotatg/leftclaw-service-job-127
