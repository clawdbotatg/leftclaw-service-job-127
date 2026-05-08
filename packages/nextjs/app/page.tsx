"use client";

import { useEffect, useMemo, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import {
  useScaffoldEventHistory,
  useScaffoldReadContract,
  useScaffoldWriteContract,
  useTargetNetwork,
} from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

type JobStatus = 0 | 1 | 2 | 3; // Active, Executed, Cancelled, Reclaimed

const STATUS_LABELS: Record<JobStatus, string> = {
  0: "Active",
  1: "Executed",
  2: "Cancelled",
  3: "Reclaimed",
};

const STATUS_BADGE_CLASS: Record<JobStatus, string> = {
  0: "badge-success",
  1: "badge-info",
  2: "badge-neutral",
  3: "badge-warning",
};

type JobTuple = readonly [
  `0x${string}`, // registrant
  bigint, // executeAt (uint64)
  number, // maxGas (uint32)
  `0x${string}`, // target
  number, // status (uint8)
  bigint, // bondAmount
  `0x${string}`, // callData
  `0x${string}`, // extraData
];

type RegisteredJob = {
  jobId: bigint;
  target: `0x${string}`;
  executeAt: bigint;
  bondAmount: bigint;
  maxGas: number;
  calldataHash: `0x${string}`;
  blockNumber?: bigint;
};

const formatCountdown = (executeAt: bigint, now: number): string => {
  const target = Number(executeAt) * 1000;
  const diffMs = target - now;
  if (diffMs <= 0) {
    const overdue = Math.abs(diffMs);
    const mins = Math.floor(overdue / 60000);
    if (mins < 60) return `${mins}m overdue`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}h overdue`;
    return `${Math.floor(hours / 24)}d overdue`;
  }
  const seconds = Math.floor(diffMs / 1000);
  if (seconds < 60) return `${seconds}s`;
  const mins = Math.floor(seconds / 60);
  if (mins < 60) return `${mins}m ${seconds % 60}s`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ${mins % 60}m`;
  return `${Math.floor(hours / 24)}d ${hours % 24}h`;
};

const JobRow = ({
  registered,
  staleWindow,
  now,
  onView,
  onCancel,
  onReclaim,
  isPending,
}: {
  registered: RegisteredJob;
  staleWindow: bigint | undefined;
  now: number;
  onView: (job: RegisteredJob, jobData: JobTuple | undefined) => void;
  onCancel: (jobId: bigint) => void;
  onReclaim: (jobId: bigint) => void;
  isPending: boolean;
}) => {
  const { data: jobData } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "jobs",
    args: [registered.jobId],
  });

  const tuple = jobData as JobTuple | undefined;
  const status = (tuple?.[4] ?? 0) as JobStatus;
  const executeAt = registered.executeAt;
  const nowSec = BigInt(Math.floor(now / 1000));
  const isActive = status === 0;
  const canCancel = isActive && nowSec + 60n < executeAt;
  const isExecutable = isActive && nowSec >= executeAt;
  const canReclaim = isActive && staleWindow !== undefined && nowSec >= executeAt + staleWindow;

  return (
    <tr className="hover:bg-base-200 cursor-pointer" onClick={() => onView(registered, tuple)}>
      <td className="font-mono">{registered.jobId.toString()}</td>
      <td>
        <Address address={registered.target} format="short" size="sm" />
      </td>
      <td className="text-sm">{formatCountdown(executeAt, now)}</td>
      <td className="font-mono text-sm">{formatUnits(registered.bondAmount, 6)}</td>
      <td>
        <span className={`badge ${STATUS_BADGE_CLASS[status]} badge-sm`}>{STATUS_LABELS[status]}</span>
      </td>
      <td onClick={e => e.stopPropagation()}>
        {canReclaim ? (
          <button className="btn btn-warning btn-xs" onClick={() => onReclaim(registered.jobId)} disabled={isPending}>
            Reclaim
          </button>
        ) : isExecutable ? (
          <span className="badge badge-info badge-sm">Executable</span>
        ) : canCancel ? (
          <button className="btn btn-outline btn-xs" onClick={() => onCancel(registered.jobId)} disabled={isPending}>
            Cancel
          </button>
        ) : (
          <span className="text-xs opacity-60">—</span>
        )}
      </td>
    </tr>
  );
};

