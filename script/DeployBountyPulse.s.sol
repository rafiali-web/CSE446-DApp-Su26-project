// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {BountyPulse} from "../src/BountyPulse.sol";

contract DeployBountyPulse is Script {
    function run() external returns (BountyPulse) {
        vm.startBroadcast();

        BountyPulse bountyPulse = new BountyPulse();

        vm.stopBroadcast();

        return bountyPulse;
    }
}