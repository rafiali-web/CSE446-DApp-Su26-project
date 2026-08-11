// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BountyPulse} from "../src/BountyPulse.sol";

/**
 * @title  Deploy
 * @notice Deployment script for BountyPulse.
 *
 * @dev USAGE
 *        forge script script/Deploy.s.sol:Deploy \
 *          --rpc-url http://127.0.0.1:8545 --broadcast -vvv
 *
 *      `scripts/deploy-local.sh` wraps this, then syncs the resulting address
 *      and ABI into the frontend.
 *
 * @dev CONFIGURATION
 *      Read from the environment, each with a safe local default so a bare
 *      `forge script` against anvil works with no setup at all:
 *
 *        PRIVATE_KEY         deployer key -> becomes the permanent Arbiter
 *        ARBITER_NAME        display name for the Arbiter profile
 *        ARBITER_AVATAR_CID  IPFS CID for the Arbiter avatar
 *
 *      The default key is Anvil's first well-known development account. It is
 *      published in Foundry's own documentation, is identical on every machine,
 *      and holds no value on any real network. Deploying anywhere other than a
 *      local chain REQUIRES setting PRIVATE_KEY explicitly.
 */
contract Deploy is Script {
    /// @dev Anvil account #0 — a public, valueless development key.
    uint256 internal constant ANVIL_ACCOUNT_ZERO_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    uint256 internal constant ANVIL_CHAIN_ID = 31_337;

    string internal constant DEFAULT_ARBITER_NAME = "BountyPulse Arbiter";
    string internal constant DEFAULT_ARBITER_AVATAR = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG";

    function run() external returns (BountyPulse pulse) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", ANVIL_ACCOUNT_ZERO_KEY);
        string memory arbiterName = vm.envOr("ARBITER_NAME", DEFAULT_ARBITER_NAME);
        string memory arbiterAvatar = vm.envOr("ARBITER_AVATAR_CID", DEFAULT_ARBITER_AVATAR);

        address deployer = vm.addr(deployerKey);

        if (deployerKey == ANVIL_ACCOUNT_ZERO_KEY && block.chainid != ANVIL_CHAIN_ID) {
            console.log("");
            console.log("!! REFUSING TO DEPLOY: the default Anvil development key is being used");
            console.log("!! on chain id %s, which is not the local chain (%s).", block.chainid, ANVIL_CHAIN_ID);
            console.log("!! Set PRIVATE_KEY to a key you control before deploying off-chain-id-31337.");
            revert("Deploy: refusing to use the public Anvil key outside a local chain");
        }

        vm.startBroadcast(deployerKey);
        pulse = new BountyPulse(arbiterName, arbiterAvatar);
        vm.stopBroadcast();

        _report(pulse, deployer, arbiterName, arbiterAvatar);
        _writeDeploymentRecord(pulse, deployer);
    }

    function _report(BountyPulse pulse, address deployer, string memory name, string memory avatar) internal view {
        console.log("");
        console.log("================================================================");
        console.log("  BountyPulse deployed");
        console.log("================================================================");
        console.log("  Contract address : %s", address(pulse));
        console.log("  Chain id         : %s", block.chainid);
        console.log("  Deployer/Arbiter : %s", deployer);
        console.log("  Arbiter name     : %s", name);
        console.log("  Arbiter avatar   : %s", avatar);
        console.log("  Runtime bytecode : %s bytes", address(pulse).code.length);
        console.log("----------------------------------------------------------------");
        console.log("  Platform fee     : %s bps (2%%)", pulse.PLATFORM_FEE_BPS());
        console.log("  Start reputation : %s", pulse.INITIAL_REPUTATION());
        console.log("  Bid rep. gate    : %s", pulse.MIN_BID_REPUTATION());
        console.log("================================================================");
        console.log("");
    }

    /**
     * @dev Writes a machine-readable deployment record consumed by
     *      scripts/deploy-local.sh. The `.local.json` suffix is git-ignored:
     *      addresses from an ephemeral chain must never be committed.
     */
    function _writeDeploymentRecord(BountyPulse pulse, address deployer) internal {
        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".local.json");

        string memory json = string.concat(
            "{\n",
            '  "contract": "BountyPulse",\n',
            '  "address": "',
            vm.toString(address(pulse)),
            '",\n',
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "deployer": "',
            vm.toString(deployer),
            '",\n',
            '  "arbiter": "',
            vm.toString(pulse.arbiter()),
            '",\n',
            '  "blockNumber": ',
            vm.toString(block.number),
            ",\n",
            '  "timestamp": ',
            vm.toString(block.timestamp),
            "\n",
            "}\n"
        );

        vm.writeFile(path, json);
        console.log("  Deployment record: %s", path);
    }
}
