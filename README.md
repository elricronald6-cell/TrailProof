# TrailProof

Proof-of-visit trails on BOT Chain.

A creator lays out an ordered set of waypoints, each sealed behind the hash of
a code posted at the place itself, and funds a purse. Walkers check in one
waypoint at a time, **in order**, by submitting the code. Finish every waypoint
before the trail closes and you split the purse with everyone else who
finished.

## The honest limitation

A code becomes public the moment the first walker submits it — calldata is
readable. This proves somebody was in a position to know the code, not that
every later walker stood at the waypoint. For trails where that matters, keep
the window short and rotate codes by publishing a new trail. The frontend says
this on the page rather than hiding it.

## Gates are bound to the trail

Each gate is `keccak256(abi.encodePacked(trailId, index, code))`, so a code
lifted from one trail cannot be replayed on another. That also means a creator
has to predict the trail id when building the hashes. The frontend reads
`trailCount()` immediately before sending, then calls `gateAt(id, 0)` after the
transaction lands and tells you plainly if the id shifted — **print the codes
only after that check passes.**

## Contract surface

| Call | Who | What it does |
|---|---|---|
| `createTrail(name, waypointNames[], gates[], durationSecs)` | anyone | 1–12 waypoints, 1–180 days, purse ≥ 0.01 BOT |
| `topUpPurse(trailId)` | anyone | Adds to an open purse |
| `checkIn(trailId, code)` | anyone | Opens your next gate. **Works while paused** |
| `claimPurse(trailId)` | finishers | Equal share after close, minus `feeBps` (2% default, capped 5%) |
| `reclaimPurse(trailId)` | creator | Whole purse back if nobody finished |
| `gateFor` / `gateAt` | view | Build hashes off-chain, then verify what was stored |

The share is fixed on the first claim and whatever cannot divide evenly goes to
fees right there, so no dust is stranded. `withdrawFees` is bounded by
`accumulatedFees` and can never reach a purse. A pause blocks new trails and
top-ups but never a check-in — a walker standing at a waypoint with a running
clock is never locked out.

## Build and deploy

```bash
npm install
npx hardhat test          # 15 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Organic / wabi-sabi**: warm
paper with a grain overlay, muted olive and terracotta, imperfect hand-drawn
lines. One narrow column read top to bottom — no cards, no panels, no stat
strip, with whitespace and hairline rules doing all the separating. Each trail
is a wandering dashed path with a station per waypoint, and buttons are text
links rather than filled shapes.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.

Codes are hashed in the browser; only the hash is sent.
