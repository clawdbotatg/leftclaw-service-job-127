"use client";

import { useMemo, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatUnits } from "viem";
import { useScaffoldEventHistory, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

type ActivityItem = {
  type: "Registered" | "Executed" | "Cancelled" | "Reclaimed";
  jobId: bigint;
  blockNumber: bigint;
  detail: string;
};

const StatsPage: NextPage = () => {
  const [sweeping, setSweeping] = useState(false);

  const { data: registeredEvents } = useScaffoldEventHistory({
    contractName: "CronBond",
    eventName: "JobRegistered",
    fromBlock: 0n,
    watch: true,
  });
  const { data: executedEvents } = useScaffoldEventHistory({
    contractName: "CronBond",
    eventName: "JobExecuted",
    fromBlock: 0n,
    watch: true,
  });
  const { data: cancelledEvents } = useScaffoldEventHistory({
    contractName: "CronBond",
    eventName: "JobCancelled",
    fromBlock: 0n,
    watch: true,
  });
  const { data: reclaimedEvents } = useScaffoldEventHistory({
    contractName: "CronBond",
    eventName: "JobReclaimedStale",
    fromBlock: 0n,
    watch: true,
  });

  const { data: protocolFeesAccrued } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "protocolFeesAccrued",
  });
  const { data: minBond } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "minBond",
  });
  const { data: protocolFeeBps } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "protocolFeeBps",
  });
  const { data: cancellationFeeBps } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "cancellationFeeBps",
  });
  const { data: cancellationFeeFloor } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "cancellationFeeFloor",
  });
  const { data: staleWindow } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "staleWindow",
  });
  const { data: minDelay } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "minDelay",
  });
  const { data: maxDelay } = useScaffoldReadContract({
    contractName: "CronBond",
    functionName: "maxDelay",
  });

  const totalBonded = useMemo<bigint>(() => {
    if (!registeredEvents) return 0n;
    let sum = 0n;
    for (const ev of registeredEvents) {
      const args = ev.args as { bondAmount?: bigint } | undefined;
      if (args?.bondAmount) sum += args.bondAmount;
    }
    return sum;
  }, [registeredEvents]);

  const totalKeeperPayouts = useMemo<bigint>(() => {
    if (!executedEvents) return 0n;
    let sum = 0n;
    for (const ev of executedEvents) {
      const args = ev.args as { keeperPayout?: bigint } | undefined;
      if (args?.keeperPayout) sum += args.keeperPayout;
    }
    return sum;
  }, [executedEvents]);

  const totalProtocolFees = useMemo<bigint>(() => {
    let sum = 0n;
    if (executedEvents && registeredEvents) {
      // protocol fee on execution = bond - keeperPayout (per event); we approximate via bondAmount lookup
      const bondById = new Map<string, bigint>();
      for (const ev of registeredEvents) {
        const args = ev.args as { jobId?: bigint; bondAmount?: bigint } | undefined;
        if (args?.jobId !== undefined && args.bondAmount !== undefined) {
          bondById.set(args.jobId.toString(), args.bondAmount);
        }
      }
      for (const ev of executedEvents) {
        const args = ev.args as { jobId?: bigint; keeperPayout?: bigint } | undefined;
        if (args?.jobId !== undefined && args.keeperPayout !== undefined) {
          const bond = bondById.get(args.jobId.toString());
          if (bond !== undefined) sum += bond - args.keeperPayout;
        }
      }
    }
    if (cancelledEvents) {
      for (const ev of cancelledEvents) {
        const args = ev.args as { cancellationFee?: bigint } | undefined;
        if (args?.cancellationFee) sum += args.cancellationFee;
      }
    }
    if (reclaimedEvents) {
      for (const ev of reclaimedEvents) {
        const args = ev.args as { fee?: bigint } | undefined;
        if (args?.fee) sum += args.fee;
      }
    }
    return sum;
  }, [executedEvents, registeredEvents, cancelledEvents, reclaimedEvents]);

  const topKeepers = useMemo(() => {
    const map = new Map<string, { earned: bigint; count: number }>();
    if (executedEvents) {
      for (const ev of executedEvents) {
        const args = ev.args as { keeper?: `0x${string}`; keeperPayout?: bigint } | undefined;
        if (!args?.keeper) continue;
        const cur = map.get(args.keeper) ?? { earned: 0n, count: 0 };
        cur.earned += args.keeperPayout ?? 0n;
        cur.count += 1;
        map.set(args.keeper, cur);
      }
    }
    return Array.from(map.entries())
      .map(([addr, v]) => ({ address: addr as `0x${string}`, ...v }))
      .sort((a, b) => (a.earned > b.earned ? -1 : a.earned < b.earned ? 1 : 0))
      .slice(0, 10);
  }, [executedEvents]);

  const topRegistrants = useMemo(() => {
    const map = new Map<string, { bonded: bigint; count: number }>();
    if (registeredEvents) {
      for (const ev of registeredEvents) {
        const args = ev.args as { registrant?: `0x${string}`; bondAmount?: bigint } | undefined;
        if (!args?.registrant) continue;
        const cur = map.get(args.registrant) ?? { bonded: 0n, count: 0 };
        cur.bonded += args.bondAmount ?? 0n;
        cur.count += 1;
        map.set(args.registrant, cur);
      }
    }
    return Array.from(map.entries())
      .map(([addr, v]) => ({ address: addr as `0x${string}`, ...v }))
      .sort((a, b) => (a.bonded > b.bonded ? -1 : a.bonded < b.bonded ? 1 : 0))
      .slice(0, 10);
  }, [registeredEvents]);

  const recentActivity = useMemo<ActivityItem[]>(() => {
    const items: ActivityItem[] = [];
    if (registeredEvents) {
      for (const ev of registeredEvents) {
        const args = ev.args as { jobId?: bigint; bondAmount?: bigint } | undefined;
        if (!args?.jobId || ev.blockNumber === undefined) continue;
        items.push({
          type: "Registered",
          jobId: args.jobId,
          blockNumber: ev.blockNumber as bigint,
          detail: `${formatUnits(args.bondAmount ?? 0n, 6)} USDC bond`,
        });
      }
    }
    if (executedEvents) {
      for (const ev of executedEvents) {
        const args = ev.args as { jobId?: bigint; keeperPayout?: bigint; success?: boolean } | undefined;
        if (!args?.jobId || ev.blockNumber === undefined) continue;
        items.push({
          type: "Executed",
          jobId: args.jobId,
          blockNumber: ev.blockNumber as bigint,
          detail: `${args.success ? "ok" : "failed"} • payout ${formatUnits(args.keeperPayout ?? 0n, 6)} USDC`,
        });
      }
    }
    if (cancelledEvents) {
      for (const ev of cancelledEvents) {
        const args = ev.args as { jobId?: bigint; refunded?: bigint } | undefined;
        if (!args?.jobId || ev.blockNumber === undefined) continue;
        items.push({
          type: "Cancelled",
          jobId: args.jobId,
          blockNumber: ev.blockNumber as bigint,
          detail: `refunded ${formatUnits(args.refunded ?? 0n, 6)} USDC`,
        });
      }
    }
    if (reclaimedEvents) {
      for (const ev of reclaimedEvents) {
        const args = ev.args as { jobId?: bigint; refunded?: bigint } | undefined;
        if (!args?.jobId || ev.blockNumber === undefined) continue;
        items.push({
          type: "Reclaimed",
          jobId: args.jobId,
          blockNumber: ev.blockNumber as bigint,
          detail: `refunded ${formatUnits(args.refunded ?? 0n, 6)} USDC`,
        });
      }
    }
    items.sort((a, b) => (a.blockNumber > b.blockNumber ? -1 : a.blockNumber < b.blockNumber ? 1 : 0));
    return items.slice(0, 20);
  }, [registeredEvents, executedEvents, cancelledEvents, reclaimedEvents]);

  const { writeContractAsync: cronBondWriteAsync } = useScaffoldWriteContract({
    contractName: "CronBond",
  });

  const handleSweep = async () => {
    setSweeping(true);
    try {
      await cronBondWriteAsync({ functionName: "withdrawProtocolFees" });
      notification.success("Protocol fees swept to treasury");
    } catch (err: any) {
      notification.error(err?.message ?? "Sweep failed");
    } finally {
      setSweeping(false);
    }
  };

  const formatBadgeClass: Record<ActivityItem["type"], string> = {
    Registered: "badge-success",
    Executed: "badge-info",
    Cancelled: "badge-neutral",
    Reclaimed: "badge-warning",
  };

  return (
    <div className="flex flex-col grow px-5 py-8 max-w-6xl mx-auto w-full">
      <h1 className="text-3xl font-bold mb-6">Stats</h1>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Registered</div>
          <div className="stat-value text-2xl">{registeredEvents?.length ?? 0}</div>
        </div>
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Executed</div>
          <div className="stat-value text-2xl">{executedEvents?.length ?? 0}</div>
        </div>
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Cancelled</div>
          <div className="stat-value text-2xl">{cancelledEvents?.length ?? 0}</div>
        </div>
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Reclaimed</div>
          <div className="stat-value text-2xl">{reclaimedEvents?.length ?? 0}</div>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-3 mb-6">
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Total Bonded</div>
          <div className="stat-value text-xl">{formatUnits(totalBonded, 6)} USDC</div>
        </div>
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Keeper Payouts</div>
          <div className="stat-value text-xl">{formatUnits(totalKeeperPayouts, 6)} USDC</div>
        </div>
        <div className="stat bg-base-100 rounded-lg shadow">
          <div className="stat-title">Protocol Fees (lifetime)</div>
          <div className="stat-value text-xl">{formatUnits(totalProtocolFees, 6)} USDC</div>
        </div>
      </div>

      <div className="card bg-base-100 shadow mb-6">
        <div className="card-body flex-row justify-between items-center">
          <div>
            <h3 className="card-title text-base">Protocol Fees Accrued</h3>
            <p className="font-mono">
              {protocolFeesAccrued !== undefined ? formatUnits(protocolFeesAccrued, 6) : "—"} USDC
            </p>
          </div>
          <button
            className="btn btn-primary btn-sm"
            onClick={handleSweep}
            disabled={sweeping || !protocolFeesAccrued || protocolFeesAccrued === 0n}
          >
            {sweeping ? <span className="loading loading-spinner loading-sm" /> : "Sweep to Treasury"}
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
        <div className="card bg-base-100 shadow">
          <div className="card-body">
            <h3 className="card-title text-base">Top Keepers</h3>
            {topKeepers.length === 0 ? (
              <p className="opacity-70 text-sm">No executions yet.</p>
            ) : (
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>Address</th>
                    <th>Earned</th>
                    <th>Jobs</th>
                  </tr>
                </thead>
                <tbody>
                  {topKeepers.map(k => (
                    <tr key={k.address}>
                      <td>
                        <Address address={k.address} format="short" size="sm" />
                      </td>
                      <td className="font-mono">{formatUnits(k.earned, 6)}</td>
                      <td className="font-mono">{k.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
        <div className="card bg-base-100 shadow">
          <div className="card-body">
            <h3 className="card-title text-base">Top Registrants</h3>
            {topRegistrants.length === 0 ? (
              <p className="opacity-70 text-sm">No registrations yet.</p>
            ) : (
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>Address</th>
                    <th>Bonded</th>
                    <th>Jobs</th>
                  </tr>
                </thead>
                <tbody>
                  {topRegistrants.map(r => (
                    <tr key={r.address}>
                      <td>
                        <Address address={r.address} format="short" size="sm" />
                      </td>
                      <td className="font-mono">{formatUnits(r.bonded, 6)}</td>
                      <td className="font-mono">{r.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
      </div>

      <div className="card bg-base-100 shadow mb-6">
        <div className="card-body">
          <h3 className="card-title text-base">Recent Activity</h3>
          {recentActivity.length === 0 ? (
            <p className="opacity-70 text-sm">No activity yet.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>Type</th>
                    <th>Job ID</th>
                    <th>Detail</th>
                    <th>Block</th>
                  </tr>
                </thead>
                <tbody>
                  {recentActivity.map((item, i) => (
                    <tr key={`${item.blockNumber}-${item.jobId}-${i}`}>
                      <td>
                        <span className={`badge badge-sm ${formatBadgeClass[item.type]}`}>{item.type}</span>
                      </td>
                      <td className="font-mono">{item.jobId.toString()}</td>
                      <td className="text-sm">{item.detail}</td>
                      <td className="font-mono text-xs">{item.blockNumber.toString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      <div className="card bg-base-100 shadow">
        <div className="card-body">
          <h3 className="card-title text-base">Owner Knobs</h3>
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
            <div>
              <div className="opacity-60">minBond</div>
              <div className="font-mono">{minBond !== undefined ? `${formatUnits(minBond, 6)} USDC` : "—"}</div>
            </div>
            <div>
              <div className="opacity-60">protocolFeeBps</div>
              <div className="font-mono">{protocolFeeBps !== undefined ? `${protocolFeeBps} bps` : "—"}</div>
            </div>
            <div>
              <div className="opacity-60">cancellationFeeBps</div>
              <div className="font-mono">{cancellationFeeBps !== undefined ? `${cancellationFeeBps} bps` : "—"}</div>
            </div>
            <div>
              <div className="opacity-60">cancellationFeeFloor</div>
              <div className="font-mono">
                {cancellationFeeFloor !== undefined ? `${formatUnits(cancellationFeeFloor, 6)} USDC` : "—"}
              </div>
            </div>
            <div>
              <div className="opacity-60">staleWindow</div>
              <div className="font-mono">
                {staleWindow !== undefined ? `${(Number(staleWindow) / 86_400).toFixed(1)} days` : "—"}
              </div>
            </div>
            <div>
              <div className="opacity-60">minDelay</div>
              <div className="font-mono">{minDelay !== undefined ? `${minDelay}s` : "—"}</div>
            </div>
            <div>
              <div className="opacity-60">maxDelay</div>
              <div className="font-mono">
                {maxDelay !== undefined ? `${(Number(maxDelay) / 86_400).toFixed(0)} days` : "—"}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default StatsPage;
