// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TrailProof
 * @notice Proof-of-visit trails on BOT Chain.
 *
 * A creator lays out an ordered set of waypoints, each sealed behind the hash
 * of a code posted at the place itself, and funds a purse. Walkers check in
 * one waypoint at a time, in order, by submitting the code. Finish every
 * waypoint before the trail closes and you split the purse with everyone else
 * who finished.
 *
 * Honest limitation, stated plainly: a code becomes public the moment the
 * first walker submits it, because calldata is readable. This proves that
 * somebody was in a position to know the code, not that every later walker
 * stood at the waypoint. For trails where that matters, keep the window short
 * and rotate the codes by publishing a new trail.
 */
contract TrailProof is Ownable, Pausable, ReentrancyGuard {
    struct Trail {
        address creator;
        uint256 purse;
        uint64 closesAt;
        uint32 waypointCount;
        uint32 finishers;
        uint256 shareEach;
        bool shareFixed;
        bool reclaimed;
        string name;
    }

    uint32 public constant MIN_WAYPOINTS = 1;
    uint32 public constant MAX_WAYPOINTS = 12;
    uint64 public constant MIN_DURATION = 1 days;
    uint64 public constant MAX_DURATION = 180 days;
    uint256 public constant MIN_PURSE = 0.01 ether;
    uint256 public constant MAX_NAME = 56;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Taken from each finisher's share at claim time.
    uint16 public feeBps = 200;

    uint256 public accumulatedFees;
    /// @notice Purse money not yet paid out or reclaimed.
    uint256 public lockedTotal;

    Trail[] private _trails;
    mapping(uint256 => bytes32[]) private _gates;
    mapping(uint256 => string[]) private _waypointNames;
    /// @dev trailId => walker => index of the next waypoint they owe.
    mapping(uint256 => mapping(address => uint32)) private _progress;
    mapping(uint256 => mapping(address => bool)) private _claimed;
    mapping(uint256 => address[]) private _finishers;
    mapping(address => uint256[]) private _trailsByCreator;

    event TrailCreated(uint256 indexed trailId, address indexed creator, string name, uint32 waypoints, uint256 purse, uint64 closesAt);
    event PurseToppedUp(uint256 indexed trailId, address indexed from, uint256 amount, uint256 purse);
    event CheckedIn(uint256 indexed trailId, address indexed walker, uint32 waypointIndex, uint32 progress);
    event Finished(uint256 indexed trailId, address indexed walker, uint32 position);
    event ShareFixed(uint256 indexed trailId, uint256 shareEach, uint256 dustToFees);
    event PurseClaimed(uint256 indexed trailId, address indexed walker, uint256 amount, uint256 fee);
    event PurseReclaimed(uint256 indexed trailId, address indexed creator, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // -------------------------------------------------------------- create

    /**
     * @param gates One hash per waypoint, in walking order. Each must be
     *        `keccak256(abi.encodePacked(trailId, index, code))`, so a code
     *        lifted from one trail cannot be replayed on another.
     */
    function createTrail(
        string calldata name,
        string[] calldata waypointNames,
        bytes32[] calldata gates,
        uint64 durationSecs
    ) external payable whenNotPaused returns (uint256 trailId) {
        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "bad name");
        require(gates.length == waypointNames.length, "length mismatch");
        require(gates.length >= MIN_WAYPOINTS && gates.length <= MAX_WAYPOINTS, "bad waypoint count");
        require(durationSecs >= MIN_DURATION && durationSecs <= MAX_DURATION, "bad duration");
        require(msg.value >= MIN_PURSE, "purse too small");

        trailId = _trails.length;
        _trails.push(
            Trail({
                creator: msg.sender,
                purse: msg.value,
                closesAt: uint64(block.timestamp) + durationSecs,
                waypointCount: uint32(gates.length),
                finishers: 0,
                shareEach: 0,
                shareFixed: false,
                reclaimed: false,
                name: name
            })
        );

        for (uint256 i = 0; i < gates.length; i++) {
            require(gates[i] != bytes32(0), "empty gate");
            require(bytes(waypointNames[i]).length <= MAX_NAME, "waypoint name too long");
            _gates[trailId].push(gates[i]);
            _waypointNames[trailId].push(waypointNames[i]);
        }

        _trailsByCreator[msg.sender].push(trailId);
        lockedTotal += msg.value;
        emit TrailCreated(trailId, msg.sender, name, uint32(gates.length), msg.value, _trails[trailId].closesAt);
    }

    /// @notice Anyone may add to a purse while the trail is open.
    function topUpPurse(uint256 trailId) external payable whenNotPaused {
        Trail storage t = _trail(trailId);
        require(block.timestamp < t.closesAt, "trail closed");
        require(msg.value > 0, "nothing sent");
        t.purse += msg.value;
        lockedTotal += msg.value;
        emit PurseToppedUp(trailId, msg.sender, msg.value, t.purse);
    }

    // ------------------------------------------------------------ check in

    /**
     * @notice Submit the code for the next waypoint you owe.
     * @dev Deliberately not blocked by a pause — a walker standing at a
     *      waypoint with a running clock should never be locked out.
     */
    function checkIn(uint256 trailId, string calldata code) external {
        Trail storage t = _trail(trailId);
        require(block.timestamp < t.closesAt, "trail closed");

        uint32 idx = _progress[trailId][msg.sender];
        require(idx < t.waypointCount, "already finished");
        require(keccak256(abi.encodePacked(trailId, idx, code)) == _gates[trailId][idx], "wrong code");

        unchecked {
            idx += 1;
        }
        _progress[trailId][msg.sender] = idx;
        emit CheckedIn(trailId, msg.sender, idx - 1, idx);

        if (idx == t.waypointCount) {
            _finishers[trailId].push(msg.sender);
            unchecked {
                t.finishers += 1;
            }
            emit Finished(trailId, msg.sender, t.finishers);
        }
    }

    // --------------------------------------------------------------- purse

    /**
     * @notice Finishers collect an equal share once the trail closes.
     * @dev The share is fixed on the first claim, and whatever cannot divide
     *      evenly goes to fees there and then, so no dust is stranded.
     */
    function claimPurse(uint256 trailId) external nonReentrant {
        Trail storage t = _trail(trailId);
        require(block.timestamp >= t.closesAt, "not closed");
        require(_progress[trailId][msg.sender] == t.waypointCount && t.waypointCount > 0, "did not finish");
        require(!_claimed[trailId][msg.sender], "already claimed");

        if (!t.shareFixed) {
            uint256 share = t.purse / t.finishers;
            uint256 dust = t.purse - (share * t.finishers);
            t.shareEach = share;
            t.shareFixed = true;
            if (dust > 0) {
                accumulatedFees += dust;
                lockedTotal -= dust;
            }
            emit ShareFixed(trailId, share, dust);
        }

        _claimed[trailId][msg.sender] = true;
        uint256 amount = t.shareEach;
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 net = amount - fee;
        accumulatedFees += fee;
        lockedTotal -= amount;

        emit PurseClaimed(trailId, msg.sender, net, fee);

        (bool ok, ) = payable(msg.sender).call{value: net}("");
        require(ok, "payout failed");
    }

    /// @notice If nobody finished, the creator takes the purse back.
    function reclaimPurse(uint256 trailId) external nonReentrant {
        Trail storage t = _trail(trailId);
        require(t.creator == msg.sender, "not creator");
        require(block.timestamp >= t.closesAt, "not closed");
        require(t.finishers == 0, "someone finished");
        require(!t.reclaimed, "already reclaimed");

        t.reclaimed = true;
        uint256 amount = t.purse;
        lockedTotal -= amount;
        emit PurseReclaimed(trailId, msg.sender, amount);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "reclaim failed");
    }

    // --------------------------------------------------------------- views

    function trailCount() external view returns (uint256) {
        return _trails.length;
    }

    function getTrail(uint256 trailId) external view returns (Trail memory) {
        return _trail(trailId);
    }

    /// @notice Waypoint names only. The gates are hashes and stay sealed here.
    function getWaypointNames(uint256 trailId) external view returns (string[] memory) {
        return _waypointNames[trailId];
    }

    function progressOf(uint256 trailId, address walker) external view returns (uint32) {
        return _progress[trailId][walker];
    }

    function hasFinished(uint256 trailId, address walker) external view returns (bool) {
        Trail storage t = _trail(trailId);
        return t.waypointCount > 0 && _progress[trailId][walker] == t.waypointCount;
    }

    function hasClaimed(uint256 trailId, address walker) external view returns (bool) {
        return _claimed[trailId][walker];
    }

    function getFinishers(uint256 trailId) external view returns (address[] memory) {
        return _finishers[trailId];
    }

    function getTrailsByCreator(address creator) external view returns (uint256[] memory) {
        return _trailsByCreator[creator];
    }

    /// @notice What one finisher would receive if the trail closed right now.
    function projectedShare(uint256 trailId) external view returns (uint256) {
        Trail storage t = _trail(trailId);
        if (t.finishers == 0) return 0;
        uint256 share = t.shareFixed ? t.shareEach : t.purse / t.finishers;
        return share - ((share * feeBps) / 10_000);
    }

    /// @notice Newest-first page of trail ids.
    function getRecent(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _trails.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    /// @notice Helper mirroring the gate formula, for building a trail off-chain.
    function gateFor(uint256 trailId, uint32 index, string calldata code) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(trailId, index, code));
    }

    /**
     * @notice The stored gate hash for a waypoint.
     * @dev Public on purpose. Gates must be built against the trail's real id,
     *      which a creator can only predict before the transaction lands. This
     *      lets a creator check straight afterwards that the codes they printed
     *      actually open the trail, rather than discovering it from a walker.
     */
    function gateAt(uint256 trailId, uint32 index) external view returns (bytes32) {
        require(index < _trail(trailId).waypointCount, "no such waypoint");
        return _gates[trailId][index];
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`, so no purse is reachable from here.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _trail(uint256 id) private view returns (Trail storage) {
        require(id < _trails.length, "no such trail");
        return _trails[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
