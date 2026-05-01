import { IDL } from "@dfinity/candid";

export const ledgerIdl = ({ IDL: _ } = { IDL }) => {
  const Account = IDL.Record({
    owner:      IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });

  const ApproveArgs = IDL.Record({
    spender:            Account,
    amount:             IDL.Nat,
    fee:                IDL.Opt(IDL.Nat),
    memo:               IDL.Opt(IDL.Vec(IDL.Nat8)),
    from_subaccount:    IDL.Opt(IDL.Vec(IDL.Nat8)),
    expected_allowance: IDL.Opt(IDL.Nat),
    expires_at:         IDL.Opt(IDL.Nat64),
    created_at_time:    IDL.Opt(IDL.Nat64),
  });

  const ApproveError = IDL.Variant({
    BadFee:              IDL.Record({ expected_fee: IDL.Nat }),
    InsufficientFunds:   IDL.Record({ balance: IDL.Nat }),
    AllowanceChanged:    IDL.Record({ current_allowance: IDL.Nat }),
    Expired:             IDL.Record({ ledger_time: IDL.Nat64 }),
    TooOld:              IDL.Null,
    CreatedInFuture:     IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate:           IDL.Record({ duplicate_of: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    GenericError:        IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
  });

  const TransferError = IDL.Variant({
    BadFee:              IDL.Record({ expected_fee: IDL.Nat }),
    BadBurn:             IDL.Record({ min_burn_amount: IDL.Nat }),
    InsufficientFunds:   IDL.Record({ balance: IDL.Nat }),
    InsufficientAllowance: IDL.Record({ allowance: IDL.Nat }),
    TooOld:              IDL.Null,
    CreatedInFuture:     IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate:           IDL.Record({ duplicate_of: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    GenericError:        IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
  });

  const TransferFromArgs = IDL.Record({
    spender_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
    from:               Account,
    to:                 Account,
    amount:             IDL.Nat,
    fee:                IDL.Opt(IDL.Nat),
    memo:               IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time:    IDL.Opt(IDL.Nat64),
  });

  const TransferArgs = IDL.Record({
    to:              Account,
    amount:          IDL.Nat,
    fee:             IDL.Opt(IDL.Nat),
    memo:            IDL.Opt(IDL.Vec(IDL.Nat8)),
    from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  });

  return IDL.Service({
    icrc1_balance_of:    IDL.Func([Account],       [IDL.Nat], ["query"]),
    icrc1_transfer:      IDL.Func([TransferArgs],  [IDL.Variant({ Ok: IDL.Nat, Err: TransferError })], []),
    icrc2_approve:       IDL.Func([ApproveArgs],   [IDL.Variant({ Ok: IDL.Nat, Err: ApproveError })],  []),
    icrc2_transfer_from: IDL.Func([TransferFromArgs], [IDL.Variant({ Ok: IDL.Nat, Err: TransferError })], []),
  });
};
