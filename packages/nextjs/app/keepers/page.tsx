"use client";

import { useEffect, useMemo, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { Abi, formatUnits } from "viem";
import { useAccount, usePublicClient, useSwitchChain } from "wagmi";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import {
  useDeployedContractInfo,
  useScaffoldEventHistory,
  useScaffoldWriteContract,
  useTargetNetwork,
  useWriteAndOpen,
} from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";
import { contracts } from "~~/utils/scaffold-eth/contract";

type SortKey = "bondDesc" | "executeAtAsc";

type ExecutableJob = {
  jobId: bigint;
  target: `0x${string}`;
  executeAt: bigint;
  bondAmount: bigint;
  maxGas: number;
};

type JobTuple = readonly [`0x${string}`, bigint, number, `0x${string}`, number, bigint, `0x${string}`, `0x${string}`];

const KeepersPage: NextPage = () => {
  const { isConnected, chain: accountChain } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const { switchChain, isPending: switchPending } = useSwitchChain();
  const { writeAndOpen } = useWriteAndOpen();
  const publicClient = usePublicClient({ chainId: targetNetwork.id });

  const [sortKey, setSortKey] = useState<SortKey>("bondDesc");
  const [statuses, setStatuses] = useState<Record<string, JobTuple | undefined>>({});
  const [staleWindow, setStaleWindow] = useState<bigint | undefined>(undefined);
  const [executingId, setExecutingId] = useState<bigint | null>(null);
  const [now, setNow] = useState<number>(() => Date.now());

  const { data: cronBondInfo } = useDeployedContractInfo({ contractName: "CronBond" });

  // Read events
  const { data: events, isLoading: eventsLoading } = useScaffoldEventHistory({
    contractName: "CronBond",
    eventName: "JobRegistered",
    fromBlock: 0n,
    watch: true,
  });

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  // Multicall jobs(id) for each registered event
  useEffect(() => {
    const run = async () => {
      const cronAddress = (contracts?.[targetNetwork.id]?.["CronBond"]?.address ?? undefined) as
        | `0x${string}`
        | undefined;
      const cronAbi = contracts?.[targetNetwork.id]?.["CronBond"]?.abi as Abi | undefined;
      if (!publicClient || !events || !cronAddress || !cronAbi) return;
      const jobIds = Array.from(
        new Set(
          events
            .map(e => (e.args as { jobId?: bigint } | undefined)?.jobId?.toString())
            .filter((s): s is string => !!s),
        ),
      );
      if (jobIds.length === 0) return;
      try {
        const results = await publicClient.multicall({
          contracts: jobIds.map(idStr => ({
            address: cronAddress,
            abi: cronAbi,
            functionName: "jobs",
            args: [BigInt(idStr)],
          })),
          allowFailure: true,
        });
        const next: Record<string, JobTuple | undefined> = {};
        results.forEach((r, i) => {
          if (r.status === "success") {
            next[jobIds[i]] = r.result as unknown as JobTuple;
          }
        });
        setStatuses(next);

        // Read staleWindow alongside
        const sw = await publicClient.readContract({
          address: cronAddress,
          abi: cronAbi,
          functionName: "staleWindow",
        });
        setStaleWindow(sw as bigint);
      } catch (err) {
        console.error("multicall failed", err);
      }
    };
    void run();
  }, [events, publicClient, targetNetwork.id]);

  const executableJobs = useMemo<ExecutableJob[]>(() => {
    if (!events) return [];
    const nowSec = BigInt(Math.floor(now / 1000));
    const list: ExecutableJob[] = [];
    const seen = new Set<string>();
    for (const ev of events) {
      const args = ev.args as
        | {
            jobId?: bigint;
            target?: `0x${string}`;
            executeAt?: bigint;
            bondAmount?: bigint;
            maxGas?: number;
          }
        | undefined;
      if (!args?.jobId || !args.target || args.executeAt === undefined || args.bondAmount === undefined) continue;
      const idStr = args.jobId.toString();
      if (seen.has(idStr)) continue;
      seen.add(idStr);
      const status = statuses[idStr];
      if (!status) continue;
      const jobStatus = status[4];
      if (jobStatus !== 0) continue; // only Active
      if (nowSec < args.executeAt) continue; // not yet executable
      if (staleWindow !== undefined && nowSec >= args.executeAt + staleWindow) continue; // stale already
      list.push({
        jobId: args.jobId,
        target: args.target,
        executeAt: args.executeAt,
        bondAmount: args.bondAmount,
        maxGas: args.maxGas ?? 0,
      });
    }
    if (sortKey === "bondDesc") {
      list.sort((a, b) => (a.bondAmount > b.bondAmount ? -1 : a.bondAmount < b.bondAmount ? 1 : 0));
    } else {
      list.sort((a, b) => (a.executeAt < b.executeAt ? -1 : a.executeAt > b.executeAt ? 1 : 0));
    }
    return list;
  }, [events, statuses, staleWindow, sortKey, now]);

  const { writeContractAsync: cronBondWriteAsync } = useScaffoldWriteContract({
    contractName: "CronBond",
  });

  const handleExecute = async (job: ExecutableJob) => {
    setExecutingId(job.jobId);
    try {
      const totalGas = BigInt(job.maxGas) + 100_000n;
      const txHash = await writeAndOpen(() =>
        cronBondWriteAsync({
          functionName: "execute",
          args: [job.jobId],
          gas: totalGas,
        } as any),
      );
      notification.success(`Execution sent. Tx: ${txHash?.slice(0, 10) ?? "submitted"}…`);
    } catch (err: any) {
      notification.error(err?.message ?? "Execute failed");
    } finally {
      setExecutingId(null);
    }
  };

  const wrongNetwork = isConnected && accountChain?.id !== targetNetwork.id;

  // Suppress unused var lint while preserving the read
  void cronBondInfo;

  return (
    <div className="flex flex-col grow px-5 py-8 max-w-6xl mx-auto w-full">
      <div className="flex justify-between items-center mb-4 flex-wrap gap-2">
        <h1 className="text-3xl font-bold">Keeper Queue</h1>
        <div className="flex gap-2 items-center">
          <span className="text-sm opacity-70">Sort:</span>
          <select
            className="select select-bordered select-sm"
            value={sortKey}
            onChange={e => setSortKey(e.target.value as SortKey)}
          >
            <option value="bondDesc">Bond (high → low)</option>
            <option value="executeAtAsc">Execute At (soonest)</option>
          </select>
        </div>
      </div>

      <div className="alert alert-warning shadow-sm mb-4 text-sm">
        <span>
          <strong>Race disclosure:</strong> First keeper wins. Losing transactions revert and lose gas. Use a bot for
          production.
        </span>
      </div>

      <div className="card bg-base-100 shadow">
        <div className="card-body p-4">
          {eventsLoading && executableJobs.length === 0 ? (
            <div className="flex justify-center py-12">
              <span className="loading loading-spinner loading-lg" />
            </div>
          ) : executableJobs.length === 0 ? (
            <div className="text-center py-12 opacity-70">No executable jobs right now. Check back soon.</div>
          ) : (
            <div className="overflow-x-auto">
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>Job ID</th>
                    <th>Target</th>
                    <th>Bond (USDC)</th>
                    <th>Execute At</th>
                    <th>Max Gas</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  {executableJobs.map(job => (
                    <tr key={job.jobId.toString()}>
                      <td className="font-mono">{job.jobId.toString()}</td>
                      <td>
                        <Address address={job.target} format="short" size="sm" />
                      </td>
                      <td className="font-mono text-sm">{formatUnits(job.bondAmount, 6)}</td>
                      <td className="text-sm">{new Date(Number(job.executeAt) * 1000).toLocaleString()}</td>
                      <td className="font-mono text-sm">{job.maxGas.toLocaleString()}</td>
                      <td>
                        {!isConnected ? (
                          <RainbowKitCustomConnectButton />
                        ) : wrongNetwork ? (
                          <button
                            className="btn btn-xs btn-warning"
                            onClick={() => switchChain({ chainId: targetNetwork.id })}
                            disabled={switchPending}
                          >
                            Switch network
                          </button>
                        ) : (
                          <div className="tooltip" data-tip="First keeper wins. Losing txs revert.">
                            <button
                              className="btn btn-xs btn-primary"
                              onClick={() => handleExecute(job)}
                              disabled={executingId === job.jobId}
                            >
                              {executingId === job.jobId ? (
                                <span className="loading loading-spinner loading-xs" />
                              ) : (
                                "Execute"
                              )}
                            </button>
                          </div>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default KeepersPage;
