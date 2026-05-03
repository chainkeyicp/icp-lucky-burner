import { IDL } from "@dfinity/candid";

export const treasuryIdl = ({ IDL: _ } = { IDL }) => {
  const TransferRecord = IDL.Record({
    to:         IDL.Principal,
    amount:     IDL.Nat64,
    blockIndex: IDL.Nat64,
    timestamp:  IDL.Int,
    note:       IDL.Text,
  });

  const Pools = IDL.Record({
    daily:     IDL.Nat64,
    small:     IDL.Nat64,
    medium:    IDL.Nat64,
    large:     IDL.Nat64,
    minSmall:  IDL.Nat64,
    minMedium: IDL.Nat64,
    minLarge:  IDL.Nat64,
  });

  const CyclesHealth = IDL.Record({
    balance:                IDL.Nat,
    lastCmcError:           IDL.Text,
    lastTopUpAt:            IDL.Int,
    lastTopUpAmount:        IDL.Nat64,
    lastSettleCyclesBefore: IDL.Nat,
    lastSettleCyclesAfter:  IDL.Nat,
    lastSettleCyclesDelta:  IDL.Int,
    lotteryConfigured:      IDL.Bool,
    frontendConfigured:     IDL.Bool,
    historySize:            IDL.Nat,
    maxHistorySize:         IDL.Nat,
  });

  const TreasuryAccounting = IDL.Record({
    ledgerBalance:      IDL.Nat,
    totalPools:         IDL.Nat,
    unallocatedBalance: IDL.Nat,
    poolDeficit:        IDL.Nat,
    dailyPool:          IDL.Nat64,
    smallPool:          IDL.Nat64,
    mediumPool:         IDL.Nat64,
    largePool:          IDL.Nat64,
    minSmall:           IDL.Nat64,
    minMedium:          IDL.Nat64,
    minLarge:           IDL.Nat64,
    lastCmcError:       IDL.Text,
    lastPayoutError:    IDL.Text,
    lastPayoutAt:       IDL.Int,
    lastPayoutNote:     IDL.Text,
  });

  return IDL.Service({
    getCyclesHealth:         IDL.Func([], [CyclesHealth], ["query"]),
    getLastCmcError:         IDL.Func([], [IDL.Text], ["query"]),
    getPools:                IDL.Func([], [Pools], ["query"]),
    getTreasuryAccounting:   IDL.Func([], [TreasuryAccounting], []),
    getMyWinnings:           IDL.Func([IDL.Principal], [IDL.Nat64], ["query"]),
    getTransferHistory:      IDL.Func([], [IDL.Vec(TransferRecord)], ["query"]),
    getTransferHistoryPaged: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Vec(TransferRecord)], ["query"]),
    setCmcAccountIds:        IDL.Func([IDL.Vec(IDL.Nat8), IDL.Vec(IDL.Nat8), IDL.Vec(IDL.Nat8)], [], []),
    setDevMode:              IDL.Func([IDL.Bool], [], []),
    setDevPrincipal:         IDL.Func([IDL.Text], [], []),
    setFrontendCanister:     IDL.Func([IDL.Principal], [], []),
    setLotteryCanister:      IDL.Func([IDL.Principal], [], []),
  });
};
