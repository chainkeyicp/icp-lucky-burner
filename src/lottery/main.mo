import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Random "mo:base/Random";
import Blob "mo:base/Blob";
import Timer "mo:base/Timer";
import Cycles "mo:base/ExperimentalCycles";

import Treasury "canister:treasury";

actor Lottery {
  stable var admin : Principal = Principal.fromText("njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae");

  let TICKET_PRICE_E8S : Nat64 = 10_000_000; // 0.1 ICP
  let TICKET_PRICE     : Nat   = 10_000_000;
  let MAX_TICKETS      : Nat   = 10;
  let DAY_NANOS        : Int   = 86_400_000_000_000;
  let LEDGER_ID        : Text  = "ryjl3-tyaaa-aaaaa-aaaba-cai";
  let LEDGER_FEE       : Nat   = 10_000;
  let MAX_WINNER_HISTORY : Nat = 500;
  let MAX_ROUND_SNAPSHOTS : Nat = 500;

  // Mystery drop thresholds (out of 256)
  // 25% ≈ 64/256 | 10% ≈ 26/256 | 3% ≈ 8/256
  let SMALL_THRESHOLD  : Nat8 = 64;
  let MEDIUM_THRESHOLD : Nat8 = 26;
  let LARGE_THRESHOLD  : Nat8 = 8;

  // ── Types ──────────────────────────────────────────────────────────────────

  public type MysteryDrop = {
    smallWinner  : ?Principal;
    mediumWinner : ?Principal;
    largeWinner  : ?Principal;
  };

  public type WinnerRecord = {
    roundId      : Nat;
    winner       : Principal;
    amountWon    : Nat64;
    blockIndex   : Nat64;
    timestamp    : Int;
    ticketsSold  : Nat;
    smallWinner  : ?Principal;
    mediumWinner : ?Principal;
    largeWinner  : ?Principal;
    smallAmt     : Nat64;
    mediumAmt    : Nat64;
    largeAmt     : Nat64;
  };

  public type RoundStatus = {
    roundId     : Nat;
    ticketsSold : Nat;
    myTickets   : Nat;
    dailyPool   : Nat64;
    smallPool   : Nat64;
    mediumPool  : Nat64;
    largePool   : Nat64;
    minSmall    : Nat64;
    minMedium   : Nat64;
    minLarge    : Nat64;
    roundStart  : Int;
    roundEnd    : Int;
    isDevMode   : Bool;
  };

  public type PurchaseRecord = {
    buyer     : Principal;
    count     : Nat;
    timestamp : Int;
    roundId   : Nat;
  };

  public type CyclesHealth = {
    balance              : Nat;
    lastBuyCyclesBefore  : Nat;
    lastBuyCyclesAfter   : Nat;
    lastBuyCyclesDelta   : Int;
    lastDrawCyclesBefore : Nat;
    lastDrawCyclesAfter  : Nat;
    lastDrawCyclesDelta  : Int;
    historySize          : Nat;
    snapshotSize         : Nat;
    maxHistorySize       : Nat;
  };

  public type AutonomyUsageStats = {
    samples              : Nat;
    avgDailyCyclesUsed   : Nat;
    avgTicketsPerRound   : Nat;
    totalCyclesUsed      : Nat;
    totalTickets         : Nat;
  };

  type TransferFromError = {
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
    icrc2_transfer_from : shared ({
      spender_subaccount : ?Blob;
      from               : { owner : Principal; subaccount : ?Blob };
      to                 : { owner : Principal; subaccount : ?Blob };
      amount             : Nat;
      fee                : ?Nat;
      memo               : ?Blob;
      created_at_time    : ?Nat64;
    }) -> async { #Ok : Nat; #Err : TransferFromError };
  };

  let ledger : LedgerActor = actor(LEDGER_ID);

  // ── Stable state ───────────────────────────────────────────────────────────

  stable var currentRound         : Nat  = 1;
  stable var roundStartTime       : Int  = Time.now();
  stable var isDevMode            : Bool = false;
  stable var winnerHistory        : [WinnerRecord] = [];
  stable var ticketEntries        : [(Principal, Nat)] = [];
  stable var ticketPoolArr        : [Principal] = [];
  stable var purchaseHistory      : [PurchaseRecord] = [];
  stable var winnerTicketsArr     : [(Nat, Nat)] = [];
  stable var roundParticipantsArr : [(Nat, [(Principal, Nat)])] = [];
  stable var lastBuyCyclesBefore  : Nat = 0;
  stable var lastBuyCyclesAfter   : Nat = 0;
  stable var lastDrawCyclesBefore : Nat = 0;
  stable var lastDrawCyclesAfter  : Nat = 0;
  stable var cycleUsageHistory    : [(Nat, Nat, Nat)] = [];

  // Local pool cache — mirrors treasury pools, updated at purchase and draw
  stable var cachedDailyPool   : Nat64 = 0;
  stable var cachedSmallPool   : Nat64 = 0;
  stable var cachedMediumPool  : Nat64 = 0;
  stable var cachedLargePool   : Nat64 = 0;
  stable var cachedMinSmall    : Nat64 = 50_000_000;
  stable var cachedMinMedium   : Nat64 = 200_000_000;
  stable var cachedMinLarge    : Nat64 = 500_000_000;

  // ── Mutable state ──────────────────────────────────────────────────────────

  var tickets : HashMap.HashMap<Principal, Nat> =
    HashMap.fromIter(ticketEntries.vals(), 16, Principal.equal, Principal.hash);

  var ticketBuf : Buffer.Buffer<Principal> = do {
    let b = Buffer.Buffer<Principal>(100);
    for (p in ticketPoolArr.vals()) b.add(p);
    b
  };

  var timerId : ?Timer.TimerId = null;

  // ── Upgrade hooks ──────────────────────────────────────────────────────────

  system func preupgrade() {
    ticketEntries := Iter.toArray(tickets.entries());
    ticketPoolArr := Buffer.toArray(ticketBuf);
    switch (timerId) { case (?id) Timer.cancelTimer(id); case null {} };
  };

  system func postupgrade() {
    tickets   := HashMap.fromIter(ticketEntries.vals(), 16, Principal.equal, Principal.hash);
    ticketBuf := Buffer.Buffer<Principal>(100);
    for (p in ticketPoolArr.vals()) ticketBuf.add(p);
    admin     := Principal.fromText("njtst-4gvw7-fsjc5-7rz4t-jmpau-l2yo5-xxqp5-dnoyd-zkbtj-bdfnj-4ae");
    isDevMode := false;
    scheduleNextDraw<system>();
  };

  // ── Timer ──────────────────────────────────────────────────────────────────

  func scheduleNextDraw<system>() {
    switch (timerId) { case (?id) Timer.cancelTimer(id); case null {} };
    let diff  = (roundStartTime + DAY_NANOS) - Time.now();
    let delay : Nat = if (diff < 1_000_000) 1_000_000 else Int.abs(diff);
    timerId := ?Timer.setTimer<system>(#nanoseconds delay, func() : async () {
      await draw();
      scheduleNextDraw<system>();
    });
  };

  // ── Participant snapshot helpers ───────────────────────────────────────────

  func getWinnerTickets(roundId : Nat) : Nat {
    for ((r, n) in winnerTicketsArr.vals()) {
      if (r == roundId) return n;
    };
    0
  };

  func recordWinnerTickets(roundId : Nat, count : Nat) {
    let buf = Buffer.fromArray<(Nat, Nat)>(winnerTicketsArr);
    buf.add((roundId, count));
    winnerTicketsArr := keepLast<(Nat, Nat)>(Buffer.toArray(buf), MAX_ROUND_SNAPSHOTS);
  };

  func snapshotParticipants(roundId : Nat) {
    let snapshot = Iter.toArray(tickets.entries());
    let buf = Buffer.fromArray<(Nat, [(Principal, Nat)])>(roundParticipantsArr);
    buf.add((roundId, snapshot));
    roundParticipantsArr := keepLast<(Nat, [(Principal, Nat)])>(Buffer.toArray(buf), MAX_ROUND_SNAPSHOTS);
  };

  func getParticipantSnapshot(roundId : Nat) : [(Principal, Nat)] {
    for ((r, ps) in roundParticipantsArr.vals()) {
      if (r == roundId) return ps;
    };
    []
  };

  // ── Seed helper ────────────────────────────────────────────────────────────
  // Extract a Nat seed from a slice of entropy bytes [from, to)

  func seedFromBytes(bytes : [Nat8], from : Nat, to : Nat) : Nat {
    var s : Nat = 0;
    var i = from;
    while (i < to and i < bytes.size()) {
      s := s * 256 + Nat8.toNat(bytes[i]);
      i += 1;
    };
    s
  };

  func keepLast<T>(arr : [T], max : Nat) : [T] {
    if (arr.size() <= max) return arr;
    let start = Int.abs(Int.abs(arr.size()) - Int.abs(max));
    Array.tabulate<T>(max, func(i) { arr[start + i] })
  };

  func cyclesDelta(before : Nat, after : Nat) : Int {
    if (after >= before) Int.abs(after - before) else -Int.abs(before - after)
  };

  func cyclesUsed(before : Nat, after : Nat) : Nat {
    if (before >= after) before - after else after - before
  };

  func recordCycleUsage(roundId : Nat, ticketsSold : Nat, used : Nat) {
    let buf = Buffer.fromArray<(Nat, Nat, Nat)>(cycleUsageHistory);
    buf.add((roundId, ticketsSold, used));
    cycleUsageHistory := keepLast<(Nat, Nat, Nat)>(Buffer.toArray(buf), MAX_ROUND_SNAPSHOTS);
  };

  func autonomyUsageStats(limit : Nat) : AutonomyUsageStats {
    let n = cycleUsageHistory.size();
    let samples = Nat.min(limit, n);
    var totalCycles : Nat = 0;
    var totalTickets : Nat = 0;
    var i : Nat = 0;
    var idx : Nat = n;
    while (i < samples) {
      idx -= 1;
      totalTickets += cycleUsageHistory[idx].1;
      totalCycles += cycleUsageHistory[idx].2;
      i += 1;
    };
    {
      samples;
      avgDailyCyclesUsed = if (samples == 0) 0 else totalCycles / samples;
      avgTicketsPerRound = if (samples == 0) 0 else totalTickets / samples;
      totalCyclesUsed = totalCycles;
      totalTickets;
    }
  };

  // ── Draw ───────────────────────────────────────────────────────────────────

  func draw() : async () {
    lastDrawCyclesBefore := Cycles.balance();
    let pool = Buffer.toArray(ticketBuf);
    let sold = pool.size();

    if (sold == 0) {
      let buf = Buffer.fromArray<WinnerRecord>(winnerHistory);
      buf.add({
        roundId = currentRound; winner = Principal.fromText("aaaaa-aa");
        amountWon = 0; blockIndex = 0; timestamp = Time.now(); ticketsSold = 0;
        smallWinner = null; mediumWinner = null; largeWinner = null;
        smallAmt = 0; mediumAmt = 0; largeAmt = 0;
      });
      winnerHistory := keepLast<WinnerRecord>(Buffer.toArray(buf), MAX_WINNER_HISTORY);
      lastDrawCyclesAfter := Cycles.balance();
      recordCycleUsage(currentRound, sold, cyclesUsed(lastDrawCyclesBefore, lastDrawCyclesAfter));
      advanceRound();
      return;
    };

    let entropy = await Random.blob();
    let bytes   = Blob.toArray(entropy);

    // Bytes 0-2: mystery drop checks
    let smallDrop  = Nat8.toNat(bytes[0]) < Nat8.toNat(SMALL_THRESHOLD)
                     and cachedSmallPool >= cachedMinSmall;
    let mediumDrop = Nat8.toNat(bytes[1]) < Nat8.toNat(MEDIUM_THRESHOLD)
                     and cachedMediumPool >= cachedMinMedium;
    let largeDrop  = Nat8.toNat(bytes[2]) < Nat8.toNat(LARGE_THRESHOLD)
                     and cachedLargePool >= cachedMinLarge;

    // Bytes 3-10: daily winner seed
    let dailySeed  = seedFromBytes(bytes, 3, 11);
    let winner     = pool[dailySeed % sold];

    // Bytes 11-18: small mystery winner seed
    let smallSeed  = seedFromBytes(bytes, 11, 19);
    let smallW     = if (smallDrop)  ?pool[smallSeed  % sold] else null;

    // Bytes 19-26: medium mystery winner seed
    let medSeed    = seedFromBytes(bytes, 19, 27);
    let medW       = if (mediumDrop) ?pool[medSeed    % sold] else null;

    // Bytes 27-31: large mystery winner seed (5 bytes — enough)
    let largeSeed  = seedFromBytes(bytes, 27, 32);
    let largeW     = if (largeDrop)  ?pool[largeSeed  % sold] else null;

    snapshotParticipants(currentRound);
    let winnerCount = switch (tickets.get(winner)) { case (?n) n; case null 0 };
    recordWinnerTickets(currentRound, winnerCount);

    // Snapshot pool amounts before clearing (for history record)
    let sAmt : Nat64 = if (smallDrop)  cachedSmallPool  else 0;
    let mAmt : Nat64 = if (mediumDrop) cachedMediumPool else 0;
    let lAmt : Nat64 = if (largeDrop)  cachedLargePool  else 0;

    let settleResult = await Treasury.settle(winner, smallW, medW, largeW);
    var amountWon  : Nat64 = 0;
    var blockIndex : Nat64 = 0;
    switch settleResult {
      case (#ok(r)) { amountWon := r.amountWon; blockIndex := r.blockIndex };
      case (#err(_)) {};
    };

    // Update cached pools
    cachedDailyPool := 0;
    if (smallDrop)  cachedSmallPool  := 0;
    if (mediumDrop) cachedMediumPool := 0;
    if (largeDrop)  cachedLargePool  := 0;

    let buf = Buffer.fromArray<WinnerRecord>(winnerHistory);
    buf.add({
      roundId = currentRound; winner; amountWon; blockIndex;
      timestamp = Time.now(); ticketsSold = sold;
      smallWinner = smallW; mediumWinner = medW; largeWinner = largeW;
      smallAmt = sAmt; mediumAmt = mAmt; largeAmt = lAmt;
    });
    winnerHistory := keepLast<WinnerRecord>(Buffer.toArray(buf), MAX_WINNER_HISTORY);
    lastDrawCyclesAfter := Cycles.balance();
    recordCycleUsage(currentRound, sold, cyclesUsed(lastDrawCyclesBefore, lastDrawCyclesAfter));
    advanceRound();
  };

  func advanceRound() {
    currentRound   += 1;
    roundStartTime := Time.now();
    tickets   := HashMap.HashMap(16, Principal.equal, Principal.hash);
    ticketBuf := Buffer.Buffer<Principal>(100);
  };

  // ── Public API ─────────────────────────────────────────────────────────────

  public shared ({ caller }) func buyTickets(count : Nat) : async Result.Result<Text, Text> {
    lastBuyCyclesBefore := Cycles.balance();
    if (Principal.isAnonymous(caller)) {
      lastBuyCyclesAfter := Cycles.balance();
      return #err("Login required");
    };
    if (count == 0 or count > MAX_TICKETS) {
      lastBuyCyclesAfter := Cycles.balance();
      return #err("Buy 1–10 tickets");
    };
    let existing = switch (tickets.get(caller)) { case (?n) n; case null 0 };
    if (existing + count > MAX_TICKETS) {
      lastBuyCyclesAfter := Cycles.balance();
      return #err(
        "Max 10 tickets per wallet. You have " # Nat.toText(existing) # " already."
      );
    };

    if (not isDevMode) {
      let totalAmount = count * TICKET_PRICE;
      let treasuryId  = Principal.fromActor(Treasury);
      let payResult   = await ledger.icrc2_transfer_from({
        spender_subaccount = null;
        from               = { owner = caller; subaccount = null };
        to                 = { owner = treasuryId; subaccount = null };
        amount             = totalAmount;
        fee                = ?LEDGER_FEE;
        memo               = null;
        created_at_time    = null;
      });
      switch payResult {
        case (#Err(e)) {
          let msg = switch e {
            case (#InsufficientFunds(_))     "Insufficient ICP balance";
            case (#InsufficientAllowance(_)) "Approve ICP spend first (step 1 of 2)";
            case (#BadFee(_))                "Bad fee — expected 0.0001 ICP";
            case (#TooOld)                   "Transaction too old, try again";
            case _                           "Payment failed";
          };
          lastBuyCyclesAfter := Cycles.balance();
          return #err(msg);
        };
        case (#Ok(_)) {};
      };
    };

    tickets.put(caller, existing + count);
    for (_ in Iter.range(0, count - 1)) ticketBuf.add(caller);

    let revenue = Nat64.fromNat(count) * TICKET_PRICE_E8S;
    await Treasury.addTicketRevenue(revenue);

    // Mirror treasury pool distribution in local cache
    cachedDailyPool  += revenue * 54 / 100;
    cachedSmallPool  += revenue * 16 / 100;
    cachedMediumPool += revenue * 11 / 100;
    cachedLargePool  += revenue *  7 / 100;

    let rec : PurchaseRecord = { buyer = caller; count; timestamp = Time.now(); roundId = currentRound };
    let buf = Buffer.fromArray<PurchaseRecord>(purchaseHistory);
    buf.add(rec);
    purchaseHistory := keepLast<PurchaseRecord>(Buffer.toArray(buf), 50);

    lastBuyCyclesAfter := Cycles.balance();
    #ok("Purchased " # Nat.toText(count) # " ticket(s). Total: " #
        Nat.toText(existing + count) # "/10.")
  };

  public shared ({ caller }) func setAdmin(p : Principal) : async () {
    assert Principal.equal(caller, admin);
    admin := p;
  };

  public shared func devEndDay() : async Result.Result<Text, Text> {
    if (not isDevMode) return #err("Not in dev mode");
    await draw();
    #ok("Day ended → Round #" # Nat.toText(currentRound))
  };

  public shared ({ caller }) func setDevMode(enabled : Bool) : async () {
    assert Principal.equal(caller, admin);
    isDevMode := enabled;
    if (not enabled) scheduleNextDraw<system>();
  };

  public shared query ({ caller }) func getRoundStatus() : async RoundStatus {
    let myT = switch (tickets.get(caller)) { case (?n) n; case null 0 };
    {
      roundId = currentRound; ticketsSold = ticketBuf.size();
      myTickets = myT;
      dailyPool  = cachedDailyPool;
      smallPool  = cachedSmallPool;
      mediumPool = cachedMediumPool;
      largePool  = cachedLargePool;
      minSmall   = cachedMinSmall;
      minMedium  = cachedMinMedium;
      minLarge   = cachedMinLarge;
      roundStart = roundStartTime; roundEnd = roundStartTime + DAY_NANOS;
      isDevMode;
    }
  };

  public query func getRecentPurchases() : async [PurchaseRecord] {
    let filtered = Array.filter<PurchaseRecord>(purchaseHistory, func(r) { r.roundId == currentRound });
    let t = filtered.size();
    Array.tabulate<PurchaseRecord>(t, func(i) { filtered[t - 1 - i] })
  };

  public query func getRoundTickets(roundId : Nat) : async [(Principal, Nat)] {
    if (roundId == currentRound) {
      Iter.toArray(tickets.entries())
    } else {
      let snap = getParticipantSnapshot(roundId);
      if (snap.size() > 0) return snap;
      let found = Array.filter<WinnerRecord>(winnerHistory, func(r) { r.roundId == roundId });
      if (found.size() > 0) {
        [(found[0].winner, getWinnerTickets(roundId))]
      } else []
    }
  };

  public query func getMyRounds(who : Principal) : async [(Nat, Nat, Nat)] {
    var result : [(Nat, Nat, Nat)] = [];
    for ((roundId, snap) in roundParticipantsArr.vals()) {
      for ((p, n) in snap.vals()) {
        if (Principal.equal(p, who)) {
          let total = Array.foldLeft<(Principal, Nat), Nat>(snap, 0, func(acc, e) { acc + e.1 });
          result := Array.append(result, [(roundId, n, total)]);
        };
      };
    };
    switch (tickets.get(who)) {
      case (?n) { result := Array.append(result, [(currentRound, n, ticketBuf.size())]) };
      case null {};
    };
    Array.sort<(Nat, Nat, Nat)>(result, func(a, b) {
      if (a.0 > b.0) #less else if (a.0 < b.0) #greater else #equal
    })
  };

  public query func getWinnerHistory() : async [WinnerRecord] {
    let t = winnerHistory.size();
    Array.tabulate<WinnerRecord>(t, func(i) { winnerHistory[t - 1 - i] })
  };

  public query func getWinnerHistoryPaged(offset : Nat, limit : Nat) : async [WinnerRecord] {
    let t = winnerHistory.size();
    if (offset >= t) return [];
    let rev = Array.tabulate<WinnerRecord>(t, func(i) { winnerHistory[t - 1 - i] });
    Array.tabulate<WinnerRecord>(Nat.min(offset + limit, t) - offset, func(i) { rev[offset + i] })
  };

  public query func getCyclesHealth() : async CyclesHealth {
    {
      balance = Cycles.balance();
      lastBuyCyclesBefore;
      lastBuyCyclesAfter;
      lastBuyCyclesDelta = cyclesDelta(lastBuyCyclesBefore, lastBuyCyclesAfter);
      lastDrawCyclesBefore;
      lastDrawCyclesAfter;
      lastDrawCyclesDelta = cyclesDelta(lastDrawCyclesBefore, lastDrawCyclesAfter);
      historySize = winnerHistory.size();
      snapshotSize = roundParticipantsArr.size();
      maxHistorySize = MAX_WINNER_HISTORY;
    }
  };

  public query func getAutonomyUsageStats(limit : Nat) : async AutonomyUsageStats {
    autonomyUsageStats(limit)
  };
}
