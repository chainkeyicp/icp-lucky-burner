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
import Cycles "mo:base/ExperimentalCycles";
import Timer "mo:base/Timer";

persistent actor Treasury {
  // ── Canister IDs ───────────────────────────────────────────────────────────

  transient let LEDGER_ID  : Text = "ryjl3-tyaaa-aaaaa-aaaba-cai";
  transient let CMC_ID     : Text = "rkp4c-7iaaa-aaaaa-aaaca-cai";
  transient let LEDGER_FEE : Nat  = 10_000; // 0.0001 ICP in e8s
  transient let MAX_TRANSFER_HISTORY : Nat = 1_000;
  transient let MAX_PAYOUT_RETRIES : Nat = 10;
  transient let PAYOUT_RETRY_INTERVAL_NANOS : Nat = 300_000_000_000; // 5 minutes
  transient let DEV_PRINCIPAL : Text = "njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae";

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

  transient let ledger : LedgerActor = actor(LEDGER_ID);
  transient let cmc    : CMCActor    = actor(CMC_ID);

  // ── Public types ───────────────────────────────────────────────────────────

  public type TransferRecord = {
    to         : Principal;
    amount     : Nat64;
    blockIndex : Nat64;
    timestamp  : Int;
    note       : Text;
  };

  public type TopUpAuditRecord = {
    canister     : Principal;
    canisterName : Text;
    amount       : Nat64;
    netAmount    : Nat64;
    blockIndex   : Nat64;
    cyclesMinted : Nat;
    timestamp    : Int;
    status       : Text;
    error        : Text;
  };

  public type PendingPayout = {
    id         : Nat;
    to         : Principal;
    amount     : Nat64;
    note       : Text;
    retryCount : Nat;
    nextRetryAt : Int;
    lastError  : Text;
    status     : Text;
    blockIndex : Nat64;
    createdAt  : Int;
    updatedAt  : Int;
  };

  public type SettleOk = { amountWon : Nat64; blockIndex : Nat64 };

  public type CyclesHealth = {
    balance                : Nat;
    lastCmcError           : Text;
    lastTopUpAt            : Int;
    lastTopUpAmount        : Nat64;
    frontendCyclesKnown    : Nat;
    frontendCyclesUpdatedAt : Int;
    lastSettleCyclesBefore : Nat;
    lastSettleCyclesAfter  : Nat;
    lastSettleCyclesDelta  : Int;
    lotteryConfigured      : Bool;
    frontendConfigured     : Bool;
    historySize            : Nat;
    maxHistorySize         : Nat;
  };

  public type TreasuryAccounting = {
    ledgerBalance          : Nat;
    totalPools             : Nat;
    unallocatedBalance     : Nat;
    poolDeficit            : Nat;
    dailyPool              : Nat64;
    smallPool              : Nat64;
    mediumPool             : Nat64;
    largePool              : Nat64;
    minSmall               : Nat64;
    minMedium              : Nat64;
    minLarge               : Nat64;
    lastCmcError           : Text;
    lastPayoutError        : Text;
    lastPayoutAt           : Int;
    lastPayoutNote         : Text;
    pendingPayoutCount     : Nat;
    pendingPayoutTotal     : Nat;
  };

  public type FundingStats = {
    samples                : Nat;
    avgCyclesFunded        : Nat;
    totalCyclesFunded      : Nat;
    frontendCyclesKnown    : Nat;
    frontendCyclesUpdatedAt : Int;
  };

  // ── Stable state ───────────────────────────────────────────────────────────

  stable var dailyPool       : Nat64 = 0;
  stable var smallPool       : Nat64 = 0;
  stable var mediumPool      : Nat64 = 0;
  stable var largePool       : Nat64 = 0;
  stable var lotteryPrincipal : ?Principal = ?Principal.fromText("m3n4c-3qaaa-aaaal-qw55a-cai");
  stable var frontendPrincipal : ?Principal = ?Principal.fromText("m4m2w-wiaaa-aaaal-qw55q-cai");
  stable var transferHistory : [TransferRecord] = [];
  stable var lastCmcError    : Text = "none";
  stable var lastTopUpAt     : Int = 0;
  stable var lastTopUpAmount : Nat64 = 0;
  stable var frontendCyclesKnown : Nat = 0;
  stable var frontendCyclesUpdatedAt : Int = 0;
  stable var topUpCycleHistory : [(Int, Nat)] = [];
  stable var topUpAuditHistory : [TopUpAuditRecord] = [];
  stable var pendingPayouts : [PendingPayout] = [];
  stable var nextPendingPayoutId : Nat = 0;
  stable var lastSettleCyclesBefore : Nat = 0;
  stable var lastSettleCyclesAfter  : Nat = 0;
  stable var lastPayoutError : Text = "none";
  stable var lastPayoutAt    : Int = 0;
  stable var lastPayoutNote  : Text = "none";
  stable var cachedLedgerBalance : Nat = 0;
  stable var cachedLedgerBalanceAt : Int = 0;
  transient var payoutRetryTimerId : ?Timer.TimerId = null;

  // Min pool sizes before mystery can drop (in e8s)
  transient let MIN_SMALL  : Nat64 = 50_000_000;  // 0.5 ICP
  transient let MIN_MEDIUM : Nat64 = 200_000_000; // 2.0 ICP
  transient let MIN_LARGE  : Nat64 = 500_000_000; // 5.0 ICP

  // ── Upgrade hook ──────────────────────────────────────────────────────────

  system func preupgrade() {
    switch (payoutRetryTimerId) { case (?id) Timer.cancelTimer(id); case null {} };
  };

  system func postupgrade() {
    cmcLotteryAccountId  := ?Blob.fromArray([46,7,15,5,226,247,37,177,20,92,19,19,237,155,195,39,113,37,21,167,226,175,174,17,205,201,219,254,107,16,176,114]);
    cmcTreasuryAccountId := ?Blob.fromArray([252,7,177,91,47,178,11,179,214,34,155,200,128,52,109,192,177,58,212,155,147,84,79,83,231,90,197,72,111,169,31,209]);
    cmcFrontendAccountId := ?Blob.fromArray([196,138,80,230,198,178,78,66,160,253,131,229,121,56,69,231,45,127,59,62,207,197,50,72,11,201,199,223,235,239,202,237]);
    schedulePayoutRetryLoop<system>();
  };

  // ── Admin ──────────────────────────────────────────────────────────────────

  // ── Auth helper ────────────────────────────────────────────────────────────

  func assertLottery(caller : Principal) {
    switch lotteryPrincipal {
      case (?lp) { assert Principal.equal(caller, lp) };
      case null  { assert false };
    };
  };

  // ── Cycles top-up helper ──────────────────────────────────────────────────
  // CMC requires a legacy `transfer` (not ICRC1) with:
  //   memo    = 0x50555054 (Nat64 "TPUP")
  //   to      = accountIdentifier(CMC, subaccount=principalToSubaccount(canisterId))
  // Then call notify_top_up(block_index, canister_id).

  // CMC account IDs are computed off-chain (SHA224 not available in Motoko base)
  // and hardcoded here before production deploy.

  // CMC account IDs: accountIdentifier(CMC, principalToSubaccount(canisterId))
  // Lottery  (m3n4c-3qaaa-aaaal-qw55a-cai): 2e070f05e2f725b1145c1313ed9bc327712515a7e2afae11cdc9dbfe6b10b072
  // Treasury (msox6-nyaaa-aaaal-qw54q-cai): fc07b15b2fb20bb3d6229bc880346dc0b13ad49b93544f53e75ac5486fa91fd1
  // Frontend (m4m2w-wiaaa-aaaal-qw55q-cai): c48a50e6c6b24e42a0fd83e5793845e72d7f3b3ecfc532480bc9c7dfebefcaed
  stable var cmcLotteryAccountId  : ?Blob = ?Blob.fromArray([46,7,15,5,226,247,37,177,20,92,19,19,237,155,195,39,113,37,21,167,226,175,174,17,205,201,219,254,107,16,176,114]);
  stable var cmcTreasuryAccountId : ?Blob = ?Blob.fromArray([252,7,177,91,47,178,11,179,214,34,155,200,128,52,109,192,177,58,212,155,147,84,79,83,231,90,197,72,111,169,31,209]);
  stable var cmcFrontendAccountId : ?Blob = ?Blob.fromArray([196,138,80,230,198,178,78,66,160,253,131,229,121,56,69,231,45,127,59,62,207,197,50,72,11,201,199,223,235,239,202,237]);

  func topUpCanister(accountId : ?Blob, canisterId : Principal, canisterName : Text, amount : Nat64) : async Bool {
    if (amount == 0 or amount <= Nat64.fromNat(LEDGER_FEE)) return false;
    switch accountId {
      case null {
        lastCmcError := "CMC account ID not configured";
        recordTopUpAudit(canisterId, canisterName, amount, 0, 0, 0, "failed", lastCmcError);
        return false;
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
            trackOutgoing(amount);
            let cmcRes = await cmc.notify_top_up({
              block_index = blockIndex;
              canister_id = canisterId;
            });
            switch cmcRes {
              case (#Ok(cyclesMinted))  {
                lastCmcError := "ok";
                lastTopUpAt := Time.now();
                lastTopUpAmount := amount;
                recordTopUpCycles(cyclesMinted);
                recordTopUpAudit(canisterId, canisterName, amount, net, blockIndex, cyclesMinted, "performed", "");
                switch frontendPrincipal {
                  case (?fp) {
                    if (Principal.equal(canisterId, fp)) {
                      frontendCyclesKnown += cyclesMinted;
                      frontendCyclesUpdatedAt := lastTopUpAt;
                    };
                  };
                  case null {};
                };
                return true;
              };
              case (#Err(e)) {
                lastCmcError := switch e {
                  case (#Refunded(r))           "Refunded: " # r.reason;
                  case (#InvalidTransaction(t)) "InvalidTransaction: " # t;
                  case (#Other(o))              "Other: " # o.error_message;
                  case (#Processing)            "Processing";
                  case (#TransactionTooOld(_))  "TransactionTooOld";
                };
                recordTopUpAudit(canisterId, canisterName, amount, net, blockIndex, 0, "failed", lastCmcError);
                return false;
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
            recordTopUpAudit(canisterId, canisterName, amount, net, 0, 0, "failed", lastCmcError);
            return false;
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
    trackIncoming(amount);

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

    do {
      // Fire-and-forget top-up and dev fee — don't block the caller
      let lotteryShare  = cycles10 * 45 / 100;
      let frontendShare = cycles10 * 20 / 100;
      let treasuryShare = cycles10 - lotteryShare - frontendShare;
      let lp = lotteryPrincipal;
      let fp = frontendPrincipal;
      ignore async {
        switch lp {
          case (?lp) {
            let _ = await topUpCanister(cmcLotteryAccountId,  lp, "Lottery", lotteryShare);
          };
          case null {
            lastCmcError := "Lottery canister not configured; sending lottery share to treasury";
          };
        };
        switch fp {
          case (?fp) {
            let _ = await topUpCanister(cmcFrontendAccountId, fp, "Frontend", frontendShare);
          };
          case null {
            lastCmcError := "Frontend canister not configured; sending frontend share to treasury";
          };
        };
        let fallbackLottery : Nat64 = switch lp { case (?_) 0; case null lotteryShare };
        let fallbackFrontend : Nat64 = switch fp { case (?_) 0; case null frontendShare };
        let _ = await topUpCanister(cmcTreasuryAccountId, Principal.fromActor(Treasury), "Treasury", treasuryShare + fallbackLottery + fallbackFrontend);
        if (Nat64.toNat(dev2) > LEDGER_FEE) {
          let devRes = await ledger.icrc1_transfer({
            to              = { owner = Principal.fromText(DEV_PRINCIPAL); subaccount = null };
            amount          = Nat64.toNat(dev2) - LEDGER_FEE;
            fee             = ?LEDGER_FEE;
            memo            = null;
            from_subaccount = null;
            created_at_time = null;
          });
          switch devRes {
            case (#Ok(_)) {
              trackOutgoing(dev2);
              recordDev(dev2);
            };
            case (#Err(e)) {
              lastPayoutError := "Developer fee failed: " # transferErrText(e);
              lastPayoutAt := Time.now();
              lastPayoutNote := "Developer fee";
            };
          };
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
    lastSettleCyclesBefore := Cycles.balance();
    assertLottery(caller);

    if (dailyPool == 0) {
      lastSettleCyclesAfter := Cycles.balance();
      return #ok({ amountWon = 0; blockIndex = 0 });
    };

    let dp = dailyPool;
    dailyPool := 0;

    if (false) {
      record(dailyWinner, dp, "Daily Prize (dev mode)");
      switch smallWinner  { case (?w) { let s = smallPool;  smallPool  := 0; record(w, s, "Small Mystery (dev mode)") };  case null {} };
      switch mediumWinner { case (?w) { let m = mediumPool; mediumPool := 0; record(w, m, "Medium Mystery (dev mode)") }; case null {} };
      switch largeWinner  { case (?w) { let l = largePool;  largePool  := 0; record(w, l, "Large Mystery (dev mode)") };  case null {} };
      lastSettleCyclesAfter := Cycles.balance();
      return #ok({ amountWon = dp; blockIndex = 0 });
    };

    // ── Daily winner ──────────────────────────────────────────────────────────
    let dpNat = Nat64.toNat(dp);
    let winNet = if (dpNat > LEDGER_FEE) Nat.sub(dpNat, LEDGER_FEE) else 0;
    if (winNet == 0) {
      lastSettleCyclesAfter := Cycles.balance();
      return #err("Daily pool too small to cover fee");
    };

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
        let err = "Daily transfer failed: " # transferErrText(e);
        ignore createPendingPayout(dailyWinner, dp, "Daily Prize", err);
        lastSettleCyclesAfter := Cycles.balance();
        return #ok({ amountWon = Nat64.fromNat(winNet); blockIndex = 0 });
      };
    };
    recordWithBlock(dailyWinner, dp, blockIndex, "Daily Prize");
    trackOutgoing(dp);

    // ── Small mystery ─────────────────────────────────────────────────────────
    switch smallWinner {
      case (?w) {
        let amt = smallPool;
        if (await payPrize(w, amt, "Small Mystery Prize")) smallPool := 0;
      };
      case null {};
    };

    // ── Medium mystery ────────────────────────────────────────────────────────
    switch mediumWinner {
      case (?w) {
        let amt = mediumPool;
        if (await payPrize(w, amt, "Medium Mystery Prize")) mediumPool := 0;
      };
      case null {};
    };

    // ── Large mystery ─────────────────────────────────────────────────────────
    switch largeWinner {
      case (?w) {
        let amt = largePool;
        if (await payPrize(w, amt, "Large Mystery Prize")) largePool := 0;
      };
      case null {};
    };

    lastSettleCyclesAfter := Cycles.balance();
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

  func schedulePayoutRetryLoop<system>() {
    switch (payoutRetryTimerId) { case (?id) Timer.cancelTimer(id); case null {} };
    payoutRetryTimerId := ?Timer.setTimer<system>(#nanoseconds PAYOUT_RETRY_INTERVAL_NANOS, func() : async () {
      payoutRetryTimerId := null;
      await retryDuePayouts();
      schedulePayoutRetryLoop<system>();
    });
  };

  func createPendingPayout(to : Principal, amount : Nat64, note : Text, err : Text) : Nat {
    let now = Time.now();
    let id = nextPendingPayoutId;
    nextPendingPayoutId += 1;
    let rec : PendingPayout = {
      id;
      to;
      amount;
      note;
      retryCount = 0;
      nextRetryAt = now + PAYOUT_RETRY_INTERVAL_NANOS;
      lastError = err;
      status = "pending";
      blockIndex = 0;
      createdAt = now;
      updatedAt = now;
    };
    let buf = Buffer.fromArray<PendingPayout>(pendingPayouts);
    buf.add(rec);
    pendingPayouts := keepLast<PendingPayout>(Buffer.toArray(buf), MAX_TRANSFER_HISTORY);
    lastPayoutError := err;
    lastPayoutAt := now;
    lastPayoutNote := note;
    id
  };

  func retryDuePayouts() : async () {
    let now = Time.now();
    let buf = Buffer.Buffer<PendingPayout>(pendingPayouts.size());
    for (p in pendingPayouts.vals()) {
      if (p.status == "pending" and p.nextRetryAt <= now and p.retryCount < MAX_PAYOUT_RETRIES) {
        let updated = await retryPendingPayout(p);
        buf.add(updated);
      } else {
        buf.add(p);
      };
    };
    pendingPayouts := Buffer.toArray(buf);
  };

  func retryPendingPayout(p : PendingPayout) : async PendingPayout {
    let amountNat = Nat64.toNat(p.amount);
    if (amountNat <= LEDGER_FEE) {
      let now = Time.now();
      return {
        p with
        retryCount = p.retryCount + 1;
        nextRetryAt = now + PAYOUT_RETRY_INTERVAL_NANOS;
        lastError = "Amount too small to cover fee";
        status = "failed";
        updatedAt = now;
      };
    };

    let res = await ledger.icrc1_transfer({
      to              = { owner = p.to; subaccount = null };
      amount          = Nat.sub(amountNat, LEDGER_FEE);
      fee             = ?LEDGER_FEE;
      memo            = null;
      from_subaccount = null;
      created_at_time = null;
    });
    let now = Time.now();
    switch res {
      case (#Ok(blockIndex)) {
        let bi = Nat64.fromNat(blockIndex);
        recordWithBlock(p.to, p.amount, bi, p.note # " retry");
        trackOutgoing(p.amount);
        lastPayoutError := "ok";
        lastPayoutAt := now;
        lastPayoutNote := p.note # " retry";
        {
          p with
          retryCount = p.retryCount + 1;
          nextRetryAt = 0;
          lastError = "";
          status = "paid";
          blockIndex = bi;
          updatedAt = now;
        }
      };
      case (#Err(e)) {
        let err = p.note # " retry failed: " # transferErrText(e);
        let nextCount = p.retryCount + 1;
        lastPayoutError := err;
        lastPayoutAt := now;
        lastPayoutNote := p.note # " retry";
        {
          p with
          retryCount = nextCount;
          nextRetryAt = now + PAYOUT_RETRY_INTERVAL_NANOS;
          lastError = err;
          status = if (nextCount >= MAX_PAYOUT_RETRIES) "failed" else "pending";
          updatedAt = now;
        }
      };
    }
  };

  func payPrize(to : Principal, amount : Nat64, note : Text) : async Bool {
    let amountNat = Nat64.toNat(amount);
    if (amountNat <= LEDGER_FEE) {
      lastPayoutError := note # " too small to cover fee";
      lastPayoutAt := Time.now();
      lastPayoutNote := note;
      return false;
    };

    let res = await ledger.icrc1_transfer({
      to              = { owner = to; subaccount = null };
      amount          = Nat.sub(amountNat, LEDGER_FEE);
      fee             = ?LEDGER_FEE;
      memo            = null;
      from_subaccount = null;
      created_at_time = null;
    });
    switch res {
      case (#Ok(blockIndex)) {
        lastPayoutError := "ok";
        lastPayoutAt := Time.now();
        lastPayoutNote := note;
        recordWithBlock(to, amount, Nat64.fromNat(blockIndex), note);
        trackOutgoing(amount);
        true
      };
      case (#Err(e)) {
        let err = note # " failed: " # transferErrText(e);
        ignore createPendingPayout(to, amount, note, err);
        true
      };
    }
  };

  func record(to : Principal, amount : Nat64, note : Text) {
    recordWithBlock(to, amount, 0, note);
  };

  func recordWithBlock(to : Principal, amount : Nat64, blockIndex : Nat64, note : Text) {
    if (amount == 0) return;
    let rec : TransferRecord = { to; amount; blockIndex; timestamp = Time.now(); note };
    let buf = Buffer.fromArray<TransferRecord>(transferHistory);
    buf.add(rec);
    transferHistory := keepLast<TransferRecord>(Buffer.toArray(buf), MAX_TRANSFER_HISTORY);
  };

  func recordDev(amount : Nat64) {
    if (amount == 0) return;
    record(Principal.fromText(DEV_PRINCIPAL), amount, "Developer fee (2%)");
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
    transferHistory := keepLast<TransferRecord>(Buffer.toArray(buf), MAX_TRANSFER_HISTORY);
  };

  func recordTopUpCycles(cyclesMinted : Nat) {
    if (cyclesMinted == 0) return;
    let buf = Buffer.fromArray<(Int, Nat)>(topUpCycleHistory);
    buf.add((Time.now(), cyclesMinted));
    topUpCycleHistory := keepLast<(Int, Nat)>(Buffer.toArray(buf), MAX_TRANSFER_HISTORY);
  };

  func recordTopUpAudit(
    canister : Principal,
    canisterName : Text,
    amount : Nat64,
    netAmount : Nat64,
    blockIndex : Nat64,
    cyclesMinted : Nat,
    status : Text,
    error : Text,
  ) {
    let rec : TopUpAuditRecord = {
      canister;
      canisterName;
      amount;
      netAmount;
      blockIndex;
      cyclesMinted;
      timestamp = Time.now();
      status;
      error;
    };
    let buf = Buffer.fromArray<TopUpAuditRecord>(topUpAuditHistory);
    buf.add(rec);
    topUpAuditHistory := keepLast<TopUpAuditRecord>(Buffer.toArray(buf), MAX_TRANSFER_HISTORY);
  };

  func fundingStats(limit : Nat) : FundingStats {
    let n = topUpCycleHistory.size();
    let samples = Nat.min(limit, n);
    var total : Nat = 0;
    var i : Nat = 0;
    var idx : Nat = n;
    while (i < samples) {
      idx -= 1;
      total += topUpCycleHistory[idx].1;
      i += 1;
    };
    {
      samples;
      avgCyclesFunded = if (samples == 0) 0 else total / samples;
      totalCyclesFunded = total;
      frontendCyclesKnown;
      frontendCyclesUpdatedAt;
    }
  };

  func totalPoolsNat() : Nat {
    Nat64.toNat(dailyPool) + Nat64.toNat(smallPool) + Nat64.toNat(mediumPool) + Nat64.toNat(largePool)
  };

  func pendingPayoutTotalNat() : Nat {
    var total : Nat = 0;
    for (p in pendingPayouts.vals()) {
      if (p.status != "paid") total += Nat64.toNat(p.amount);
    };
    total
  };

  func pendingPayoutCountNat() : Nat {
    var total : Nat = 0;
    for (p in pendingPayouts.vals()) {
      if (p.status != "paid") total += 1;
    };
    total
  };

  func accountingBalance() : Nat {
    if (cachedLedgerBalance == 0) totalPoolsNat() + pendingPayoutTotalNat() else cachedLedgerBalance
  };

  func trackIncoming(amount : Nat64) {
    if (cachedLedgerBalance == 0) cachedLedgerBalance := totalPoolsNat();
    cachedLedgerBalance += Nat64.toNat(amount);
    cachedLedgerBalanceAt := Time.now();
  };

  func trackOutgoing(amount : Nat64) {
    let amountNat = Nat64.toNat(amount);
    cachedLedgerBalance := if (cachedLedgerBalance > amountNat) Nat.sub(cachedLedgerBalance, amountNat) else 0;
    cachedLedgerBalanceAt := Time.now();
  };

  func treasuryAccounting(balance : Nat) : TreasuryAccounting {
    let pendingTotal = pendingPayoutTotalNat();
    let totalPools = totalPoolsNat() + pendingTotal;
    {
      ledgerBalance = balance;
      totalPools;
      unallocatedBalance = if (balance >= totalPools) Nat.sub(balance, totalPools) else 0;
      poolDeficit = if (totalPools > balance) Nat.sub(totalPools, balance) else 0;
      dailyPool;
      smallPool;
      mediumPool;
      largePool;
      minSmall = MIN_SMALL;
      minMedium = MIN_MEDIUM;
      minLarge = MIN_LARGE;
      lastCmcError;
      lastPayoutError;
      lastPayoutAt;
      lastPayoutNote;
      pendingPayoutCount = pendingPayoutCountNat();
      pendingPayoutTotal = pendingTotal;
    }
  };

  func keepLast<T>(arr : [T], max : Nat) : [T] {
    if (arr.size() <= max) return arr;
    let start = Int.abs(Int.abs(arr.size()) - Int.abs(max));
    Array.tabulate<T>(max, func(i) { arr[start + i] })
  };

  func cyclesDelta(before : Nat, after : Nat) : Int {
    if (after >= before) Int.abs(after - before) else -Int.abs(before - after)
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

  public query func getCyclesHealth() : async CyclesHealth {
    {
      balance = Cycles.balance();
      lastCmcError;
      lastTopUpAt;
      lastTopUpAmount;
      frontendCyclesKnown;
      frontendCyclesUpdatedAt;
      lastSettleCyclesBefore;
      lastSettleCyclesAfter;
      lastSettleCyclesDelta = cyclesDelta(lastSettleCyclesBefore, lastSettleCyclesAfter);
      lotteryConfigured = switch lotteryPrincipal { case (?_) true; case null false };
      frontendConfigured = switch frontendPrincipal { case (?_) true; case null false };
      historySize = transferHistory.size();
      maxHistorySize = MAX_TRANSFER_HISTORY;
    }
  };

  public query func getTreasuryAccounting() : async TreasuryAccounting {
    treasuryAccounting(accountingBalance())
  };

  public query func getFundingStats(limit : Nat) : async FundingStats {
    fundingStats(limit)
  };

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

  public query func getTopUpAuditHistoryPaged(offset : Nat, limit : Nat) : async [TopUpAuditRecord] {
    let t = topUpAuditHistory.size();
    if (offset >= t) return [];
    let rev = Array.tabulate<TopUpAuditRecord>(t, func(i) { topUpAuditHistory[t - 1 - i] });
    Array.tabulate<TopUpAuditRecord>(Nat.min(offset + limit, t) - offset, func(i) { rev[offset + i] })
  };

  public query func getPendingPayouts() : async [PendingPayout] {
    let active = Array.filter<PendingPayout>(pendingPayouts, func(p) { p.status != "paid" });
    let t = active.size();
    Array.tabulate<PendingPayout>(t, func(i) { active[t - 1 - i] })
  };
}
