// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CronBond} from "../contracts/CronBond.sol";

contract Deploy is Script {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PROTOCOL_FEE_RECEIVER = 0x8E9a2fa876CD2626F1CA2676132Fe638DE4ac3F1;
    address constant INITIAL_OWNER = 0x8E9a2fa876CD2626F1CA2676132Fe638DE4ac3F1;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        CronBond cronBond = new CronBond(USDC, PROTOCOL_FEE_RECEIVER, INITIAL_OWNER);

        // Post-deploy assertions
        require(address(cronBond.USDC()) == USDC, "USDC mismatch");
        require(cronBond.PROTOCOL_FEE_RECEIVER() == PROTOCOL_FEE_RECEIVER, "FEE_RECEIVER mismatch");
        require(cronBond.owner() == INITIAL_OWNER, "owner mismatch");
        require(cronBond.minBond() == 1_000_000, "minBond mismatch");
        require(cronBond.protocolFeeBps() == 10, "protocolFeeBps mismatch");
        require(cronBond.cancellationFeeBps() == 500, "cancellationFeeBps mismatch");
        require(cronBond.cancellationFeeFloor() == 50_000, "cancellationFeeFloor mismatch");
        require(cronBond.staleWindow() == 604_800, "staleWindow mismatch");
        require(cronBond.minDelay() == 120, "minDelay mismatch");
        require(cronBond.maxDelay() == 157_680_000, "maxDelay mismatch");

        vm.stopBroadcast();

        console.log("CronBond deployed at:", address(cronBond));
    }
}
