import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Blob "mo:base/Blob";

actor Treasury {
  stable var admin : Principal = Principal.fromText("njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae");

  // ── Canister IDs ───────────────────────────────────────────────────────────

  let LEDGER_ID  : Text = "ryjl3-tyaaa-aaaaa-aaaba-cai";
  let CMC_ID     : Text = "rkp4c-7iaaa-aaaaa-aaaca-cai";
  let LEDGER_FEE : Nat  = 10_000; // 0.0001 ICP in e8s

  // ── Actor types ────────────────────────────────────────────────────────────

  type TransferError = {
    #BadFee              : { expected_fee : Nat };
    #BadBurn             : { min_burn_amount : Nat };
    #InsufficientFunds   : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture     : { ledger_time : Nat64 };
    #Duplicate           : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError        : { error_code : Nat; message : Text };
  };

  type LedgerActor = actor {
    icrc1_transfer : shared ({
      to              : { owner : Principal; subaccount : ?Blob };
      amount          : Nat;
      fee             : ?Nat;
      memo            : ?Blob;
      from_subaccount : ?Blob;
      created_at_time : ?Nat64;
    }) -> async { #Ok : Nat; #Err : TransferError };
    icrc1_balance_of : query ({ owner : Principal; subaccount : ?Blob }) -> async Nat;
    // Legacy transfer — required by CMC notify_top_up (uses Nat64 memo + AccountIdentifier)
    transfer : shared ({
      to      : Blob;   // 32-byte account identifier
      amount  : { e8s : Nat64 };
      fee     : { e8s : Nat64 };
      memo    : Nat64;
      from_subaccount : ?Blob;
      created_at_time : ?{ timestamp_nanos : Nat64 };
    }) -> async { #Ok : Nat64; #Err : { #BadFee : { expected_fee : { e8s : Nat64 } }; #InsufficientFunds : { balance : { e8s : Nat64 } }; #TxTooOld : { allowed_window_nanos : Nat64 }; #TxCreatedInFuture; #TxDuplicate : { duplicate_of : Nat64 } } };
  };

  type CMCActor = actor {
    notify_top_up : shared ({
      block_index : Nat64;
      canister_id : Principal;
    }) -> async { #Ok : Nat; #Err : { #Refunded : { block_index : ?Nat64; reason : Text }; #InvalidTransaction : Text; #Other : { error_message : Text; error_code : Nat64 }; #Processing; #TransactionTooOld : Nat64 } };
  };

  let ledger : LedgerActor = actor(LEDGER_ID);
  let cmc    : CMCActor    = actor(CMC_ID);

  // ── Public types ───────────────────────────────────────────────────────────

  public type TransferRecord = {
    to         : Principal;
    amount     : Nat64;
    blockIndex : Nat64;
    timestamp  : Int;
    note       : Text;
  };

  public type SettleOk = { amountWon : Nat64; blockIndex : Nat64 };

  // ── Stable state ───────────────────────────────────────────────────────────

  stable var dailyPool       : Nat64 = 0;
  stable var smallPool       : Nat64 = 0;
  stable var mediumPool      : Nat64 = 0;
  stable var largePool       : Nat64 = 0;
  stable var devPrincipal    : Text  = "njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae";
  stable var isDevMode       : Bool  = false;
  stable var lotteryPrincipal : ?Principal = null;
  stable var transferHistory : [TransferRecord] = [];
  stable var lastCmcError    : Text = "none";

  // Min pool sizes before mystery can drop (in e8s)
  let MIN_SMALL  : Nat64 = 50_000_000;  // 0.5 ICP
  let MIN_MEDIUM : Nat64 = 200_000_000; // 2.0 ICP
  let MIN_LARGE  : Nat64 = 500_000_000; // 5.0 ICP

  // ── Upgrade hook ──────────────────────────────────────────────────────────

  system func postupgrade() {
    admin        := Principal.fromText("njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae");
    devPrincipal := "njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae";
    isDevMode    := false;
    cmcLotteryAccountId  := ?Blob.fromArray([46,7,15,5,226,247,37,177,20,92,19,19,237,155,195,39,113,37,21,167,226,175,174,17,205,201,219,254,107,16,176,114]);
    cmcTreasuryAccountId := ?Blob.fromArray([252,7,177,91,47,178,11,179,214,34,155,200,128,52,109,192,177,58,212,155,147,84,79,83,231,90,197,72,111,169,31,209]);
  };

  // ── Admin ──────────────────────────────────────────────────────────────────

  public shared ({ caller }) func setAdmin(p : Principal) : async () {
    assert Principal.equal(caller, admin);
    admin := p;
  };

  public shared ({ caller }) func setDevMode(b : Bool) : async () {
    assert Principal.equal(caller, admin);
    isDevMode := b;
  };

  public shared ({ caller }) func setDevPrincipal(p : Text) : async () {
    assert Principal.equal(caller, admin);
    devPrincipal := p;
  };

  public shared ({ caller }) func setLotteryCanister(p : Principal) : async () {
    assert Principal.equal(caller, admin);
    lotteryPrincipal := ?p;
  };

  // ── Auth helper ────────────────────────────────────────────────────────────

  func assertLottery(caller : Principal) {
    switch lotteryPrincipal {
      case (?lp) { assert Principal.equal(caller, lp) };
      case null  { assert Principal.equal(caller, admin) };
    };
  };

  // ── Cycles top-up helper ──────────────────────────────────────────────────
  // CMC requires a legacy `transfer` (not ICRC1) with:
  //   memo    = 0x50555054 (Nat64 "TPUP")
  //   to      = accountIdentifier(CMC, subaccount=principalToSubaccount(canisterId))
  // Then call notify_top_up(block_index, canister_id).

  // CMC account IDs are computed off-chain (SHA224 not available in Motoko base)
  // and set via setCmcAccountIds after deploy.

  // CMC account IDs: accountIdentifier(CMC, principalToSubaccount(canisterId))
  // Lottery  (m3n4c-3qaaa-aaaal-qw55a-cai): 2e070f05e2f725b1145c1313ed9bc327712515a7e2afae11cdc9dbfe6b10b072
  // Treasury (msox6-nyaaa-aaaal-qw54q-cai): fc07b15b2fb20bb3d6229bc880346dc0b13ad49b93544f53e75ac5486fa91fd1
  stable var cmcLotteryAccountId  : ?Blob = ?Blob.fromArray([46,7,15,5,226,247,37,177,20,92,19,19,237,155,195,39,113,37,21,167,226,175,174,17,205,201,219,254,107,16,176,114]);
  stable var cmcTreasuryAccountId : ?Blob = ?Blob.fromArray([252,7,177,91,47,178,11,179,214,34,155,200,128,52,109,192,177,58,212,155,147,84,79,83,231,90,197,72,111,169,31,209]);

  func topUpCanister(accountId : ?Blob, canisterId : Principal, amount : Nat64) : async () {
    if (amount == 0 or amount <= Nat64.fromNat(LEDGER_FEE)) return;
    switch accountId {
      case null {
        lastCmcError := "CMC account ID not set — call setCmcAccountIds first";
        return;
      };
      case (?accId) {
        let net = amount - Nat64.fromNat(LEDGER_FEE);
        // Legacy transfer with memo = 0x50555054 (TPUP)
        let transferRes = await ledger.transfer({
          to              = accId;
          amount          = { e8s = net };
          fee             = { e8s = Nat64.fromNat(LEDGER_FEE) };
          memo            = 0x50555054;
          from_subaccount = null;
          created_at_time = null;
        });
        switch transferRes {
          case (#Ok(blockIndex)) {
            let cmcRes = await cmc.notify_top_up({
              block_index = blockIndex;
              canister_id = canisterId;
            });
            switch cmcRes {
              case (#Ok(_))  { lastCmcError := "ok" };
              case (#Err(e)) {
                lastCmcError := switch e {
                  case (#Refunded(r))           "Refunded: " # r.reason;
                  case (#InvalidTransaction(t)) "InvalidTransaction: " # t;
                  case (#Other(o))              "Other: " # o.error_message;
                  case (#Processing)            "Processing";
                  case (#TransactionTooOld(_))  "TransactionTooOld";
                };
              };
            };
          };
          case (#Err(e)) {
            lastCmcError := switch e {
              case (#BadFee(f))           "BadFee: expected " # Nat64.toText(f.expected_fee.e8s);
              case (#InsufficientFunds(f)) "InsufficientFunds: " # Nat64.toText(f.balance.e8s);
              case (#TxTooOld(_))         "TxTooOld";
              case (#TxCreatedInFuture)   "TxCreatedInFuture";
              case (#TxDuplicate(d))      "TxDuplicate: " # Nat64.toText(d.duplicate_of);
            };
          };
        };
      };
    };
  };

  // ── Called by lottery canister at ticket purchase ──────────────────────────
  // Distributes immediately: 10% → cycles, rest splits across pools.
  // Per ticket (0.1 ICP = 10_000_000 e8s):
  //   burn/cycles : 10% = 1_000_000
  //   daily       : 54% = 5_400_000
  //   small       : 16% = 1_600_000
  //   medium      : 11% = 1_100_000
  //   large       :  7% =   700_000
  //   dev         :  2% =   200_000
  //   (total = 100%)
  public shared ({ caller }) func addTicketRevenue(amount : Nat64) : async () {
    assertLottery(caller);

    let cycles10 = amount * 10 / 100;
    let dev2     = amount *  2 / 100;
    let daily54  = amount * 54 / 100;
    let small16  = amount * 16 / 100;
    let medium11 = amount * 11 / 100;
    // large gets the remainder to avoid rounding loss
    let large7   = amount - cycles10 - dev2 - daily54 - small16 - medium11;

    dailyPool  += daily54;
    smallPool  += small16;
    mediumPool += medium11;
    largePool  += large7;

    logTopUp(cycles10);

    if (not isDevMode) {
      // Fire-and-forget top-up and dev fee — don't block the caller
      let lotteryShare  = cycles10 * 60 / 100;
      let treasuryShare = cycles10 - lotteryShare;
      let lp = lotteryPrincipal;
      ignore async {
        switch lp {
          case (?lp) {
            await topUpCanister(cmcLotteryAccountId,  lp, lotteryShare);
            await topUpCanister(cmcTreasuryAccountId, Principal.fromActor(Treasury), treasuryShare);
          };
          case null {
            await topUpCanister(cmcTreasuryAccountId, Principal.fromActor(Treasury), cycles10);
          };
        };
        if (Nat64.toNat(dev2) > LEDGER_FEE) {
          let _ = await ledger.icrc1_transfer({
            to              = { owner = Principal.fromText(devPrincipal); subaccount = null };
            amount          = Nat64.toNat(dev2) - LEDGER_FEE;
            fee             = ?LEDGER_FEE;
            memo            = null;
            from_subaccount = null;
            created_at_time = null;
          });
          recordDev(dev2);
        };
      };
    };
  };

  public query func getPools() : async {
    daily : Nat64; small : Nat64; medium : Nat64; large : Nat64;
    minSmall : Nat64; minMedium : Nat64; minLarge : Nat64;
  } {
    { daily = dailyPool; small = smallPool; medium = mediumPool; large = largePool;
      minSmall = MIN_SMALL; minMedium = MIN_MEDIUM; minLarge = MIN_LARGE }
  };

  // ── Settlement ─────────────────────────────────────────────────────────────
  // Called by lottery at end of day with winner(s).
  // smallWinner/mediumWinner/largeWinner are null if that mystery didn't drop.

  public shared ({ caller }) func settle(
    dailyWinner  : Principal,
    smallWinner  : ?Principal,
    mediumWinner : ?Principal,
    largeWinner  : ?Principal,
  ) : async Result.Result<SettleOk, Text> {
    assertLottery(caller);

    if (dailyPool == 0) return #ok({ amountWon = 0; blockIndex = 0 });

    let dp = dailyPool;
    dailyPool := 0;

    if (isDevMode) {
      record(dailyWinner, dp, "Daily Prize (dev mode)");
      switch smallWinner  { case (?w) { let s = smallPool;  smallPool  := 0; record(w, s, "Small Mystery (dev mode)") };  case null {} };
      switch mediumWinner { case (?w) { let m = mediumPool; mediumPool := 0; record(w, m, "Medium Mystery (dev mode)") }; case null {} };
      switch largeWinner  { case (?w) { let l = largePool;  largePool  := 0; record(w, l, "Large Mystery (dev mode)") };  case null {} };
      return #ok({ amountWon = dp; blockIndex = 0 });
    };

    // ── Daily winner ──────────────────────────────────────────────────────────
    let winNet = if (Nat64.toNat(dp) > LEDGER_FEE) Nat64.toNat(dp) - LEDGER_FEE else 0;
    if (winNet == 0) return #err("Daily pool too small to cover fee");

    let winRes = await ledger.icrc1_transfer({
      to              = { owner = dailyWinner; subaccount = null };
      amount          = winNet;
      fee             = ?LEDGER_FEE;
      memo            = null;
      from_subaccount = null;
      created_at_time = null;
    });
    let blockIndex : Nat64 = switch winRes {
      case (#Ok(bi)) Nat64.fromNat(bi);
      case (#Err(e)) {
        dailyPool += dp;
        return #err("Daily transfer failed: " # transferErrText(e));
      };
    };
    record(dailyWinner, dp, "Daily Prize");

    // ── Small mystery ─────────────────────────────────────────────────────────
    switch smallWinner {
      case (?w) {
        let amt = smallPool;
        smallPool := 0;
        if (Nat64.toNat(amt) > LEDGER_FEE) {
          let _ = await ledger.icrc1_transfer({
            to = { owner = w; subaccount = null }; amount = Nat64.toNat(amt) - LEDGER_FEE;
            fee = ?LEDGER_FEE; memo = null; from_subaccount = null; created_at_time = null;
          });
          record(w, amt, "Small Mystery Prize");
        };
      };
      case null {};
    };

    // ── Medium mystery ────────────────────────────────────────────────────────
    switch mediumWinner {
      case (?w) {
        let amt = mediumPool;
        mediumPool := 0;
        if (Nat64.toNat(amt) > LEDGER_FEE) {
          let _ = await ledger.icrc1_transfer({
            to = { owner = w; subaccount = null }; amount = Nat64.toNat(amt) - LEDGER_FEE;
            fee = ?LEDGER_FEE; memo = null; from_subaccount = null; created_at_time = null;
          });
          record(w, amt, "Medium Mystery Prize");
        };
      };
      case null {};
    };

    // ── Large mystery ─────────────────────────────────────────────────────────
    switch largeWinner {
      case (?w) {
        let amt = largePool;
        largePool := 0;
        if (Nat64.toNat(amt) > LEDGER_FEE) {
          let _ = await ledger.icrc1_transfer({
            to = { owner = w; subaccount = null }; amount = Nat64.toNat(amt) - LEDGER_FEE;
            fee = ?LEDGER_FEE; memo = null; from_subaccount = null; created_at_time = null;
          });
          record(w, amt, "Large Mystery Prize");
        };
      };
      case null {};
    };

    #ok({ amountWon = Nat64.fromNat(winNet); blockIndex })
  };

  // ── Helpers ────────────────────────────────────────────────────────────────

  func transferErrText(e : TransferError) : Text {
    switch e {
      case (#InsufficientFunds(_))   "Insufficient funds in treasury";
      case (#BadFee(_))              "Bad fee";
      case (#TemporarilyUnavailable) "Ledger temporarily unavailable";
      case (#GenericError(g))        g.message;
      case _                         "Transfer error";
    }
  };

  func record(to : Principal, amount : Nat64, note : Text) {
    if (amount == 0) return;
    let rec : TransferRecord = { to; amount; blockIndex = 0; timestamp = Time.now(); note };
    let buf = Buffer.fromArray<TransferRecord>(transferHistory);
    buf.add(rec);
    transferHistory := Buffer.toArray(buf);
  };

  func recordDev(amount : Nat64) {
    if (amount == 0) return;
    record(Principal.fromText(devPrincipal), amount, "Developer fee (2%)");
  };

  func logTopUp(amount : Nat64) {
    if (amount == 0) return;
    let rec : TransferRecord = {
      to        = Principal.fromText(CMC_ID);
      amount;
      blockIndex = 0;
      timestamp  = Time.now();
      note       = "Cycles top-up (10%)";
    };
    let buf = Buffer.fromArray<TransferRecord>(transferHistory);
    buf.add(rec);
    transferHistory := Buffer.toArray(buf);
  };

  // ── Queries ────────────────────────────────────────────────────────────────

  public query func getMyWinnings(who : Principal) : async Nat64 {
    var total : Nat64 = 0;
    for (r in transferHistory.vals()) {
      if (Principal.equal(r.to, who) and
          r.note != "Cycles top-up (10%)" and
          r.note != "Developer fee (2%)") {
        total += r.amount;
      };
    };
    total
  };

  public query func getLastCmcError() : async Text { lastCmcError };


  public query func getTransferHistory() : async [TransferRecord] {
    let t = transferHistory.size();
    Array.tabulate<TransferRecord>(t, func(i) { transferHistory[t - 1 - i] })
  };

  public query func getTransferHistoryPaged(offset : Nat, limit : Nat) : async [TransferRecord] {
    let t = transferHistory.size();
    if (offset >= t) return [];
    let rev = Array.tabulate<TransferRecord>(t, func(i) { transferHistory[t - 1 - i] });
    Array.tabulate<TransferRecord>(Nat.min(offset + limit, t) - offset, func(i) { rev[offset + i] })
  };
}
