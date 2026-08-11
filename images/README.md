# Screenshots

Drop the demo captures here using the exact filenames below. The root
`README.md` already references every one of them, so a screenshot renders as
soon as the file exists. Nothing else needs editing.

| Filename | What to capture |
|---|---|
| `01-registration.png` | The registration card: display name, the Client/Freelancer role choice, the avatar file picker. Ideally after choosing an image, so the `.plate` preview is visible. |
| `02-client-dashboard.png` | The Client dashboard: the "Post a bounty" form above the "My bounties" list with at least one bounty posted. |
| `03-bounty-feed-sorting.png` | The Freelancer's open bounty feed with the sort control open or the status segmented control switched, showing the "off-chain, 0 gas" note. |
| `04-bid-list.png` | A bounty card expanded to its quotes table, several bids visible, cheapest first. |
| `05-escrow-funding-metamask.png` | The MetaMask confirmation popup for `fundEscrow`, with the ETH value visible over the DApp behind it. |
| `06-work-submission-ipfs.png` | The awarded-work card mid-submission: the file chosen and the "Work pinned" toast showing the returned CID. |
| `07-arbiter-disputes.png` | The Arbiter panel: the platform totals table and an open dispute with both verdict buttons. |
| `08-unclaimed-earnings.png` | The sidebar earnings tracker showing a non-zero balance with the "Claim" button enabled. |
| `09-live-sync-two-windows.png` | Two browser windows side by side on different accounts, where an action in one has already updated the other. This is the checkpoint-5 proof, so make the difference obvious. |

## Guidance

- **PNG** is preferred; `.jpg`, `.jpeg`, `.webp` and `.gif` also render.
- Capture at a window width of at least 1280px so the two-column layout and the
  sidebar are both visible.
- These files are **tracked** in git. `.gitignore` carries explicit negations for
  this directory precisely so no broad ignore rule swallows them.
- Keep each file under roughly 1 MB. Screenshots live in git history forever.
- Redact nothing but the obvious: local Anvil accounts are public test keys, but
  crop out any real browser tabs, bookmarks or other windows.
