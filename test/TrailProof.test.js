const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const E = (n) => ethers.parseEther(String(n));
const CODES = ["elm-gate", "stone-bridge", "summit-cairn"];
const NAMES = ["Elm Gate", "Stone Bridge", "Summit Cairn"];

const gate = (trailId, index, code) =>
  ethers.solidityPackedKeccak256(["uint256", "uint32", "string"], [trailId, index, code]);

describe("TrailProof", function () {
  let tp, owner, creator, ann, ben, cara;

  beforeEach(async () => {
    [owner, creator, ann, ben, cara] = await ethers.getSigners();
    const F = await ethers.getContractFactory("TrailProof");
    tp = await F.deploy();
    await tp.waitForDeployment();
  });

  async function newTrail(purse = "1", dur = 7 * DAY, n = 3) {
    const id = Number(await tp.trailCount());
    const gates = CODES.slice(0, n).map((c, i) => gate(id, i, c));
    await tp.connect(creator).createTrail("Ridgeline Loop", NAMES.slice(0, n), gates, dur, { value: E(purse) });
    return id;
  }
  async function walkAll(id, who, n = 3) {
    for (let i = 0; i < n; i++) await tp.connect(who).checkIn(id, CODES[i]);
  }

  it("creates a trail with sealed waypoints and a purse", async () => {
    const id = await newTrail();
    const t = await tp.getTrail(id);
    expect(t.creator).to.equal(creator.address);
    expect(t.waypointCount).to.equal(3);
    expect(t.purse).to.equal(E(1));
    expect(await tp.getWaypointNames(id)).to.deep.equal(NAMES);
    expect(await tp.lockedTotal()).to.equal(E(1));
  });

  it("rejects mismatched arrays, an empty trail and a dust purse", async () => {
    const id = Number(await tp.trailCount());
    const gates = CODES.map((c, i) => gate(id, i, c));
    await expect(
      tp.connect(creator).createTrail("x", ["only one"], gates, 7 * DAY, { value: E(1) })
    ).to.be.revertedWith("length mismatch");
    await expect(tp.connect(creator).createTrail("x", [], [], 7 * DAY, { value: E(1) })).to.be.revertedWith(
      "bad waypoint count"
    );
    await expect(
      tp.connect(creator).createTrail("x", NAMES, gates, 7 * DAY, { value: 1 })
    ).to.be.revertedWith("purse too small");
    await expect(
      tp.connect(creator).createTrail("x", NAMES, gates, 600, { value: E(1) })
    ).to.be.revertedWith("bad duration");
  });

  it("advances one waypoint at a time and refuses a wrong code", async () => {
    const id = await newTrail();
    await expect(tp.connect(ann).checkIn(id, "not-the-code")).to.be.revertedWith("wrong code");
    // The second waypoint's code does not open the first gate.
    await expect(tp.connect(ann).checkIn(id, CODES[1])).to.be.revertedWith("wrong code");

    await tp.connect(ann).checkIn(id, CODES[0]);
    expect(await tp.progressOf(id, ann.address)).to.equal(1);
    await tp.connect(ann).checkIn(id, CODES[1]);
    expect(await tp.progressOf(id, ann.address)).to.equal(2);
  });

  it("will not accept a code minted for a different trail", async () => {
    const a = await newTrail();
    const b = await newTrail();
    // Codes are bound to the trail id, so trail a's gate is useless on trail b.
    await tp.connect(ann).checkIn(a, CODES[0]);
    await expect(tp.connect(ann).checkIn(b, "wrong")).to.be.revertedWith("wrong code");
    await tp.connect(ann).checkIn(b, CODES[0]); // correct code, rehashed for trail b
    expect(await tp.progressOf(b, ann.address)).to.equal(1);
  });

  it("records a finisher at the last waypoint", async () => {
    const id = await newTrail();
    await walkAll(id, ann);
    expect(await tp.hasFinished(id, ann.address)).to.equal(true);
    expect((await tp.getTrail(id)).finishers).to.equal(1);
    expect(await tp.getFinishers(id)).to.deep.equal([ann.address]);
    await expect(tp.connect(ann).checkIn(id, CODES[0])).to.be.revertedWith("already finished");
  });

  it("closes to new check-ins and top-ups once the clock runs out", async () => {
    const id = await newTrail();
    await time.increase(8 * DAY);
    await expect(tp.connect(ann).checkIn(id, CODES[0])).to.be.revertedWith("trail closed");
    await expect(tp.connect(ben).topUpPurse(id, { value: E(1) })).to.be.revertedWith("trail closed");
  });

  it("splits the purse evenly between finishers, minus the fee", async () => {
    const id = await newTrail("1");
    await walkAll(id, ann);
    await walkAll(id, ben);
    await tp.connect(cara).checkIn(id, CODES[0]); // did not finish

    await expect(tp.connect(ann).claimPurse(id)).to.be.revertedWith("not closed");
    await time.increase(8 * DAY);

    // 0.5 each, 2% fee = 0.49 net
    await expect(tp.connect(ann).claimPurse(id)).to.changeEtherBalance(ann, E("0.49"));
    await expect(tp.connect(ben).claimPurse(id)).to.changeEtherBalance(ben, E("0.49"));
    await expect(tp.connect(cara).claimPurse(id)).to.be.revertedWith("did not finish");
    await expect(tp.connect(ann).claimPurse(id)).to.be.revertedWith("already claimed");

    expect(await tp.accumulatedFees()).to.equal(E("0.02"));
    expect(await tp.lockedTotal()).to.equal(0);
  });

  it("sweeps indivisible dust into fees on the first claim", async () => {
    const id = await newTrail("1");
    await walkAll(id, ann);
    await walkAll(id, ben);
    await walkAll(id, cara);
    await time.increase(8 * DAY);

    await tp.connect(ann).claimPurse(id);
    const t = await tp.getTrail(id);
    expect(t.shareFixed).to.equal(true);
    expect(t.shareEach * 3n + 1n).to.equal(E(1)); // 1 wei could not divide

    await tp.connect(ben).claimPurse(id);
    await tp.connect(cara).claimPurse(id);
    expect(await tp.lockedTotal()).to.equal(0);
    expect(await ethers.provider.getBalance(await tp.getAddress())).to.equal(await tp.accumulatedFees());
  });

  it("returns the purse to the creator when nobody finishes", async () => {
    const id = await newTrail("1");
    await tp.connect(ann).checkIn(id, CODES[0]);
    await time.increase(8 * DAY);

    await expect(tp.connect(ann).reclaimPurse(id)).to.be.revertedWith("not creator");
    await expect(tp.connect(creator).reclaimPurse(id)).to.changeEtherBalance(creator, E(1));
    await expect(tp.connect(creator).reclaimPurse(id)).to.be.revertedWith("already reclaimed");
    expect(await tp.lockedTotal()).to.equal(0);
  });

  it("refuses a reclaim once anyone has finished", async () => {
    const id = await newTrail("1");
    await walkAll(id, ann);
    await time.increase(8 * DAY);
    await expect(tp.connect(creator).reclaimPurse(id)).to.be.revertedWith("someone finished");
  });

  it("lets anyone top up an open purse", async () => {
    const id = await newTrail("1");
    await tp.connect(ben).topUpPurse(id, { value: E("0.5") });
    expect((await tp.getTrail(id)).purse).to.equal(E("1.5"));
    expect(await tp.lockedTotal()).to.equal(E("1.5"));
  });

  it("keeps check-ins open while paused but blocks new trails", async () => {
    const id = await newTrail();
    await tp.connect(owner).pause();

    await tp.connect(ann).checkIn(id, CODES[0]); // a walker on the hill is never locked out
    await expect(
      tp.connect(creator).createTrail("x", NAMES, [gate(9, 0, "a"), gate(9, 1, "b"), gate(9, 2, "c")], 7 * DAY, { value: E(1) })
    ).to.be.revertedWithCustomError(tp, "EnforcedPause");
  });

  it("reports a projected share that matches what gets paid", async () => {
    const id = await newTrail("1");
    await walkAll(id, ann);
    await walkAll(id, ben);
    expect(await tp.projectedShare(id)).to.equal(E("0.49"));
    await time.increase(8 * DAY);
    await expect(tp.connect(ann).claimPurse(id)).to.changeEtherBalance(ann, E("0.49"));
  });

  it("caps the fee and withdraws only fees, owner only", async () => {
    await expect(tp.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");

    const id = await newTrail("1");
    await walkAll(id, ann);
    await time.increase(8 * DAY);
    await tp.connect(ann).claimPurse(id);

    await expect(tp.connect(ann).withdrawFees(ann.address)).to.be.revertedWithCustomError(
      tp,
      "OwnableUnauthorizedAccount"
    );
    await expect(tp.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.02"));
    expect(await tp.accumulatedFees()).to.equal(0);
  });

  it("exposes the gate helpers so a creator can verify their printed codes", async () => {
    const id = await newTrail();
    expect(await tp.gateFor(id, 0, CODES[0])).to.equal(gate(id, 0, CODES[0]));
    expect(await tp.gateAt(id, 0)).to.equal(await tp.gateFor(id, 0, CODES[0]));
    expect(await tp.gateAt(id, 2)).to.not.equal(await tp.gateFor(id, 2, "wrong"));
    await expect(tp.gateAt(id, 7)).to.be.revertedWith("no such waypoint");
    await newTrail();
    expect((await tp.getRecent(2)).map(Number)).to.deep.equal([1, 0]);
    expect((await tp.getTrailsByCreator(creator.address)).length).to.equal(2);
  });
});
