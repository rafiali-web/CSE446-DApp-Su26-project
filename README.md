# BountyPulse - Decentralized Micro-Bounty & Escrow

## Table of contents

1. [Demo](#demo)
2. [Architecture](#architecture)
3. [Specification → implementation map](#specification--implementation-map)
4. [Prerequisites](#prerequisites)
5. [Quickstart](#quickstart)
6. [Sudo commands](#sudo-commands)
7. [Running the chain and deploying](#running-the-chain-and-deploying)
8. [MetaMask setup](#metamask-setup)
9. [Pinata setup](#pinata-setup)
10. [Design system](#design-system)
11. [Using the DApp](#using-the-dapp)
12. [The five checkpoints and how to demo them](#the-five-checkpoints-and-how-to-demo-them)
13. [Contract API reference](#contract-api-reference)
14. [Tests](#tests)
15. [Gas notes and the off-chain sorting decision](#gas-notes-and-the-off-chain-sorting-decision)
16. [Security notes](#security-notes)
17. [Troubleshooting](#troubleshooting)
18. [Project structure](#project-structure)
19. [Collaborator fork](#collaborator-fork)

---

## Demo

Screenshots live in [`images/`](images/). Drop a capture in with the filename below and it
renders here automatically — see [`images/README.md`](images/README.md) for the shot list and
the naming contract.

### Registration and role selection

![BountyPulse registration card, showing the display-name field, the Client and Freelancer
role choice, and the avatar file picker with an image selected](images/01-registration.png)

Registration is permanent: one address, one account, one role. The avatar is pinned to IPFS
first and only the returned CID is written on-chain.

### Client dashboard

![Client dashboard with the post-a-bounty form above a list of the client's own bounties](images/02-client-dashboard.png)

### Bounty feed with off-chain sorting

![Freelancer bounty feed with the sort control and the status segmented control, annotated
off-chain, 0 gas](images/03-bounty-feed-sorting.png)

Every sort and filter runs in the browser on data already fetched by a single free `view`
call. See [Gas notes](#gas-notes-and-the-off-chain-sorting-decision).

### Bid list

![A bounty card expanded to its quotes table, several bids listed cheapest first](images/04-bid-list.png)

### Escrow funding in MetaMask

![MetaMask confirmation dialog for fundEscrow showing the ETH value, over the DApp](images/05-escrow-funding-metamask.png)

### Work submission with IPFS upload

![Awarded work card mid-submission with a file chosen and a toast showing the returned IPFS
CID](images/06-work-submission-ipfs.png)

### Arbiter dispute panel

![Arbiter panel showing the platform totals table and an open dispute with both verdict
buttons](images/07-arbiter-disputes.png)

### Unclaimed earnings and claiming

![Sidebar earnings tracker showing a non-zero unclaimed balance with the Claim button
enabled](images/08-unclaimed-earnings.png)

Payouts are credited to a withdrawable balance rather than pushed, so a reverting recipient
can never block a settlement. The holder withdraws on demand.

### Live sync across two windows

![Two browser windows side by side on different MetaMask accounts, where an action in the
left window has already updated the right one without a reload](images/09-live-sync-two-windows.png)

The page never calls `window.location.reload()`. Every update arrives through a
`contract.on(...)` listener.

---

## Architecture

Two layers with a deliberate split. Anything large and immutable goes to IPFS; anything
that must be *agreed upon* goes on-chain.

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                                   BROWSER                                     │
│                                                                               │
│   index.html ── design-system/styles.css                                      │
│        │                                                                      │
│        ├── js/icons.js         vendored Lucide geometry                        │
│        ├── js/contract.js      ABI + enums + address resolution (pure data)    │
│        ├── js/ipfsHelper.js    two-step Pinata pipeline, retry/backoff         │
│        └── js/app.js           wallet · role UI · off-chain sort · event sync  │
│                 │                          │                                   │
│        ┌────────┴────────┐        ┌────────┴─────────┐                         │
│        │  MetaMask       │        │  read provider   │                         │
│        │  (signer)       │        │  (JsonRpc, logs) │                         │
│        └────────┬────────┘        └────────┬─────────┘                         │
└─────────────────┼──────────────────────────┼──────────────────────────────────┘
                  │ transactions             │ eth_call (free) + event logs
                  │                          │
   ┌──────────────▼──────────────────────────▼───────────────┐   ┌──────────────┐
   │            ANVIL — local EVM, chain id 31337            │   │   PINATA     │
   │  ┌───────────────────────────────────────────────────┐  │   │   (IPFS)     │
   │  │              BountyPulse.sol                      │  │   │              │
   │  │                                                   │  │   │  avatars     │
   │  │  Registry     address => User (role, rep, CID)    │  │   │  briefs      │
   │  │  Bounties     id => Bounty (budget, escrow, CID)  │  │   │  work files  │
   │  │  Bids         id => Bid[]  (non-payable quotes)   │  │   └──────▲───────┘
   │  │  Ledger       address => withdrawableBalance      │  │          │
   │  │                                                   │  │          │ HTTP POST
   │  │  ESCROW VAULT: holds ETH, never pushes payouts    │  │          │ returns CID
   │  └───────────────────────────────────────────────────┘  │          │
   └─────────────────────────────────────────────────────────┘   ───────┘
                        ▲                                          only the 46-char
                        └── stores CIDs only, never file bytes ────── CID goes on-chain
```

### Bounty lifecycle

```
                 postBounty()                fundEscrow()  [payable, exact]
   (none) ───────────────────────► Open ────────────────────────► Locked
                                    │                                │
                              placeBid() × n                    submitWork()
                              (non-payable)                          │
                                                                     ▼
                                                                 Submitted
                                                                     │
                            ┌────────────────────────────────────────┤
                            │ approveWork()                          │ raiseDispute()
                            ▼                                        ▼
                        Resolved ◄──────────────────────────────  Disputed
                     freelancer +98%                                 │
                     arbiter    +2%                                  │ resolveDispute()
                     reputation +15                     ┌────────────┴────────────┐
                                                        │ ClientFault             │ FreelancerFault
                                                        ▼                         ▼
                                                    Resolved                  Refunded
                                              freelancer +98%            client +100%
                                              arbiter    +2%             reputation −30
                                              reputation unchanged

   Money never leaves on approval. It is credited to withdrawableBalance and pulled
   out later with claimFunds() — the pull-payment pattern.
```

---

## Specification → implementation map

| # | Requirement | Where it lives | Verified by |
|---|---|---|---|
| 2.1 | Arbiter = contract deployer | `constructor`, `immutable arbiter` | `test_Deployment_RegistersDeployerAsArbiter` |
| 2.1 | Arbiter resolves disputes, collects fees | `resolveDispute`, `_credit(arbiter, fee)` | `test_ResolveDispute_*`, `test_ClaimFunds_ArbiterWithdrawsAccumulatedFees` |
| 2.1 | Register with Name, Role, `ipfsAvatarHash` | `registerUser(string,Role,string)` | `test_RegisterUser_Client` |
| 2.1 | Contract is the sole registry | `_users`, `_registeredUsers` | `test_RegisterUser_EnumeratesRegistry` |
| 2.1 | **An address cannot register twice** | `AlreadyRegistered` guard | `test_RegisterUser_RevertWhen_AlreadyRegistered` |
| 2.1 | Freelancers start at **100 reputation** | `INITIAL_REPUTATION` | `test_RegisterUser_FreelancerStartsWith100Reputation` |
| 2.2.1 | Client posts bounty: Max Budget (wei) + details CID | `postBounty(uint256,string)` | `test_PostBounty_CreatesOpenBountyWithoutMovingEth` |
| 2.2.1 | Initial status `Open` | `BountyStatus.Open` | same |
| 2.2.2 | Freelancer submits a price quote | `placeBid(uint256,uint256)` | `test_PlaceBid_StoresQuote` |
| 2.2.2 | **Must be non-payable** | no `payable` keyword | `test_PlaceBid_IsNonPayable` |
| 2.2.2 | Budget ceiling | `BidExceedsBudget` | `test_PlaceBid_RevertWhen_BidExceedsMaxBudget`, fuzz |
| 2.2.2 | Reputation gate: below 40 cannot bid | `MIN_BID_REPUTATION` | `test_ReputationGate_RevertWhen_Below40`, `..._AtExactly40_CanStillBid` |
| 2.2.3 | Funding is `payable` | `fundEscrow(uint256,address) payable` | `test_FundEscrow_ExactAmount_*` |
| 2.2.3 | **Underpayment reverts entirely** | `InsufficientEscrowPayment` | `test_FundEscrow_RevertWhen_UnderpaidByOneWei`, fuzz |
| 2.2.3 | **Overpayment: keep exact bid, refund excess same tx** | `_refundOrCredit(msg.sender, excess)` | `test_FundEscrow_Overpayment_RefundsExcessInSameTransaction`, fuzz |
| 2.2.3 | Status → `Locked` | `_setStatus` | same |
| 2.2.4 | Freelancer submits `ipfsWorkFileHash` | `submitWork(uint256,string)` | `test_SubmitWork_StoresCidAndAdvancesStatus` |
| 2.2.4 | Client approves | `approveWork(uint256)` | `test_ApproveWork_*` |
| 2.2.4 | **2% fee to the Arbiter** | `previewFeeSplit`, `PLATFORM_FEE_BPS = 200` | `test_ApproveWork_Splits2PercentFeeAndCreditsBalances`, fuzz |
| 2.2.4 | **Pull payment — do not auto-send 98%** | `withdrawableBalance` mapping | same test asserts wallet balances are unchanged |
| 2.2.4 | Reputation **+15**, status → `Resolved` | `_increaseReputation` | `test_ApproveWork_IncreasesReputationBy15` |
| 2.2.5 | `claimFunds` for Freelancer / Arbiter | `claimFunds()` | `test_ClaimFunds_*` |
| 2.2.6 | Client marks `Disputed` | `raiseDispute(uint256)` | `test_RaiseDispute_*` |
| 2.2.6 | **Outcome A**: 100% refund + **−30** reputation | `DisputeOutcome.FreelancerFault` | `test_ResolveDispute_FreelancerFault_RefundsFullEscrowAndPenalises` |
| 2.2.6 | **Outcome B**: freelancer paid minus 2% | `DisputeOutcome.ClientFault` | `test_ResolveDispute_ClientFault_PaysFreelancerMinusFee` |
| 3.1 | Auto-detect MetaMask address on load, **no address inputs** | `Wallet.detectAccount()` (`eth_accounts`) | manual — checkpoint 1 |
| 3.1 | Role-based dashboard from the on-chain registry | `Render.all()` → `panel-client/freelancer/arbiter` | manual |
| 3.1 | `accountsChanged` switches the UI instantly | `bindWalletEvents()` | manual |
| 3.2 | Fetch bounties + bids dynamically | `Chain.loadBounties()` | `test_Views_ReturnFullFeedForClientSideSorting` |
| 3.2 | **Sort/filter off-chain (gas optimization)** | `Feed.sort` / `Feed.filter` | see [gas notes](#gas-notes-and-the-off-chain-sorting-decision) |
| 3.3 | Two-step IPFS pipeline | `ipfsHelper.js` → `uploadFile`/`uploadJson` then contract call | manual — checkpoint 3 |
| 3.3 | Render via `gateway.pinata.cloud/ipfs/<CID>` | `Ipfs.gatewayUrl()` | manual |
| 3.4 | "Unclaimed Earnings" tracker | `#earnings-card`, `Render.earnings()` | manual |
| 3.4 | "Claim Funds" button → MetaMask | `Actions.claimFunds()` | manual — checkpoint 4 |
| 3.5 | Reactive UI via `contract.on(...)` | `EventSync.attach()` | manual — checkpoint 5 |
| 3.5 | **No `window.location.reload()`** | not present anywhere — `grep` to confirm | `grep -rn "location.reload" frontend/` → no matches |

---

## Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| `git`, `curl`, `unzip`, a C compiler | Foundry install | present on most systems |
| **Foundry** (`forge`, `anvil`, `cast`) | contracts | **installed by `setup.sh`** — no sudo |
| Node.js ≥ 18 + npm | vendoring ethers.js, script aliases | optional; the contracts build without it |
| `python3` | the static file server | any 3.x |
| `jq` | ABI extraction in `deploy-local.sh` | required for the frontend sync step |
| MetaMask | signing transactions | browser extension |
| A Pinata account | IPFS pinning | free tier is enough |

Verified on Ubuntu 24.04.4 LTS, zsh, git 2.43.0, node v22.18.0, npm 10.9.4, python3 3.12.3,
jq 1.7, Foundry 1.7.1 (solc 0.8.20).

---

## Quickstart

```bash
./setup.sh
```

That single command is idempotent and safe to re-run. It will:

1. detect your OS, distro and package manager;
2. check system prerequisites and **print** (never run) any command needing root;
3. install Foundry for the current user into `~/.foundry`, then run `foundryup`;
4. append a guarded `PATH` line to `~/.bashrc` and `~/.zshrc` — only if not already there;
5. install `forge-std` (preferring `--no-git`, so no submodule is created);
6. run `forge build` and `forge test`;
7. create `.env` from `.env.example` **only if `.env` does not already exist**;
8. `chmod +x` the helper scripts;
9. print the sudo block and a next-steps summary.

```
./setup.sh --help          # options
./setup.sh --skip-foundry  # leave the toolchain alone
./setup.sh --skip-tests    # build but do not test
```

> `setup.sh` never runs `sudo`, never overwrites `.env`, and touches nothing outside this
> repo, `~/.foundry` and the two shell rc files.

---

## Sudo commands

**On the verified machine: none.** `git`, `curl`, `unzip`, `cc` and `python3` were all
already present, so `setup.sh` reports:

```
================================================================================
  SUDO COMMANDS
================================================================================
  Nothing needed. Every prerequisite is already installed on this machine.
```

If something *is* missing, `setup.sh` detects it and prints the exact commands for you to
review and run yourself. On a Debian/Ubuntu machine those would be:

```bash
sudo apt-get update
sudo apt-get install -y git curl unzip build-essential python3
```

And, only if Node.js is absent:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Equivalent lines are generated automatically for `dnf`, `pacman` and `brew`.

---

## Running the chain and deploying

Three terminals.

```bash
# Terminal 1 — local EVM chain, prints 10 pre-funded accounts
./scripts/start-anvil.sh

# Terminal 2 — compile, deploy, sync the ABI + address into the frontend
./scripts/deploy-local.sh

# Terminal 3 — serve the DApp over http://
./scripts/serve-frontend.sh          # http://127.0.0.1:8080
```

`deploy-local.sh` output (real run):

```
==> Checking the chain is reachable
  +  Chain id 31337 at block 0
==> Deploying BountyPulse
  Contract address : 0x5FbDB2315678afecb367f032d93F642f64180aa3
  Chain id         : 31337
  Deployer/Arbiter : 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  Runtime bytecode : 14111 bytes
  Platform fee     : 200 bps (2%)
==> Reading back the deployment
  +  Verified on-chain: arbiter() = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, runtime code = 14111 bytes
==> Syncing the ABI and address into the frontend
  +  Wrote frontend/js/contract-address.js (19329 bytes, ABI inlined)
```

**Deployment gas: `3,309,007`.** The address does not need to be copied anywhere —
`deploy-local.sh` writes `frontend/js/contract-address.js` (git-ignored) with the address,
chain id and the exact ABI, and the DApp picks it up automatically.

> Anvil keeps state in memory. **Every anvil restart requires re-running
> `./scripts/deploy-local.sh`.**

Useful flags:

```bash
./scripts/start-anvil.sh --block-time 2      # realistic block cadence
./scripts/deploy-local.sh --gas-report       # deploy, then print the gas table
./scripts/serve-frontend.sh --port 9000 --open
```

---

## MetaMask setup

**1. Add the network** (or click *Switch to Anvil* in the DApp banner, which does it for you):

| Field | Value |
|---|---|
| Network name | `Anvil Local` |
| RPC URL | `http://127.0.0.1:8545` |
| Chain ID | `31337` |
| Currency symbol | `ETH` |

**2. Import the pre-funded test accounts.** Anvil prints ten accounts with 10000 ETH each on
startup. In MetaMask: *Account menu → Import account → Private Key*.

| # | Address | Role in the demo |
|---|---|---|
| 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | deployer → **Arbiter** |
| 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | **Client** |
| 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | **Freelancer** |

Private keys are printed by `start-anvil.sh` in terminal 1. They are the standard, publicly
documented Anvil development keys — **never** send real funds to them.

**3. Reset the nonce after restarting anvil.** MetaMask caches nonces per account. When the
chain restarts at block 0, go to *Settings → Advanced → Clear activity tab data*, otherwise
transactions fail with a nonce error.

### The "network name may not match this chain ID" notice

When you add chain `31337` manually, MetaMask shows something like:

> According to our records, this network name may not correctly match this chain ID.
> The network name does not match the chain ID.

and usually a matching notice about the currency symbol. **This is expected here, it is not an
error, and nothing is wrong with the deployment.**

**Why it appears.** MetaMask validates the name and symbol you type against a public registry
of known chain IDs ([chainid.network](https://chainid.network)). In that registry, chain ID
`31337` is assigned to **GoChain testnet**, whose symbol is `GO`. Anvil also uses `31337` as
its default local chain ID. The two collide, so typing "Anvil Local" and `ETH` disagrees with
what the registry expects and MetaMask says so. It is comparing your labels to a directory
entry, not checking the chain.

**`ETH` is the correct symbol.** Anvil's native currency genuinely is Ether with 18 decimals.
Balances, `msg.value`, and every gas calculation are denominated in wei exactly as on Ethereum.
Labelling it `GO` would be the inaccurate choice; it would just happen to match the registry.

**Your two options** — both purely cosmetic, neither changes anything on-chain:

| Option | What happens |
|---|---|
| **Dismiss the notice** (recommended) | Keep `Anvil Local` and `ETH`. The warning is informational; the network is added and works. |
| **Accept MetaMask's suggestions** | Let it relabel the network `GoChain testnet` with symbol `GO`. This changes display strings in MetaMask only. The RPC endpoint, chain ID, balances and transactions are identical. |

The in-app *Switch to Anvil* button avoids the typing entirely — it calls
`wallet_addEthereumChain` with the correct parameters (verified in
`frontend/js/app.js` → `Wallet.switchToLocalChain`):

| Parameter | Value |
|---|---|
| `chainId` | `0x7a69` (31337) |
| `nativeCurrency` | `{ name: "Ether", symbol: "ETH", decimals: 18 }` |
| `rpcUrls` | `["http://127.0.0.1:8545"]` |
| `blockExplorerUrls` | `[]` — a local chain has no explorer, and pointing at a real one would be a lie |

MetaMask may still show the same registry notice for the same reason. It is safe to accept.

> **Do not treat this warning class as noise in general.** It exists to catch token-symbol
> spoofing — a malicious site adding a network that claims to be Ethereum mainnet, or a token
> that claims to be `USDC` when it is not. Dismissing it is fine **here**, on a local chain you
> started yourself, on an RPC pointing at `127.0.0.1`. On any public network, read it.

---

## Pinata setup

**Set it once, in `.env`.** The scripts bridge it into the page for you.

1. Create a free key at <https://app.pinata.cloud/developers/api-keys>.
2. Put it in `.env` (git-ignored, and never overwritten by `setup.sh`):

   ```dotenv
   PINATA_JWT=eyJhbGciOi...
   # Optional fallback, used only when PINATA_JWT is empty:
   PINATA_API_KEY=
   PINATA_API_SECRET=
   # Optional dedicated read gateway:
   PINATA_GATEWAY=https://gateway.pinata.cloud/ipfs/
   ```

3. Run `./scripts/serve-frontend.sh` (or `./scripts/deploy-local.sh`). Either one calls
   `scripts/gen-pinata-config.sh`, which reads `.env` and writes
   `frontend/js/pinata-config.js` — a generated, git-ignored, `chmod 600` file that the page
   loads before `ipfsHelper.js`.
4. Open the DApp. The **IPFS / Pinata** panel reports the active source and the credential's
   length, for example `source: env — JWT active, 689 characters`. No pasting required.

### How the credential is resolved

A browser cannot read `.env`; there is no server to read it. That is exactly the gap
`gen-pinata-config.sh` closes. Resolution order in `frontend/js/ipfsHelper.js`, highest first:

| Precedence | Source | Where it comes from |
|---|---|---|
| 1 | `localStorage` | Typed into the DApp's IPFS / Pinata panel. A per-browser override. |
| 2 | `env` | `window.BOUNTYPULSE_PINATA`, generated from `.env`. |
| 3 | none | Uploads are refused up front with an actionable message. |

The whole `localStorage` layer outranks the whole `env` layer: an override that a file could
silently beat is not an override. Within a layer the JWT wins over the legacy pair. Pressing
*Clear* removes only the browser copy and falls back to `.env`, which the panel tells you.

Two authentication styles are supported, matching the two sets of variables:

* **JWT (preferred)** — sent as `Authorization: Bearer <jwt>`. One secret, scopeable.
* **Legacy API key + secret** — sent as the `pinata_api_key` / `pinata_secret_api_key`
  headers. Requires **both** halves; a lone half is ignored with a warning.

`PINATA_GATEWAY` is normalised, so `https://x.mypinata.cloud`, `.../`, `.../ipfs` and
`.../ipfs/` all work. A value that is not `http(s)` is rejected and the public gateway is used
instead, rather than breaking every image on the page.

### The security caveat

`frontend/js/pinata-config.js` contains the credential in plaintext and is served to the
browser, so anyone who can load the page can read it. It is `chmod 600` and git-ignored so it
cannot be committed, and the panel and logs only ever report the source and the character
length — never the value. Delete the file when you are finished.

To move the secret server-side, point `PINATA_API` in `ipfsHelper.js` at your own authenticated
proxy and drop the `Authorization` header; every call site stays identical.

---

## Design system

The interface is built on a single design system, **Classical**, which lives in two files:

| File | What it is |
|---|---|
| [`frontend/design-system/styles.css`](frontend/design-system/styles.css) | The one stylesheet: `:root` token sheet, the tonal ramps, base typography, and the component layer. Every page links this and nothing else. |
| [`frontend/design-system/theme.json`](frontend/design-system/theme.json) | The machine-readable record of exactly the same parameters, including the generation settings for the ramps and a contrast audit. |

### Direction

Editorial and book-like on a soft near-white ground. Justified body copy at a comfortable
measure, headlines flush-left over the block, and hairline rules carrying the structure.
Surfaces stay quiet: cards are bordered, buttons outlined, photographs matted like plates
tipped into a book.

### Tokens

Anchors are `--color-bg` `#f3f2f2`, `--color-text` `#201f1d`, and a single accent `#b68235`.

Every role carries a 100–900 tonal ramp — `--color-neutral-*`, `--color-accent-*`,
`--color-accent-2-*` — generated in **OKLCH on one shared perceptual lightness scale**, so
step 500 of any ramp has the same visual weight as step 500 of any other. Step 500 is pinned
to the accent's own OKLCH lightness (`0.6443`).

* **100–300** tinted fills, hovers, subtle borders
* **500** the role base
* **700–900** text on tinted fills, pressed states

Prefer a ramp step over an ad-hoc `color-mix()`.

The scheme is **mono**: there is exactly one accent. `--color-accent-2-*` is a machine-derived
stand-in — the accent's hue nudged `+6°` at `0.86` chroma — kept only so that both sets
resolve. Treat accent and accent-2 as one role.

Spacing and radius are scales, not raw values: `--space-1` … `--space-16` at a 4px base and
1.15 density (one step is 4.6px), and `--radius-sm/md/lg/xl/pill` on a 4px base. Elevation is
`--shadow-sm/md/lg` only, and it is a whisper.

### Type

Cormorant Garamond headings over Lora body, as `--font-heading` / `--font-body`, both with
real fallback stacks so the page degrades to a serif offline rather than collapsing.

**Bold is avoided.** Interface headings cap at semibold (`--font-heading-weight`, 600), and
the bigger the text the lighter it sets — display sizes take the normal cut (400). Emphasis is
carried by weight 500 and by italics, never by a sans-serif.

Numbers set tabular (`font-feature-settings: "tnum"`) wherever they stand as figures or
columns: kickers, contents numerals, tables, metrics. Running prose keeps its text figures,
because Lora's tabular feature widens word spaces and punctuation and would loosen a justified
paragraph.

### The two rules that shape everything

1. **Stroke, not fill.** Colour appears as borders, rules and underlines. `.btn-primary` is an
   accent *outline*; no component takes a solid accent fill.
2. **Contrast.** The accent-to-ground pair measures **3.02:1** — enough for icons, large text
   and interface chrome, and **not** enough for body copy. Paragraph-size text in the accent
   uses `--color-accent-700` (**5.97:1**). Both are recorded in `theme.json`'s contrast audit.

### Component classes

Build with these; do not add parallel classes.

| Class | What it is |
|---|---|
| `.btn` + `.btn-primary`, `.btn-secondary`, `.btn-ghost`, `.btn-icon`, `.btn-block` | Actions. Primary is an accent outline, never a fill. |
| `.tag` + `.tag-accent`, `.tag-accent-2`, `.tag-neutral`, `.tag-outline` | Small labels tinted from the ramps. |
| `.field` + `label`, `.input`, `.radio` + `.dot`, `.seg` + `.seg-opt` | Form fields and choices, on native elements, with no script. |
| `.card` + `.card-kicker`, `.card-title`, `.card-body`, `.card-meta`; `.elev-sm/md/lg` | Bordered, unfilled surfaces plus elevation utilities. |
| `.nav` + `.nav-brand` | Header bar. |
| `.table` | Data tables with a themed header and row rules. |
| `.dialog-backdrop` + `.dialog` (`.dialog-title/-body/-actions`) | Modal at top elevation. |
| `.hr` | Hairline rule. |
| `.plate` | Image mat — a warm archival grade inside a thin surface-coloured mat. Every content photograph goes through it. |

### Interaction states

Themed once at the system level, never per page. Every interactive element gets a hover tint
and a pressed state one step past the base on the accent ramp (`--color-accent-600` on this
light ground, `--color-accent-400` on dark, a `color-mix()` tint for outlined and ghost
variants that have no fill to darken). Keyboard focus is
`:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; }` — never the
default blue ring. `::selection` is an accent tint, and disabled controls drop to 45% opacity.

### Icons

[Lucide](https://lucide.dev), vendored as stroke SVG in
[`frontend/js/icons.js`](frontend/js/icons.js) so the DApp keeps its icons offline. Presentation
comes from `.icon` in the stylesheet; the file holds geometry only. **There are no emoji
anywhere in this project.**

### Retheming

Change the anchors in the `:root` block at the top of `styles.css`, regenerate the ramps on
the same shared lightness scale, and mirror both into `theme.json` — the two files describe
the same parameters and must move together. Re-check the contrast audit afterwards: the
3:1 accent-on-ground and 4.5:1 accent-700-on-ground floors are the constraints that keep the
scheme legible.

**Not built:** the design-system documentation microsite (`foundations/*.html`,
`components/*.html`, `templates/`, `thumbnail.html`) is a separate deliverable and is not part
of this repository.

---

## Using the DApp

Open <http://127.0.0.1:8080>. The page detects your MetaMask account **without prompting**
(`eth_accounts`), reads your role from the on-chain registry, and renders the matching
dashboard. There is no field anywhere for typing a wallet address.

### First run — register

Enter a display name, choose **Client** or **Freelancer**, and pick an avatar image. On
submit the DApp performs the two-step pipeline: it pins the image to IPFS, shows you the CID,
then asks MetaMask to sign `registerUser(name, role, cid)` with only that CID.

*The Arbiter role is not selectable.* It belongs permanently to whoever deployed the
contract.

### Client

* **Post a bounty** — title, description, max budget in ETH, optional attachment. The brief
  is pinned as a JSON document; the chain receives the CID and the budget in wei.
* **Review quotes** — each bid shows the freelancer and their price, cheapest first.
* **Fund escrow** — the amount field is pre-filled with the exact bid.
  * Lower it → the transaction reverts and you keep everything (minus gas).
  * Raise it → the contract keeps the exact bid and refunds the difference in the same
    transaction.
* **Approve** (releases 98% to the freelancer, 2% to the Arbiter) or **Dispute**.

### Freelancer

* **Unclaimed earnings** tracker with a **Claim funds** button (sidebar).
* **Open bounty feed** with client-side sort (highest/lowest budget, newest, oldest, most
  bids), a status filter, and search.
* **Submit a quote** — non-payable; no ETH leaves your wallet. Blocked if your reputation is
  below 40, with the reason shown inline.
* **My awarded work** — attach the deliverable; it is pinned to IPFS and the CID is submitted
  on-chain.

### Arbiter

* Platform stats: bounty count, ETH currently escrowed, settled count, unclaimed fees.
* **Open disputes** with two verdict buttons:
  * *Freelancer at fault* → full refund to the client, reputation −30.
  * *Client at fault* → freelancer credited the escrow minus the 2% fee.
* Unclaimed fee tracker and **Claim funds**.

The **Live activity** panel in the sidebar streams contract events as they arrive, and the
green dot indicates the listeners are attached.

---

## The five checkpoints and how to demo them

### Checkpoint 1 — Environment

```bash
./scripts/start-anvil.sh     # chain id 31337, 10 accounts × 10000 ETH
```

Show MetaMask connected to `31337`, an imported anvil account, and a green *Test* result in
the DApp's Pinata panel.

### Checkpoint 2 — Contract deployment

```bash
./scripts/deploy-local.sh --gas-report
```

Shows the terminal output, the deployed address, gas used (`3,309,007`), the runtime code
size verified by reading it back off the chain, and the full per-function gas table.

Proof of the percentage math and revert logic:

```bash
forge test --match-test "FeeSplit|Underpaid|Overpayment|2Percent" -vv
```

### Checkpoint 3 — IPFS metadata pipeline

Register a user, or post a bounty with an attachment. Watch:

1. the toast *"Avatar pinned · Qm…"* with the returned CID;
2. MetaMask asking to sign a transaction whose argument is that CID;
3. the avatar rendering from `https://gateway.pinata.cloud/ipfs/<CID>`;
4. the browser console's structured log line `ipfs_upload_complete`.

The *Brief* button on any bounty card opens the pinned JSON on the gateway.

### Checkpoint 4 — Feed and escrow flow

As the Freelancer, change **Sort** to *Highest budget* — the feed reorders instantly with no
RPC call (visible in the Network tab: nothing fires). As the Client, fund a bid with the
exact amount, then use **Claim funds** as the Freelancer.

To demonstrate the revert and refund rules live, edit the amount in the fund field:
`0.9` for a `1.0` bid reverts; `1.5` escrows `1.0` and refunds `0.5`.

### Checkpoint 5 — Live event auto-sync

1. Open <http://127.0.0.1:8080> in two windows side by side.
2. Window 1: MetaMask on the **Client** account. Window 2: the **Freelancer** account.
   (Use two browser profiles, or two browsers, so each has its own MetaMask account.)
3. Freelancer submits work in window 2.
4. Client clicks **Approve** in window 1.
5. **Without touching window 2**, its *Unclaimed earnings* jumps to `0.98 ETH`, a toast
   reads *"Earnings updated"*, and the Live activity panel logs *"Work approved on #1"*.

There is no polling loop and no reload — `grep -rn "location.reload" frontend/` returns
nothing.

---

## Contract API reference

### Types

```solidity
enum Role           { Unregistered, Client, Freelancer, Arbiter }
enum BountyStatus   { None, Open, Locked, Submitted, Disputed, Resolved, Refunded }
enum DisputeOutcome { FreelancerFault, ClientFault }
```

### Constants

| Name | Value | Meaning |
|---|---|---|
| `PLATFORM_FEE_BPS` | `200` | 2% protocol fee |
| `BPS_DENOMINATOR` | `10000` | basis-point denominator |
| `INITIAL_REPUTATION` | `100` | starting score for freelancers |
| `MIN_BID_REPUTATION` | `40` | below this, bidding is blocked |
| `REPUTATION_REWARD` | `15` | added on approval |
| `REPUTATION_PENALTY` | `30` | removed on a lost dispute (floors at 0) |

### State-changing functions

| Function | Caller | Effect |
|---|---|---|
| `registerUser(string name, Role role, string avatarCid)` | anyone, once | Creates the profile. Freelancers start at 100 reputation. |
| `postBounty(uint256 maxBudget, string detailsCid) → uint256` | Client | Creates an `Open` bounty. Moves no ETH. |
| `placeBid(uint256 bountyId, uint256 amount)` | Freelancer | **Non-payable** quote. Enforces the budget ceiling and the reputation gate. One bid per freelancer per bounty. |
| `fundEscrow(uint256 bountyId, address freelancer)` **payable** | bounty's Client | Reverts if `msg.value < bid`; refunds the excess if greater. → `Locked`. |
| `submitWork(uint256 bountyId, string workCid)` | awarded Freelancer | → `Submitted`. |
| `approveWork(uint256 bountyId)` | bounty's Client | Credits 98% / 2%, reputation +15, → `Resolved`. Sends no ETH. |
| `raiseDispute(uint256 bountyId)` | bounty's Client | From `Locked` or `Submitted` → `Disputed`. |
| `resolveDispute(uint256 bountyId, DisputeOutcome outcome)` | Arbiter | A: refund client, −30 rep, → `Refunded`. B: credit freelancer 98%, → `Resolved`. |
| `claimFunds() → uint256` | anyone with a balance | Withdraws the caller's entire withdrawable balance. |

### View functions

`arbiter()` · `bountyCount()` · `totalEscrowed()` · `totalWithdrawable()` ·
`totalLiabilities()` · `withdrawableBalance(address)` · `getWithdrawableBalance(address)` ·
`getUser(address)` · `isRegistered(address)` · `getRole(address)` · `getReputation(address)` ·
`canBid(address)` · `getRegisteredUsers()` · `getRegisteredUserCount()` ·
`getBounty(uint256)` · `getAllBounties()` · `getBountiesPaged(uint256,uint256)` ·
`getBids(uint256)` · `getBid(uint256,address)` · `getBidCount(uint256)` ·
`hasBid(uint256,address)` · `previewFeeSplit(uint256) → (fee, payout)`

### Events

Every state change emits at least one event, which is what makes the reload-free UI possible.

| Event | Emitted by |
|---|---|
| `UserRegistered(address indexed user, Role indexed role, string name, string ipfsAvatarHash, uint32 reputation)` | constructor, `registerUser` |
| `BountyPosted(uint256 indexed bountyId, address indexed client, uint256 maxBudget, string ipfsDetailsHash)` | `postBounty` |
| `BidPlaced(uint256 indexed bountyId, address indexed freelancer, uint256 amount, uint256 bidIndex)` | `placeBid` |
| `EscrowFunded(uint256 indexed bountyId, address indexed client, address indexed freelancer, uint256 escrowAmount, uint256 refundedExcess)` | `fundEscrow` |
| `WorkSubmitted(uint256 indexed bountyId, address indexed freelancer, string ipfsWorkFileHash)` | `submitWork` |
| `WorkApproved(uint256 indexed bountyId, address indexed client, address indexed freelancer, uint256 freelancerPayout, uint256 platformFee)` | `approveWork` |
| `DisputeRaised(uint256 indexed bountyId, address indexed client, BountyStatus previousStatus)` | `raiseDispute` |
| `DisputeResolved(uint256 indexed bountyId, address indexed resolvedBy, DisputeOutcome outcome, uint256 clientRefund, uint256 freelancerPayout, uint256 platformFee)` | `resolveDispute` |
| `BountyStatusChanged(uint256 indexed bountyId, BountyStatus previousStatus, BountyStatus newStatus)` | every transition |
| `ReputationChanged(address indexed freelancer, uint32 previousScore, uint32 newScore, int256 delta, string reason)` | approval, lost dispute |
| `BalanceCredited(address indexed account, uint256 amount, uint256 newBalance)` | any credit to the ledger |
| `FundsClaimed(address indexed account, uint256 amount)` | `claimFunds` |
| `DirectRefund(address indexed to, uint256 amount)` | successful in-transaction refund |
| `RefundDeferred(address indexed to, uint256 amount)` | refund that fell back to a claimable balance |

### Custom errors

`AlreadyRegistered` · `NotRegistered` · `InvalidRole` · `ArbiterIsFixedAtDeployment` ·
`EmptyName` · `NameTooLong` · `InvalidCid` · `CallerIsNotClient` · `CallerIsNotFreelancer` ·
`CallerIsNotArbiter` · `NotBountyOwner` · `NotAwardedFreelancer` · `BountyDoesNotExist` ·
`InvalidBountyStatus` · `ZeroBudget` · `ZeroBidAmount` · `BidExceedsBudget` ·
`ReputationTooLow` · `DuplicateBid` · `BidNotFound` · `InsufficientEscrowPayment` ·
`NothingToClaim` · `TransferFailed` · `ReentrantCall` · `DirectPaymentsNotAccepted`

Custom errors are cheaper than revert strings and carry structured arguments. `contract.js`
maps each one to a human-readable sentence — a user sees *"Reputation gate: your score is 10
and bidding requires at least 40"*, not `0x…`.

---

## Tests

```bash
forge test -vv            # full suite
forge test --gas-report   # with the gas table
forge fmt --check         # formatting
```

Real output:

```
Ran 83 tests for test/BountyPulse.t.sol:BountyPulseTest
...
Suite result: ok. 83 passed; 0 failed; 0 skipped; finished in 210.04ms (646.30ms CPU time)

Ran 1 test suite in 232.86ms (210.04ms CPU time): 83 tests passed, 0 failed, 0 skipped (83 total tests)
```

### Coverage by area

| Area | Tests | Highlights |
|---|---|---|
| Deployment & Arbiter | 4 | deployer becomes Arbiter; constructor validation |
| Registry | 12 | duplicate registration, role forgery, name/CID bounds, CIDv0 **and** CIDv1 |
| Post bounty | 7 | access control, zero budget, invalid CID, id sequencing |
| Bidding | 11 | **non-payable proof**, budget ceiling incl. the exact boundary, duplicates, wrong status |
| Reputation gate | 3 | passes at exactly 40, blocks at 10, saturates at 0 without underflow |
| Escrow funding | 8 | exact / under (1 wei) / over, rejecting-recipient fallback, ownership |
| Work submission | 5 | wrong freelancer, wrong status, invalid CID |
| Approval & fee math | 6 | exact 98/2 split, no push transfer, accumulation, `Resolved` |
| Claiming | 5 | exact amounts, double-claim, recipient that rejects ETH |
| Disputes | 8 | both outcomes, ±reputation, access control, double resolution |
| Security | 3 | **reentrancy attack blocked**, bare ETH rejected, unknown selector rejected |
| Views | 3 | full feed, pagination clamping, liabilities tracking |
| End-to-end | 1 | post → bid → fund → submit → approve → claim, fully settled |
| **Fuzz** | **5** | 512 runs each, deterministic seed |

The five fuzz tests:

* `testFuzz_FeeSplit_IsConservative` — for any amount, `fee + payout == amount`, `fee` is
  exactly 2% floored, and the payout is never below 98%.
* `testFuzz_ApproveWork_LedgerReconciles` — end-to-end with fuzzed escrow; balances always
  reconcile to the wei.
* `testFuzz_FundEscrow_RefundsExcessExactly` — for any bid and any overpayment, the client is
  charged exactly the bid.
* `testFuzz_FundEscrow_RevertsOnAnyUnderpayment` — any shortfall reverts and changes nothing.
* `testFuzz_PlaceBid_EnforcesBudgetCeiling` — accepted iff `quote <= budget`.

Every money-moving test also asserts the solvency invariant:

```
address(this).balance >= totalEscrowed + totalWithdrawable
```

### Live-chain verification

Beyond the unit tests, the deployed contract was exercised with `cast` against a running
anvil node: duplicate registration reverted, over-budget bids reverted, `placeBid` rejected a
call carrying ETH, underpayment reverted, a 1.5 ETH payment on a 1 ETH bid cost the client
exactly 1 ETH, approval credited exactly `0.98`/`0.02`, `claimFunds` delivered exactly
`0.98 ETH`, a lost dispute refunded exactly `0.5 ETH` and moved reputation `115 → 85`, and the
contract balance returned to `0` with `totalLiabilities() == 0`.

---

## Gas notes and the off-chain sorting decision

### Measured costs

| Operation | Gas (avg) |
|---|---|
| Deployment | **3,309,007** |
| `registerUser` | 167,861 |
| `postBounty` | 214,906 |
| `placeBid` | 128,187 |
| `fundEscrow` | 92,882 |
| `submitWork` | 105,552 |
| `approveWork` | 118,777 |
| `resolveDispute` | 62,253 |
| `claimFunds` | 35,126 |
| `previewFeeSplit` (pure) | 601 |

Runtime bytecode: **14,111 bytes** (limit 24,576).

### Why sorting happens in the browser

The specification asks for a filter/sort feature that *demonstrates the gas-optimization
principle*. The demonstration is the **absence** of an on-chain sort.

`getAllBounties()` is a `view` function. Called through `eth_call` it executes on the node and
costs the caller **nothing** — no transaction, no gas, no block space. `Feed.sort()` and
`Feed.filter()` in `frontend/js/app.js` then order and filter that array in JavaScript.

The alternative — a `getBountiesSortedByBudget()` that sorts storage — is wrong on three
counts:

1. **Cost.** A sort is O(n log n) comparisons, each reading storage. A cold `SLOAD` is 2,100
   gas. At 200 bounties that is roughly 1,500 comparisons: hundreds of thousands of gas for
   what should be a free read. The same result costs ~0.02 ms in the browser.
2. **Duplication.** Sort order is a presentation concern. Two users wanting different orders
   would each pay to sort identical data. One user changing a dropdown four times would pay
   four times.
3. **Correct layering.** The chain's job is to store, verify and settle. Arranging rows for a
   human to read is the client's job.

The same reasoning applies to the bid list on each card (sorted cheapest-first client-side)
and to the search box. The toolbar carries an `off-chain · 0 gas` label so the property is
visible in the UI, and the rationale is documented at the top of the `Feed` module and above
the view functions in `BountyPulse.sol`.

### Other gas decisions

* **Custom errors** instead of revert strings — no string constants in bytecode.
* **`immutable arbiter`** — read from code, not storage.
* **Packed structs** — `uint32 reputation`, `uint64` timestamps and `bool` share slots.
* **`_bidIndexPlusOne`** — O(1) bid lookup; the `+1` offset lets `0` mean "no bid" without a
  second storage read.
* **Pull payments** — one transfer per claim rather than a push per settlement, and no gas
  griefing from recipient fallbacks.
* **Optimizer at 200 runs** — favours cheaper runtime calls over cheaper deployment, correct
  for a deploy-once/call-many contract.

---

## Security notes

### In the contract

* **Checks-Effects-Interactions everywhere.** Every state mutation completes before any ETH
  moves. `approveWork` makes no external call at all.
* **Reentrancy guard** on every function that moves value (`fundEscrow`, `resolveDispute`,
  `claimFunds`). `test_Security_ClaimFundsIsReentrancySafe` runs an actual attacking contract
  that re-enters from its `receive` hook and proves it is paid exactly once.
* **Pull payments.** The contract never depends on a recipient accepting a transfer to make
  progress. A freelancer with a reverting fallback cannot hold a client's approval hostage.
* **Push-with-fallback refunds.** The two spec-mandated immediate refunds (escrow overpayment,
  dispute won by the client) try a direct send and degrade to a claimable balance if it fails,
  so a contract that rejects ETH cannot brick a bounty.
* **Unforgeable Arbiter.** Set once in the constructor, `immutable`, with no transfer path.
  `registerUser` explicitly rejects `Role.Arbiter`.
* **Permanent identity.** One address, one account. A penalised freelancer cannot re-register
  to wipe the penalty.
* **Saturating reputation.** `−30` on a score of `10` floors at `0` rather than underflowing.
* **Bare ETH rejected.** `receive`/`fallback` revert: ETH with no bounty attached would be
  unrecoverable.
* **Input bounds.** Names ≤ 64 bytes, CIDs 32–100 bytes, non-zero budgets and bids.

### In the frontend

* **XSS.** Bounty titles and descriptions come from IPFS and are attacker-controllable —
  anyone can pin `<img onerror=...>` and post it as a brief. Every interpolation into
  `innerHTML` passes through `esc()`, and gateway URLs are built from a fixed `https://`
  prefix so a hostile CID cannot inject a `javascript:` scheme.
* **No address inputs.** The active account always comes from MetaMask, never from typed
  text, which removes a whole class of phishing and typo failures.
* **Listener teardown.** `EventSync.detach()` runs before every re-subscribe. Without it,
  each account switch would leave a live listener behind and events would fire N times.

### The Pinata credential — the real caveat

**The credential is exposed client-side.** This build calls `api.pinata.cloud` directly from
the browser, with the credential held either in `localStorage` or in the generated
`frontend/js/pinata-config.js`. Either way, anyone with access to the page or its devtools can
read it and pin content to — and bill — that Pinata account.

What the code does about it:

* `frontend/js/pinata-config.js` is written `chmod 600` and git-ignored, so the secret cannot
  be committed even by accident.
* Nothing ever logs, renders or reports the value. The panel and the structured logs carry the
  **source** (`env` / `localStorage`) and the **character length** only.
* Placeholder values from `.env.example` are rejected, so a stale `your_jwt_here` surfaces as
  a config error rather than a confusing 401.

To move it server-side, point `PINATA_API` in `ipfsHelper.js` at your own authenticated proxy
and drop the `Authorization` header:

```
browser ──► your backend ──► Pinata
            (authenticates the user, rate-limits,
             caps file size, holds the credential server-side)
```

Every call site stays identical.

### Secrets hygiene

* `.env` is git-ignored and **never** overwritten by `setup.sh`. Only `.env.example`, which
  contains placeholders, is committed.
* `deploy-local.sh` parses `.env` line by line and assigns explicitly instead of
  `source`-ing it, so a stray backtick in a secret cannot execute shell code. It never echoes
  a value.
* The `PRIVATE_KEY` placeholder is Anvil's publicly documented account #0. `Deploy.s.sol`
  **refuses to run** if that key is used on any chain other than 31337.
* `package-lock.json` is committed so the dependency tree is pinned and reproducible.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `forge: command not found` | PATH not reloaded | `export PATH="$HOME/.foundry/bin:$PATH"` or open a new terminal |
| Banner: *Contract address unknown* | not deployed yet | `./scripts/deploy-local.sh` |
| *No contract at that address* | anvil restarted; state is gone | re-run `./scripts/deploy-local.sh` |
| MetaMask: *nonce too high* | anvil restarted, MetaMask cached the nonce | Settings → Advanced → **Clear activity tab data** |
| Banner: *Wrong network* | MetaMask on another chain | click **Switch to Anvil**, or add chain id 31337 manually |
| Uploads fail with 401/403 | credential missing, expired, or lacking pinning scope | re-paste it in the Pinata panel and press **Test** |
| Bounty cards show *"Loading brief from IPFS…"* forever | gateway unreachable or the CID is not pinned | check the network tab; the feed still works, only the text is missing |
| *Reputation gate* on a bid | score below 40 | expected behaviour — the score is shown in the header badge |
| `window.ethereum is undefined` | page opened as `file://` | serve it: `./scripts/serve-frontend.sh` |
| Port 8545 busy | an anvil instance is already running | reuse it, or `./scripts/start-anvil.sh --port 8546` |
| `jq: command not found` during deploy | jq missing | `sudo apt-get install -y jq` |
| `setup.sh`: *foundryup could not update the toolchain* | anvil/forge is running and holds the binaries | harmless — the existing toolchain is used. Stop anvil and re-run only if you want a newer release. |
| Events do not fire in window 2 | listeners not attached | the sidebar dot should be green; check the console for `event_listeners_attached` |

Turn up frontend logging in the browser console:

```js
BountyPulseLogger.setLevel("debug");
```

---

## Project structure

```
BountyPlus/
├── src/
│   └── BountyPulse.sol            # the contract: registry, escrow, fees, reputation
├── script/
│   └── Deploy.s.sol               # Forge deploy; prints metrics, writes the record
├── test/
│   └── BountyPulse.t.sol          # 83 tests: unit, security, 5 fuzz
├── frontend/
│   ├── index.html                 # role-based UI, no address inputs
│   ├── design-system/
│   │   ├── styles.css             # THE stylesheet: tokens, OKLCH ramps, components
│   │   └── theme.json             # machine-readable record of the same parameters
│   └── js/
│       ├── contract.js            # ABI + enums + address resolution + error messages
│       ├── icons.js               # vendored Lucide geometry (no CDN, works offline)
│       ├── ipfsHelper.js          # two-step Pinata pipeline, retry/backoff/timeouts
│       ├── app.js                 # wallet, render, off-chain sort, event sync
│       ├── contract-address.js    # GENERATED by deploy-local.sh (git-ignored)
│       ├── pinata-config.js       # GENERATED from .env — holds a secret (git-ignored)
│       └── vendor/                # GENERATED: ethers.umd.min.js (git-ignored)
├── images/                        # demo screenshots, referenced by README > Demo
├── abi/
│   └── BountyPulse.json           # GENERATED by deploy-local.sh for external consumers
├── scripts/
│   ├── start-anvil.sh             # local chain, port/chain-id/block-time flags
│   ├── deploy-local.sh            # deploy + verify + sync ABI/address to frontend
│   ├── gen-pinata-config.sh       # bridges PINATA_* from .env into the browser
│   └── serve-frontend.sh          # static server, vendors ethers.js for offline use
├── deployments/
│   └── 31337.local.json           # GENERATED deployment record (git-ignored)
├── setup.sh                       # idempotent, no-sudo environment setup
├── foundry.toml                   # solc 0.8.20, optimizer, remappings, fs permissions
├── package.json                   # ethers pin + script aliases (no bundler)
├── package-lock.json              # committed: reproducible dependency tree
├── .env.example                   # placeholders only — the template for .env
├── .gitignore                     # secrets, build output, generated files
└── README.md
```



