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

  return IDL.Service({
    getPools:                IDL.Func([], [Pools], ["query"]),
    getMyWinnings:           IDL.Func([IDL.Principal], [IDL.Nat64], ["query"]),
    getTransferHistory:      IDL.Func([], [IDL.Vec(TransferRecord)], ["query"]),
    getTransferHistoryPaged: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Vec(TransferRecord)], ["query"]),
    setDevMode:              IDL.Func([IDL.Bool], [], []),
    setDevPrincipal:         IDL.Func([IDL.Text], [], []),
    setLotteryCanister:      IDL.Func([IDL.Principal], [], []),
  });
};
