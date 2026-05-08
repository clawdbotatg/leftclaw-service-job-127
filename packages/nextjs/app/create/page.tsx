"use client";

import { useEffect, useMemo, useState } from "react";
import { AddressInput } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatUnits, isHex, keccak256, parseUnits } from "viem";
import { useAccount, useSwitchChain } from "wagmi";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import {
  useScaffoldReadContract,
  useScaffoldWriteContract,
  useTargetNetwork,
  useWriteAndOpen,
} from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";
import { contracts } from "~~/utils/scaffold-eth/contract";

const CreateJobPage: NextPage = () => {
  const { address: connectedAddress, isConnected, chain: accountChain } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const { switchChain, isPending: switchPending } = useSwitchChain();
  const { writeAndOpen } = useWriteAndOpen();

  const cronBondSpender = (contracts?.[targetNetwork.id]?.["CronBond"]?.address ?? undefined) as
    | `0x${string}`
    | undefined;

  const [target, setTarget] = useState<string>("");
  const [callData, setCallData] = useState<string>("0x");
  const [executeAtLocal, setExecuteAtLocal] = useState<string>("");
  const [bondAmount, setBondAmount] = useState<string>("");
  const [maxGas, setMaxGas] = useState<number>(500_000);
  const [submittingApprove, setSubmittingApprove] = useState(false);
  const [submittingRegister, setSubmittingRegister] = useState(false);
  const [approvalCooldown, setApprovalCooldown] = useState(false);

  const { data: minBond } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "minBond",
  });

  const { data: allowance } = useScaffoldReadContract({
    contractName: "USDC",
    functionName: "allowance",
    args: [connectedAddress, cronBondSpender],
  });

  const bondAmountWei = useMemo<bigint | null>(() => {
    if (!bondAmount) return null;
    try {
      return parseUnits(bondAmount, 6);
    } catch {
      return null;
    }
  }, [bondAmount]);

  const calldataHash = useMemo<`0x${string}` | null>(() => {
    if (!callData || !isHex(callData)) return null;
    try {
      return keccak256(callData as `0x${string}`);
    } catch {
      return null;
    }
  }, [callData]);

  const executeAtSec = useMemo<bigint | null>(() => {
    if (!executeAtLocal) return null;
    const ms = new Date(executeAtLocal).getTime();
    if (Number.isNaN(ms)) return null;
    return BigInt(Math.floor(ms / 1000));
  }, [executeAtLocal]);

  const wrongNetwork = isConnected && accountChain?.id !== targetNetwork.id;

  const needsApproval = useMemo(() => {
    if (!bondAmountWei) return false;
    if (allowance === undefined) return true;
    return (allowance as bigint) < bondAmountWei;
  }, [allowance, bondAmountWei]);

  const { writeContractAsync: usdcWriteAsync } = useScaffoldWriteContract({
    contractName: "USDC",
  });

  const { writeContractAsync: cronBondWriteAsync } = useScaffoldWriteContract({
    contractName: "CronBond",
  });

  // Cooldown after approve so allowance has time to refresh on chain
  useEffect(() => {
    if (!approvalCooldown) return;
    const id = setTimeout(() => setApprovalCooldown(false), 4000);
    return () => clearTimeout(id);
  }, [approvalCooldown]);

  const handleApprove = async () => {
    if (!bondAmountWei || !cronBondSpender) {
      notification.error("Enter a valid bond amount first");
      return;
    }
    setSubmittingApprove(true);
    try {
      await writeAndOpen(() =>
        usdcWriteAsync({
          functionName: "approve",
          args: [cronBondSpender, bondAmountWei],
        }),
      );
      notification.success("USDC approved");
      setApprovalCooldown(true);
    } catch (err: any) {
      notification.error(err?.message ?? "Approval failed");
    } finally {
      setSubmittingApprove(false);
    }
  };

  const handleRegister = async () => {
    if (!target || !isHex(target as `0x${string}`)) {
      notification.error("Enter a valid target address");
      return;
    }
    if (!callData || !isHex(callData)) {
      notification.error("Calldata must be hex");
      return;
    }
    if (!executeAtSec) {
      notification.error("Choose an execute-at time");
      return;
    }
    if (!bondAmountWei) {
      notification.error("Enter a valid bond amount");
      return;
    }
    setSubmittingRegister(true);
    try {
      const txHash = await writeAndOpen(() =>
        cronBondWriteAsync({
          functionName: "register",
          args: [target as `0x${string}`, callData as `0x${string}`, executeAtSec, bondAmountWei, maxGas],
        }),
      );
      notification.success(`Job registered. Tx: ${txHash?.slice(0, 10) ?? "submitted"}…`);
      setCallData("0x");
      setExecuteAtLocal("");
      setBondAmount("");
    } catch (err: any) {
      notification.error(err?.message ?? "Register failed");
    } finally {
      setSubmittingRegister(false);
    }
  };

  return (
    <div className="flex flex-col grow px-5 py-8 max-w-3xl mx-auto w-full">
      <h1 className="text-3xl font-bold mb-6">Create Job</h1>

      <div className="card bg-base-100 shadow">
        <div className="card-body space-y-4">
          <div>
            <label className="label">
              <span className="label-text font-medium">Target Contract</span>
            </label>
            <AddressInput value={target} onChange={setTarget} placeholder="0x… target contract" />
          </div>

          <div>
            <label className="label">
              <span className="label-text font-medium">Call Data (hex)</span>
            </label>
            <textarea
              className="textarea textarea-bordered w-full font-mono text-xs"
              rows={3}
              placeholder="0x..."
              value={callData}
              onChange={e => setCallData(e.target.value.trim())}
            />
            {calldataHash && (
              <div className="text-xs opacity-70 mt-1 font-mono break-all">keccak256: {calldataHash}</div>
            )}
          </div>

          <div>
            <label className="label">
              <span className="label-text font-medium">Execute At</span>
              <span className="label-text-alt opacity-60">
                Local time ({Intl.DateTimeFormat().resolvedOptions().timeZone})
              </span>
            </label>
            <input
              type="datetime-local"
              className="input input-bordered w-full"
              value={executeAtLocal}
              onChange={e => setExecuteAtLocal(e.target.value)}
            />
          </div>

          <div>
            <label className="label">
              <span className="label-text font-medium">Bond Amount (USDC)</span>
              {minBond !== undefined && (
                <span className="label-text-alt opacity-60">min: {formatUnits(minBond, 6)} USDC</span>
              )}
            </label>
            <input
              type="number"
              step="0.000001"
              min={minBond ? formatUnits(minBond, 6) : "0"}
              className="input input-bordered w-full"
              placeholder="1.00"
              value={bondAmount}
              onChange={e => setBondAmount(e.target.value)}
            />
          </div>

          <div>
            <label className="label">
              <span className="label-text font-medium">Max Gas</span>
              <span className="label-text-alt font-mono">{maxGas.toLocaleString()}</span>
            </label>
            <input
              type="range"
              min={50_000}
              max={5_000_000}
              step={10_000}
              value={maxGas}
              onChange={e => setMaxGas(Number(e.target.value))}
              className="range range-primary"
            />
            <div className="flex justify-between text-xs opacity-60 mt-1">
              <span>50k</span>
              <span>5M</span>
            </div>
          </div>

          <div className="pt-4">
            {!isConnected ? (
              <RainbowKitCustomConnectButton />
            ) : wrongNetwork ? (
              <button
                className="btn btn-warning w-full"
                onClick={() => switchChain({ chainId: targetNetwork.id })}
                disabled={switchPending}
              >
                {switchPending ? (
                  <span className="loading loading-spinner loading-sm" />
                ) : (
                  `Switch to ${targetNetwork.name}`
                )}
              </button>
            ) : needsApproval ? (
              <button
                className="btn btn-primary w-full"
                onClick={handleApprove}
                disabled={submittingApprove || approvalCooldown || !bondAmountWei}
              >
                {submittingApprove || approvalCooldown ? (
                  <span className="loading loading-spinner loading-sm" />
                ) : (
                  "Approve USDC"
                )}
              </button>
            ) : (
              <button
                className="btn btn-primary w-full"
                onClick={handleRegister}
                disabled={submittingRegister || !bondAmountWei || !executeAtSec || !target || !calldataHash}
              >
                {submittingRegister ? <span className="loading loading-spinner loading-sm" /> : "Register Job"}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};

export default CreateJobPage;
