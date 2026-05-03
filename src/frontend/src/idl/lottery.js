import { IDL } from "@icp-sdk/core/candid";

export const lotteryIdl = ({ IDL: _ } = { IDL }) => {
  const WinnerRecord = IDL.Record({
    roundId:      IDL.Nat,
    winner:       IDL.Principal,
    amountWon:    IDL.Nat64,
    blockIndex:   IDL.Nat64,
    timestamp:    IDL.Int,
    ticketsSold:  IDL.Nat,
    smallWinner:  IDL.Opt(IDL.Principal),
    mediumWinner: IDL.Opt(IDL.Principal),
    largeWinner:  IDL.Opt(IDL.Principal),
    smallAmt:     IDL.Nat64,
    mediumAmt:    IDL.Nat64,
    largeAmt:     IDL.Nat64,
  });

  const RoundStatus = IDL.Record({
    roundId:     IDL.Nat,
    ticketsSold: IDL.Nat,
    myTickets:   IDL.Nat,
    dailyPool:   IDL.Nat64,
    smallPool:   IDL.Nat64,
    mediumPool:  IDL.Nat64,
    largePool:   IDL.Nat64,
    minSmall:    IDL.Nat64,
    minMedium:   IDL.Nat64,
    minLarge:    IDL.Nat64,
    roundStart:  IDL.Int,
    roundEnd:    IDL.Int,
  });

  const PurchaseRecord = IDL.Record({
    buyer:     IDL.Principal,
    count:     IDL.Nat,
    timestamp: IDL.Int,
    roundId:   IDL.Nat,
  });

  const CyclesHealth = IDL.Record({
    balance:              IDL.Nat,
    lastBuyCyclesBefore:  IDL.Nat,
    lastBuyCyclesAfter:   IDL.Nat,
    lastBuyCyclesDelta:   IDL.Int,
    lastDrawCyclesBefore: IDL.Nat,
    lastDrawCyclesAfter:  IDL.Nat,
    lastDrawCyclesDelta:  IDL.Int,
    historySize:          IDL.Nat,
    snapshotSize:         IDL.Nat,
    maxHistorySize:       IDL.Nat,
  });

  const AutonomyUsageStats = IDL.Record({
    samples:             IDL.Nat,
    avgDailyCyclesUsed:  IDL.Nat,
    avgTicketsPerRound:  IDL.Nat,
    totalCyclesUsed:     IDL.Nat,
    totalTickets:        IDL.Nat,
  });

  const Result = IDL.Variant({ ok: IDL.Text, err: IDL.Text });

  return IDL.Service({
    buyTickets:            IDL.Func([IDL.Nat],          [Result],        []),
    getRecentPurchases:    IDL.Func([],                 [IDL.Vec(PurchaseRecord)], ["query"]),
    getRoundTickets:       IDL.Func([IDL.Nat],          [IDL.Vec(IDL.Tuple(IDL.Principal, IDL.Nat))], ["query"]),
    getRoundStatus:        IDL.Func([],                 [RoundStatus],   ["query"]),
    getCyclesHealth:       IDL.Func([],                 [CyclesHealth],  ["query"]),
    getAutonomyUsageStats: IDL.Func([IDL.Nat],          [AutonomyUsageStats], ["query"]),
    getMyRounds:           IDL.Func([IDL.Principal],    [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat, IDL.Nat))], ["query"]),
    getWinnerHistory:      IDL.Func([],                 [IDL.Vec(WinnerRecord)], ["query"]),
    getWinnerHistoryPaged: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Vec(WinnerRecord)], ["query"]),
  });
};