const Home: NextPage = () => {
  const { address: connectedAddress, isConnected } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const [now, setNow] = useState<number>(() => Date.now());
  const [drawerJob, setDrawerJob] = useState<{ event: RegisteredJob; data: JobTuple | undefined } | null>(null);
  const [cachedFromBlock, setCachedFromBlock] = useState<bigint>(0n);

  // Tick every second for countdowns
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  // localStorage cache for last-scanned block
  useEffect(() => {
    if (!connectedAddress) return;
    const key = `cronbond-last-block-${connectedAddress.toLowerCase()}`;
    const raw = typeof window !== "undefined" ? window.localStorage.getItem(key) : null;
    if (raw) {
      try {
        setCachedFromBlock(BigInt(raw));
      } catch {
        setCachedFromBlock(0n);
      }
    } else {
      setCachedFromBlock(0n);
    }
  }, [connectedAddress]);

  const { data: pendingWithdrawal } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "pendingWithdrawals",
    args: [connectedAddress],
  });

  const { data: staleWindow } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "staleWindow",
  });

  const { data: events, isLoading: eventsLoading } = useScaffoldEventHistory({
    contractName: "CronBond",
    eventName: "JobRegistered",
    fromBlock: cachedFromBlock,
    watch: true,
    enabled: Boolean(connectedAddress),
    filters: connectedAddress ? { registrant: connectedAddress } : undefined,
  });

  // Persist max scanned block
  useEffect(() => {
    if (!connectedAddress || !events || events.length === 0) return;
    let maxBlock = cachedFromBlock;
    for (const ev of events) {
      const bn = ev.blockNumber as bigint | undefined;
      if (bn && bn > maxBlock) maxBlock = bn;
    }
    if (maxBlock > cachedFromBlock) {
      const key = `cronbond-last-block-${connectedAddress.toLowerCase()}`;
      try {
        window.localStorage.setItem(key, maxBlock.toString());
      } catch {
        // ignore
      }
    }
  }, [events, connectedAddress, cachedFromBlock]);

  const registeredJobs = useMemo<RegisteredJob[]>(() => {
    if (!events) return [];
    const seen = new Set<string>();
    const out: RegisteredJob[] = [];
    for (const ev of events) {
      const args = ev.args as
        | {
            jobId?: bigint;
            target?: `0x${string}`;
            executeAt?: bigint;
            bondAmount?: bigint;
            maxGas?: number;
            calldataHash?: `0x${string}`;
          }
        | undefined;
      if (!args?.jobId || !args.target || args.executeAt === undefined || args.bondAmount === undefined) continue;
      const key = args.jobId.toString();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        jobId: args.jobId,
        target: args.target,
        executeAt: args.executeAt,
        bondAmount: args.bondAmount,
        maxGas: args.maxGas ?? 0,
        calldataHash: args.calldataHash ?? "0x",
        blockNumber: ev.blockNumber as bigint | undefined,
      });
    }
    out.sort((a, b) => (a.jobId < b.jobId ? 1 : -1));
    return out;
  }, [events]);

  const { writeContractAsync: cronBondWriteAsync, isMining } = useScaffoldWriteContract({
    contractName: "CronBond",
  });

  const handleWithdraw = async () => {
    try {
      await cronBondWriteAsync({ functionName: "withdraw" });
      notification.success("Withdrawal sent");
    } catch (err: any) {
      notification.error(err?.message ?? "Withdraw failed");
    }
  };

  const handleCancel = async (jobId: bigint) => {
    try {
      await cronBondWriteAsync({ functionName: "cancel", args: [jobId] });
      notification.success(`Job ${jobId} cancelled`);
    } catch (err: any) {
      notification.error(err?.message ?? "Cancel failed");
    }
  };

  const handleReclaim = async (jobId: bigint) => {
    try {
      await cronBondWriteAsync({ functionName: "reclaimStale", args: [jobId] });
      notification.success(`Job ${jobId} reclaimed`);
    } catch (err: any) {
      notification.error(err?.message ?? "Reclaim failed");
    }
  };

  if (!isConnected) {
    return (
      <div className="flex flex-col items-center justify-center grow pt-20 px-5">
        <div className="card bg-base-100 shadow-xl max-w-md">
          <div className="card-body items-center text-center">
            <h1 className="card-title text-2xl">My Jobs</h1>
            <p>Connect your wallet to view and manage your scheduled jobs on Base.</p>
            <div className="card-actions mt-4">
              <RainbowKitCustomConnectButton />
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col grow px-5 py-8 max-w-6xl mx-auto w-full">
      <div className="flex justify-between items-center mb-6">
        <h1 className="text-3xl font-bold">My Jobs</h1>
        <div className="text-sm opacity-70">
          Network: <span className="font-medium">{targetNetwork.name}</span>
        </div>
      </div>

      {pendingWithdrawal && pendingWithdrawal > 0n && (
        <div className="alert alert-success mb-6 shadow">
          <div className="flex justify-between items-center w-full">
            <div>
              <h3 className="font-bold">Pending withdrawal available</h3>
              <p className="text-sm">{formatUnits(pendingWithdrawal, 6)} USDC ready to withdraw</p>
            </div>
            <button className="btn btn-sm btn-primary" onClick={handleWithdraw} disabled={isMining}>
              {isMining ? <span className="loading loading-spinner loading-sm" /> : "Withdraw"}
            </button>
          </div>
        </div>
      )}

      <div className="card bg-base-100 shadow">
        <div className="card-body p-4">
          {eventsLoading && registeredJobs.length === 0 ? (
            <div className="flex justify-center py-12">
              <span className="loading loading-spinner loading-lg" />
            </div>
          ) : registeredJobs.length === 0 ? (
            <div className="text-center py-12 opacity-70">
              <p>No jobs found. Head to Create Job to schedule one.</p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>Job ID</th>
                    <th>Target</th>
                    <th>Execute At</th>
                    <th>Bond (USDC)</th>
                    <th>Status</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {registeredJobs.map(job => (
                    <JobRow
                      key={job.jobId.toString()}
                      registered={job}
                      staleWindow={staleWindow}
                      now={now}
                      onView={(ev, data) => setDrawerJob({ event: ev, data })}
                      onCancel={handleCancel}
                      onReclaim={handleReclaim}
                      isPending={isMining}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {drawerJob && (
        <div className="modal modal-open">
          <div className="modal-box max-w-2xl bg-base-100">
            <h3 className="font-bold text-lg mb-4">Job #{drawerJob.event.jobId.toString()}</h3>
            <div className="space-y-3">
              <div>
                <span className="text-xs uppercase opacity-60">Target</span>
                <div>
                  <Address address={drawerJob.event.target} format="long" />
                </div>
              </div>
              <div>
                <span className="text-xs uppercase opacity-60">Bond Amount</span>
                <div className="font-mono">{formatUnits(drawerJob.event.bondAmount, 6)} USDC</div>
              </div>
              <div>
                <span className="text-xs uppercase opacity-60">Max Gas</span>
                <div className="font-mono">{drawerJob.event.maxGas.toLocaleString()}</div>
              </div>
              <div>
                <span className="text-xs uppercase opacity-60">Execute At</span>
                <div className="font-mono text-sm">
                  {new Date(Number(drawerJob.event.executeAt) * 1000).toLocaleString()}
                </div>
              </div>
              <div>
                <span className="text-xs uppercase opacity-60">Calldata Hash</span>
                <div className="font-mono text-xs break-all">{drawerJob.event.calldataHash}</div>
              </div>
              {drawerJob.data && (
                <div>
                  <span className="text-xs uppercase opacity-60">Calldata (full)</span>
                  <div className="font-mono text-xs break-all bg-base-200 p-2 rounded mt-1 max-h-40 overflow-auto">
                    {drawerJob.data[6]}
                  </div>
                </div>
              )}
            </div>
            <div className="modal-action">
              <button className="btn btn-sm" onClick={() => setDrawerJob(null)}>
                Close
              </button>
            </div>
          </div>
          <div className="modal-backdrop" onClick={() => setDrawerJob(null)} />
        </div>
      )}
    </div>
  );
};

export default Home;
