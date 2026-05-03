import { AuthClient } from "@dfinity/auth-client";
import { Actor, HttpAgent } from "@dfinity/agent";
import { Ed25519KeyIdentity } from "@dfinity/identity";
import { Principal } from "@dfinity/principal";
import { lotteryIdl }  from "./idl/lottery.js";
import { treasuryIdl } from "./idl/treasury.js";
import { ledgerIdl }   from "./idl/ledger.js";

// ── Config ─────────────────────────────────────────────────────────────────

const IS_IC_HOST = /\.icp0\.io$|\.ic0\.app$/.test(globalThis.location?.hostname ?? "");
const LOTTERY_ID  = IS_IC_HOST ? "m3n4c-3qaaa-aaaal-qw55a-cai" : (import.meta.env.VITE_LOTTERY_CANISTER_ID  ?? "");
const TREASURY_ID = IS_IC_HOST ? "msox6-nyaaa-aaaal-qw54q-cai" : (import.meta.env.VITE_TREASURY_CANISTER_ID ?? "");
const LEDGER_ID   = "ryjl3-tyaaa-aaaaa-aaaba-cai";
const IS_LOCAL    = !IS_IC_HOST && (import.meta.env.VITE_DFX_NETWORK ?? "local") !== "ic";
const HOST        = IS_LOCAL ? (import.meta.env.VITE_HOST ?? "http://localhost:8080") : "https://icp-api.io";
const II_URL      = "https://identity.ic0.app";
const EXPLORER_BASE = "https://dashboard.internetcomputer.org/transaction/";
const LEDGER_FEE  = 10_000n;

// ── State ──────────────────────────────────────────────────────────────────

let authClient    = null;
let agent         = null;
let lotteryActor  = null;
let ledgerActor   = null;
let identity      = null;
let ticketQty     = 1;
let winnersOffset = 0;
let lastRoundId   = 0;
let lastTopUpToastAt = 0n;
const WINNERS_PAGE = 20;

// ── Boot ───────────────────────────────────────────────────────────────────

setupNav();
setupGlobalActions();
setupQty();
setupDevPanel();
startCountdown();
initAsync();

async function initAsync() {
  try {
    if (IS_LOCAL) {
      document.getElementById("dev-login-btn").style.display = "inline-flex";
      document.getElementById("login-btn").style.display = "none";
      const stored = localStorage.getItem("dev_identity");
      if (stored) await connectWithIdentity(Ed25519KeyIdentity.fromJSON(stored));
    } else {
      authClient = await AuthClient.create();
      if (await authClient.isAuthenticated()) {
        await connectWithIdentity(authClient.getIdentity());
      }
    }
    await refreshRound();
  } catch (e) {
    console.error("Init error:", e);
  } finally {
    document.getElementById("preloader").classList.add("hidden");
    document.getElementById("main-content").style.visibility = "visible";
  }

  refreshLiveFeed();
  refreshStats();
  if (activePage() === "rules") refreshTransparency();

  setInterval(async () => {
    await refreshRound();
    await refreshLiveFeed();
    await refreshStats();
    if (activePage() === "rules") await refreshTransparency();
  }, 30_000);
}

// ── Auth ───────────────────────────────────────────────────────────────────

async function connectWithIdentity(id) {
  identity = id;
  const host = IS_LOCAL ? HOST : "https://icp-api.io";
  agent = new HttpAgent({ identity, host });
  if (IS_LOCAL) await agent.fetchRootKey().catch(() => {});

  lotteryActor = Actor.createActor(lotteryIdl,  { agent, canisterId: LOTTERY_ID });
  ledgerActor  = Actor.createActor(ledgerIdl,   { agent, canisterId: LEDGER_ID });

  const principal = identity.getPrincipal().toText();
  document.getElementById("user-principal").textContent = shortPrincipal(principal);
  document.getElementById("auth-section").classList.add("hidden");
  document.getElementById("user-section").classList.remove("hidden");
  document.getElementById("login-prompt").classList.add("hidden");
  document.getElementById("buy-section").classList.remove("hidden");
  document.getElementById("wallet-login-prompt").classList.add("hidden");
  document.getElementById("wallet-content").classList.remove("hidden");
  document.getElementById("wallet-principal").textContent = principal;
  refreshBalance();
}

document.getElementById("login-btn").addEventListener("click", async () => {
  if (!authClient) authClient = await AuthClient.create();
  authClient.login({
    identityProvider: II_URL,
    onSuccess: async () => {
      await connectWithIdentity(authClient.getIdentity());
      await refreshRound();
    },
  });
});

document.getElementById("dev-login-btn")?.addEventListener("click", async () => {
  const stored = localStorage.getItem("dev_identity");
  let id;
  if (stored) {
    id = Ed25519KeyIdentity.fromJSON(stored);
  } else {
    id = Ed25519KeyIdentity.generate();
    localStorage.setItem("dev_identity", JSON.stringify(id.toJSON()));
  }
  await connectWithIdentity(id);
  await refreshRound();
});

document.getElementById("logout-btn").addEventListener("click", async () => {
  await authClient?.logout();
  localStorage.removeItem("dev_identity");
  location.reload();
});

// ── Navigation ─────────────────────────────────────────────────────────────

function setupNav() {
  document.querySelectorAll(".nav-link").forEach(link => {
    link.addEventListener("click", e => {
      const page = link.dataset.page;
      if (!page) return;
      e.preventDefault();
      document.querySelectorAll(".nav-link").forEach(l => l.classList.remove("active"));
      link.classList.add("active");
      document.querySelectorAll(".page").forEach(p => {
        p.classList.remove("active");
        p.classList.add("hidden");
      });
      const target = document.getElementById(`page-${page}`);
      target.classList.remove("hidden");
      target.classList.add("active");
      if (page === "winners") refreshWinners();
      if (page === "wallet") refreshMyHistory();
      if (page === "rules") refreshTransparency();
    });
  });
}

function activePage() {
  return document.querySelector(".page.active")?.id?.replace("page-", "") ?? "lottery";
}

function setupGlobalActions() {
  document.querySelectorAll(".login-forward-btn").forEach(btn => {
    btn.addEventListener("click", () => document.getElementById("login-btn").click());
  });

  const overlay = document.getElementById("modal-overlay");
  overlay.addEventListener("click", () => closeModal());
  overlay.querySelector(".modal").addEventListener("click", e => e.stopPropagation());
  document.getElementById("modal-close").addEventListener("click", () => closeModal());
}

// ── Dev panel ──────────────────────────────────────────────────────────────

function setupDevPanel() {
  if (!IS_LOCAL) return;
  document.getElementById("dev-panel").classList.remove("hidden");
  document.getElementById("dev-end-day").addEventListener("click", async () => {
    const btn = document.getElementById("dev-end-day");
    const msg = document.getElementById("dev-msg");
    if (!lotteryActor) { msg.textContent = "Login first"; return; }
    btn.disabled = true;
    msg.textContent = "Processing...";
    try {
      const res = await lotteryActor.devEndDay();
      msg.textContent = "ok" in res ? res.ok : res.err;
      await refreshRound();
      await refreshWinners();
      await refreshBalance();
    } catch (e) {
      msg.textContent = String(e);
    }
    btn.disabled = false;
  });
}

// ── Ticket qty selector ────────────────────────────────────────────────────

function setupQty() {
  document.getElementById("qty-minus").addEventListener("click", () => {
    if (ticketQty > 1) { ticketQty--; renderQty(); }
  });
  document.getElementById("qty-plus").addEventListener("click", () => {
    if (ticketQty < 10) { ticketQty++; renderQty(); }
  });
  document.getElementById("buy-btn").addEventListener("click", buyTickets);
  renderQty();
}

function renderQty() {
  document.getElementById("qty-display").textContent = ticketQty;
  document.getElementById("ticket-cost").textContent = `${(ticketQty * 0.1).toFixed(1)} ICP`;
}

async function buyTickets() {
  if (!lotteryActor) return;
  const btn = document.getElementById("buy-btn");
  const msg = document.getElementById("buy-msg");
  btn.disabled = true;
  setMsg(msg, "", "");
  openProgressOverlay();
  const topUpBaseline = await getTopUpBaseline();

  try {
    if (!IS_LOCAL && ledgerActor) {
      setStep("step-approve", "active");
      const approveAmount = BigInt(ticketQty) * 10_000_000n + LEDGER_FEE;
      const approveRes = await ledgerActor.icrc2_approve({
        spender:            { owner: Principal.fromText(LOTTERY_ID), subaccount: [] },
        amount:             approveAmount,
        fee:                [],
        memo:               [],
        from_subaccount:    [],
        expected_allowance: [],
        expires_at:         [],
        created_at_time:    [],
      });
      if ("Err" in approveRes) {
        const errKey = Object.keys(approveRes.Err)[0];
        setStep("step-approve", "error", `Approve failed: ${errKey}`);
        setTimeout(closeProgressOverlay, 2000);
        setMsg(msg, `Approve failed: ${errKey}`, "error");
        btn.disabled = false;
        return;
      }
      setStep("step-approve", "done", "ICP approved");
    }

    setStep("step-buy", "active");
    const res = await lotteryActor.buyTickets(ticketQty);

    if ("ok" in res) {
      setStep("step-buy", "done", `${ticketQty} ticket${ticketQty > 1 ? "s" : ""} registered`);
      setStep("step-cycles", "active", "Performing top-up request...");
      // Top-up is finalized asynchronously by treasury; confirmation comes by polling telemetry.
      await sleep(650);
      setStep("step-cycles", "done", "Top-up request performed");
      await sleep(550);
      closeProgressOverlay();
      toast(`Bought ${ticketQty} ticket${ticketQty > 1 ? "s" : ""}!`, "success");
      setMsg(msg, res.ok, "success");
      await refreshRound();
      await refreshLiveFeed();
      await refreshStats();
      watchCyclesTopUp(topUpBaseline);
    } else {
      setStep("step-buy", "error", res.err);
      setTimeout(closeProgressOverlay, 2500);
      setMsg(msg, res.err, "error");
    }
  } catch (e) {
    closeProgressOverlay();
    setMsg(msg, String(e), "error");
  }
  btn.disabled = false;
}

async function getTopUpBaseline() {
  if (IS_LOCAL) return null;
  try {
    const h = await makeAnonActors().treasury.getCyclesHealth();
    return BigInt(h.lastTopUpAt);
  } catch {
    return null;
  }
}

async function watchCyclesTopUp(previousTopUpAt) {
  if (IS_LOCAL || previousTopUpAt === null) return;
  for (let i = 0; i < 12; i++) {
    await sleep(2_000);
    try {
      const h = await makeAnonActors().treasury.getCyclesHealth();
      const topUpAt = BigInt(h.lastTopUpAt);
      if (topUpAt > previousTopUpAt && topUpAt > lastTopUpToastAt) {
        lastTopUpToastAt = topUpAt;
        if (h.lastCmcError === "ok") {
          toast("Cycles top-up confirmed", "success");
        } else {
          toast(`Cycles top-up status: ${h.lastCmcError}`, "info");
        }
        await refreshStats();
        return;
      }
    } catch (e) {
      console.error("watchCyclesTopUp:", e);
    }
  }
}

// ── Anon actors (read-only, no login required) ────────────────────────────

function makeAnonActors() {
  const host = IS_LOCAL ? HOST : "https://icp-api.io";
  const anonAgent = new HttpAgent({ host });
  if (IS_LOCAL) anonAgent.fetchRootKey().catch(() => {});
  return {
    lottery:  Actor.createActor(lotteryIdl,  { agent: anonAgent, canisterId: LOTTERY_ID }),
    treasury: Actor.createActor(treasuryIdl, { agent: anonAgent, canisterId: TREASURY_ID }),
  };
}

// ── Round status ───────────────────────────────────────────────────────────

async function refreshRound() {
  const actor = lotteryActor ?? makeAnonActors().lottery;
  try {
    const s = await actor.getRoundStatus();
    renderRound(s);
  } catch (e) { console.error("getRoundStatus:", e); }
}

async function renderRound(s) {
  const newRoundId = Number(s.roundId);
  if (lastRoundId !== 0 && newRoundId !== lastRoundId) {
    await refreshWinners();
    await refreshBalance();
    if (identity && lotteryActor) {
      try {
        const history = await lotteryActor.getWinnerHistoryPaged(0, 1);
        if (history.length > 0) {
          const last = history[0];
          const myAddr = identity.getPrincipal().toText();
          if (Number(last.roundId) === lastRoundId) {
            if (last.winner.toText() === myAddr) {
              toast(`🏆 You won ${e8sToIcp(last.amountWon)} ICP (daily)!`, "win");
            }
            if (last.smallWinner.length > 0 && last.smallWinner[0].toText() === myAddr) {
              toast(`🔮 Small Mystery! You won ${e8sToIcp(last.smallAmt)} ICP!`, "win");
            }
            if (last.mediumWinner.length > 0 && last.mediumWinner[0].toText() === myAddr) {
              toast(`✨ Medium Mystery! You won ${e8sToIcp(last.mediumAmt)} ICP!`, "win");
            }
            if (last.largeWinner.length > 0 && last.largeWinner[0].toText() === myAddr) {
              toast(`💎 LARGE MYSTERY! You won ${e8sToIcp(last.largeAmt)} ICP!`, "win");
            }
          }
        }
      } catch (e) {}
    }
  }
  lastRoundId = newRoundId;

  document.getElementById("day-banner").className = "day-banner normal";
  document.getElementById("day-label").textContent  = "Daily Draw";
  document.getElementById("day-number").textContent = `Round #${s.roundId}`;

  const daily  = Number(s.dailyPool);
  const small  = Number(s.smallPool);
  const medium = Number(s.mediumPool);
  const large  = Number(s.largePool);
  const minS   = Number(s.minSmall);
  const minM   = Number(s.minMedium);
  const minL   = Number(s.minLarge);

  document.getElementById("pool-daily").textContent  = e8sToIcp(BigInt(Math.floor(daily)));
  document.getElementById("pool-small").textContent  = e8sToIcp(BigInt(Math.floor(small)));
  document.getElementById("pool-medium").textContent = e8sToIcp(BigInt(Math.floor(medium)));
  document.getElementById("pool-large").textContent  = e8sToIcp(BigInt(Math.floor(large)));

  // Sub-labels: show drop chance or "accumulating until min"
  const smallNow  = BigInt(Math.floor(small));
  const mediumNow = BigInt(Math.floor(medium));
  const largeNow  = BigInt(Math.floor(large));

  document.getElementById("daily-sub").textContent  = `From today's ${e8sToIcp(BigInt(Math.floor(daily)))} pool`;
  document.getElementById("small-sub").textContent  = mysteryStatusText(smallNow, BigInt(minS), "25%");
  document.getElementById("medium-sub").textContent = mysteryStatusText(mediumNow, BigInt(minM), "10%");
  document.getElementById("large-sub").textContent  = mysteryStatusText(largeNow, BigInt(minL), "3%");

  const my   = Number(s.myTickets);
  const sold = Number(s.ticketsSold);
  document.getElementById("my-tickets").textContent   = `${my} / 10`;
  document.getElementById("tickets-sold").textContent = String(sold);

  const chanceRow = document.getElementById("win-chance-row");
  const chanceEl  = document.getElementById("win-chance");
  if (my > 0 && sold > 0) {
    const pct = my / sold * 100;
    chanceEl.textContent = pct >= 1 ? `${pct.toFixed(1)}%` : `${pct.toFixed(2)}%`;
    chanceRow.style.display = "flex";
  } else {
    chanceRow.style.display = "none";
  }

  const remaining = 10 - my;
  if (ticketQty > remaining) { ticketQty = Math.max(1, remaining); renderQty(); }

  window._roundEnd  = Number(s.roundEnd);
  window._isDevMode = s.isDevMode;
}

function mysteryStatusText(amount, min, chance) {
  if (amount >= min) return `${e8sToIcp(amount)} / ${e8sToIcp(min)} - eligible - ${chance} chance`;
  return `${e8sToIcp(amount)} / ${e8sToIcp(min)} - not eligible`;
}

// ── Countdown ──────────────────────────────────────────────────────────────

function startCountdown() {
  let justRefreshed = false;
  setInterval(() => {
    const el = document.getElementById("countdown");
    if (!window._roundEnd) { el.textContent = "--:--:--"; return; }
    const endMs = Number(window._roundEnd) / 1_000_000;
    const diff  = Math.max(0, endMs - Date.now());
    const h = Math.floor(diff / 3_600_000);
    const m = Math.floor((diff % 3_600_000) / 60_000);
    const s = Math.floor((diff % 60_000) / 1_000);
    el.textContent = `${pad(h)}:${pad(m)}:${pad(s)}`;

    if (diff === 0 && !justRefreshed) {
      justRefreshed = true;
      const poll = setInterval(async () => {
        await refreshRound();
        await refreshWinners();
        if (window._roundEnd && Number(window._roundEnd) / 1_000_000 > Date.now()) {
          justRefreshed = false;
          clearInterval(poll);
        }
      }, 3_000);
    }
  }, 1000);
}

// ── Wallet ─────────────────────────────────────────────────────────────────

document.getElementById("copy-principal").addEventListener("click", () => {
  const p = document.getElementById("wallet-principal").textContent;
  navigator.clipboard.writeText(p).then(() => {
    const btn = document.getElementById("copy-principal");
    btn.textContent = "Copied!";
    setTimeout(() => btn.textContent = "Copy", 1500);
  });
});

document.getElementById("refresh-balance").addEventListener("click", refreshBalance);

document.getElementById("send-btn").addEventListener("click", async () => {
  if (!ledgerActor || !identity) return;
  const toText  = document.getElementById("send-to").value.trim();
  const amtText = document.getElementById("send-amount").value.trim();
  const msg     = document.getElementById("send-msg");

  if (!toText || !amtText) { setMsg(msg, "Fill in all fields.", "error"); return; }

  let toPrincipal;
  try { toPrincipal = Principal.fromText(toText); }
  catch { setMsg(msg, "Invalid principal.", "error"); return; }

  const amtE8s = Math.round(parseFloat(amtText) * 1e8);
  if (isNaN(amtE8s) || amtE8s <= 10_000) {
    setMsg(msg, "Amount too small (min 0.0002 ICP to cover fee).", "error"); return;
  }

  const btn = document.getElementById("send-btn");
  btn.disabled = true;
  setMsg(msg, "Sending…", "");
  try {
    const res = await ledgerActor.icrc1_transfer({
      to:              { owner: toPrincipal, subaccount: [] },
      amount:          BigInt(amtE8s) - 10_000n,
      fee:             [10_000n],
      memo:            [],
      from_subaccount: [],
      created_at_time: [],
    });
    if ("Ok" in res) {
      setMsg(msg, `Sent! Block #${res.Ok}`, "success");
      toast("ICP sent successfully", "success");
      refreshBalance();
    } else {
      const errKey = Object.keys(res.Err)[0];
      const detail = res.Err[errKey];
      const errMsg = errKey === "InsufficientFunds"
        ? `Insufficient funds (balance: ${e8sToIcp(detail.balance)})`
        : errKey;
      setMsg(msg, errMsg, "error");
    }
  } catch (e) {
    setMsg(msg, String(e), "error");
  }
  btn.disabled = false;
});

async function refreshMyHistory() {
  if (!lotteryActor || !identity) return;
  const el = document.getElementById("my-history-list");
  if (!el) return;
  el.innerHTML = `<div class="my-history-empty">Loading…</div>`;
  try {
    const myPrincipal = identity.getPrincipal();
    const [myRoundsRaw, allWinners, status] = await Promise.all([
      lotteryActor.getMyRounds(myPrincipal),
      lotteryActor.getWinnerHistory(),
      lotteryActor.getRoundStatus(),
    ]);

    if (myRoundsRaw.length === 0) {
      el.innerHTML = `<div class="my-history-empty">No rounds participated in yet</div>`;
      return;
    }

    const winnerMap = new Map();
    for (const r of allWinners) winnerMap.set(Number(r.roundId), r);
    const currentRoundId = Number(status.roundId);
    const myAddr = myPrincipal.toText();

    el.innerHTML = myRoundsRaw.map(([roundId, myTickets, totalTickets]) => {
      const rid    = Number(roundId);
      const my     = Number(myTickets);
      const tot    = Number(totalTickets);
      const record = winnerMap.get(rid);
      const isActive = rid === currentRoundId;

      const wonDaily  = record && record.winner.toText() === myAddr;
      const wonSmall  = record && record.smallWinner.length  > 0 && record.smallWinner[0].toText()  === myAddr;
      const wonMedium = record && record.mediumWinner.length > 0 && record.mediumWinner[0].toText() === myAddr;
      const wonLarge  = record && record.largeWinner.length  > 0 && record.largeWinner[0].toText()  === myAddr;
      const wonAny    = wonDaily || wonSmall || wonMedium || wonLarge;

      const pct    = tot > 0 ? (my / tot * 100) : 0;
      const pctStr = pct >= 1 ? `${pct.toFixed(1)}%` : `${pct.toFixed(2)}%`;

      let badges = "";
      if (wonDaily)  badges += `<span class="mhr-won">🏆 ${e8sToIcp(record.amountWon)}</span>`;
      if (wonSmall)  badges += `<span class="mhr-mystery small">🔮 ${e8sToIcp(record.smallAmt)}</span>`;
      if (wonMedium) badges += `<span class="mhr-mystery medium">✨ ${e8sToIcp(record.mediumAmt)}</span>`;
      if (wonLarge)  badges += `<span class="mhr-mystery large">💎 ${e8sToIcp(record.largeAmt)}</span>`;
      if (isActive)  badges += `<span class="mhr-active">Active</span>`;
      if (!wonAny && !isActive) badges += `<span class="mhr-lost">Not won</span>`;

      return `<div class="my-history-row${wonAny ? " mhr-winner" : ""}">
        <span class="mhr-round">#${rid}</span>
        <span class="mhr-tickets">${my} of ${tot} tickets · ${pctStr}</span>
        ${badges}
      </div>`;
    }).join("");
  } catch (e) { console.error(e); }
}

async function refreshBalance() {
  if (!identity) return;
  const el = document.getElementById("wallet-balance");
  el.textContent = "Loading…";
  try {
    const host = IS_LOCAL ? HOST : "https://icp-api.io";
    const anonAgent = new HttpAgent({ host });
    if (IS_LOCAL) await anonAgent.fetchRootKey().catch(() => {});
    const la = Actor.createActor(ledgerIdl, { agent: anonAgent, canisterId: LEDGER_ID });
    const bal = await la.icrc1_balance_of({ owner: identity.getPrincipal(), subaccount: [] });
    el.textContent = e8sToIcp(bal);
  } catch (e) {
    try {
      const host = IS_LOCAL ? HOST : "https://icp-api.io";
      const anonAgent = new HttpAgent({ host });
      if (IS_LOCAL) await anonAgent.fetchRootKey().catch(() => {});
      const ta = Actor.createActor(treasuryIdl, { agent: anonAgent, canisterId: TREASURY_ID });
      const winnings = await ta.getMyWinnings(identity.getPrincipal());
      el.textContent = e8sToIcp(winnings) + " (winnings)";
    } catch {
      el.textContent = "—";
    }
  }
}

// ── Live feed ──────────────────────────────────────────────────────────────

async function refreshLiveFeed() {
  const actor = lotteryActor ?? makeAnonActors().lottery;
  try {
    const rows = await actor.getRecentPurchases();
    const el = document.getElementById("live-feed");
    if (rows.length === 0) {
      el.innerHTML = `<div class="live-feed-empty">No tickets yet this round</div>`;
      return;
    }
    el.innerHTML = rows.map(r => {
      const ago = timeAgo(Number(r.timestamp));
      return `<div class="live-feed-row">
        <span class="live-feed-principal">${shortPrincipal(r.buyer.toText())}</span>
        <span class="live-feed-count">${r.count} ticket${r.count > 1 ? "s" : ""}</span>
        <span class="live-feed-time">${ago}</span>
      </div>`;
    }).join("");
  } catch (e) { console.error(e); }
}

async function refreshStats() {
  const anonActors = makeAnonActors();
  const actor = lotteryActor ?? anonActors.lottery;
  const treasury = anonActors.treasury;
  try {
    const [history, status] = await Promise.all([
      actor.getWinnerHistory(),
      actor.getRoundStatus(),
    ]);
    let cycled = 0n, payout = 0n, tickets = 0;
    for (const r of history) {
      const sold = Number(r.ticketsSold);
      const rev  = BigInt(sold) * 10_000_000n;
      cycled  += rev * 10n / 100n;
      payout  += r.amountWon + r.smallAmt + r.mediumAmt + r.largeAmt;
      tickets += sold;
    }
    // Add current round: tickets sold × 0.1 ICP × 10%
    const currentSold = Number(status.ticketsSold);
    cycled  += BigInt(currentSold) * 10_000_000n * 10n / 100n;
    tickets += currentSold;

    const [lotteryHealth, treasuryHealth] = await Promise.allSettled([
      actor.getCyclesHealth(),
      treasury.getCyclesHealth(),
    ]);

    renderCyclesStat(
      lotteryHealth.status === "fulfilled" ? lotteryHealth.value : null,
      treasuryHealth.status === "fulfilled" ? treasuryHealth.value : null,
      cycled,
    );
    document.getElementById("stat-rounds").textContent  = String(history.length);
    document.getElementById("stat-tickets").textContent = String(tickets);
    document.getElementById("stat-payout").textContent  = e8sToIcp(payout);
  } catch (e) { console.error(e); }
}

function renderCyclesStat(lotteryHealth, treasuryHealth, fundedE8s) {
  const el = document.getElementById("stat-burned");
  if (!lotteryHealth || !treasuryHealth) {
    el.textContent = e8sToIcp(fundedE8s);
    return;
  }

  const lotteryCycles = BigInt(lotteryHealth.balance);
  const treasuryCycles = BigInt(treasuryHealth.balance);
  const visibleTotal = lotteryCycles + treasuryCycles;

  el.innerHTML = `
    <span class="cycles-total">${formatCycles(visibleTotal)}</span>
    <span class="cycles-row"><span>Lottery</span><strong>${formatCycles(lotteryCycles)}</strong></span>
    <span class="cycles-row"><span>Treasury</span><strong>${formatCycles(treasuryCycles)}</strong></span>
    <span class="cycles-row muted"><span>Frontend</span><strong>dfx only</strong></span>
  `;
}

async function refreshTransparency() {
  const { lottery, treasury } = makeAnonActors();
  const [lotteryHealth, treasuryHealth, accounting] = await Promise.allSettled([
    lottery.getCyclesHealth(),
    treasury.getCyclesHealth(),
    treasury.getTreasuryAccounting(),
  ]);

  if (lotteryHealth.status === "fulfilled") {
    const h = lotteryHealth.value;
    setText("health-lottery-cycles", formatCycles(BigInt(h.balance)));
    setText("health-last-buy", formatCycleDelta(h.lastBuyCyclesDelta));
    setText("health-last-draw", formatCycleDelta(h.lastDrawCyclesDelta));
  }

  if (treasuryHealth.status === "fulfilled") {
    const h = treasuryHealth.value;
    setText("health-treasury-cycles", formatCycles(BigInt(h.balance)));
    setText("health-last-settle", formatCycleDelta(h.lastSettleCyclesDelta));
    setText("health-cmc-status", h.lastCmcError === "none" ? "OK" : h.lastCmcError);
    setText("health-config-status", h.lotteryConfigured && h.frontendConfigured ? "OK" : "Incomplete");
  }

  if (accounting.status === "fulfilled") {
    const a = accounting.value;
    setText("accounting-ledger-balance", e8sToIcp(BigInt(a.ledgerBalance)));
    setText("accounting-total-pools", e8sToIcp(BigInt(a.totalPools)));
    setText("accounting-buffer", e8sToIcp(BigInt(a.unallocatedBalance)));
    setText("accounting-deficit", e8sToIcp(BigInt(a.poolDeficit)));
    setText("accounting-payout-status", a.lastPayoutError === "none" || a.lastPayoutError === "ok" ? "OK" : a.lastPayoutError);
    setText("accounting-payout-note", a.lastPayoutNote || "none");
    setText("accounting-small-eligibility", mysteryStatusText(BigInt(a.smallPool), BigInt(a.minSmall), "25%"));
    setText("accounting-medium-eligibility", mysteryStatusText(BigInt(a.mediumPool), BigInt(a.minMedium), "10%"));
    setText("accounting-large-eligibility", mysteryStatusText(BigInt(a.largePool), BigInt(a.minLarge), "3%"));
  }
}

function timeAgo(ns) {
  const sec = Math.floor((Date.now() - ns / 1_000_000) / 1000);
  if (sec < 60) return `${sec}s ago`;
  if (sec < 3600) return `${Math.floor(sec/60)}m ago`;
  return `${Math.floor(sec/3600)}h ago`;
}

// ── Modal ──────────────────────────────────────────────────────────────────

window.closeModal = function() {
  document.getElementById("modal-overlay").classList.add("hidden");
};

async function showWinnerModal(record) {
  const actor = lotteryActor ?? makeAnonActors().lottery;
  const date = new Date(Number(record.timestamp) / 1_000_000).toLocaleString("en-GB", {
    day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit"
  });
  const bi = Number(record.blockIndex);
  const noTickets = record.winner.toText() === "aaaaa-aa" && Number(record.amountWon) === 0;

  document.getElementById("modal-title").textContent = `Round #${record.roundId}`;

  let participantsHtml = "";
  let winnerChanceHtml = "";

  if (actor && !noTickets) {
    try {
      const entries = await actor.getRoundTickets(Number(record.roundId));
      if (entries.length > 0) {
        const entrySum    = entries.reduce((s, [, n]) => s + Number(n), 0);
        const total       = Math.max(entrySum, Number(record.ticketsSold));
        const winnerEntry = entries.find(([p]) => p.toText() === record.winner.toText());
        const winnerTix   = winnerEntry ? Number(winnerEntry[1]) : 0;
        const pctWon      = total > 0 && winnerTix > 0 ? (winnerTix / total * 100) : 0;

        if (winnerTix > 0) {
          winnerChanceHtml = `<div class="mwh-chance">${winnerTix} of ${total} ticket${total !== 1 ? "s" : ""} · <span class="mwh-pct">${pctWon >= 1 ? pctWon.toFixed(1) : pctWon.toFixed(2)}% win chance</span></div>`;
        }

        const isHistorical = entrySum < total;
        const sorted = [...entries].sort((a, b) => Number(b[1]) - Number(a[1]));
        const rows = sorted.map(([p, n]) => {
          const isWinner = p.toText() === record.winner.toText();
          const pct = Math.round(Number(n) / total * 100);
          return `<div class="participant-row${isWinner ? " winner-row" : ""}">
            <span class="p-principal">${shortPrincipal(p.toText())}</span>
            <span class="p-tickets-bar"><span class="p-bar-fill" style="width:${pct}%"></span></span>
            <span class="p-tickets">${n} ticket${Number(n) > 1 ? "s" : ""}${isWinner ? " 🏆" : ""}</span>
          </div>`;
        }).join("");

        const walletCount = entries.length;
        const headerRight = isHistorical ? `${total} tickets total` : `${walletCount} wallet${walletCount > 1 ? "s" : ""} · ${total} tickets`;
        participantsHtml = `
          <div class="modal-participants">
            <div class="mp-header"><span>${isHistorical ? "Winner" : "Participants"}</span><span>${headerRight}</span></div>
            ${rows}
          </div>`;
      }
    } catch (e) {}
  }

  // Mystery drops this round
  let mysteryHtml = "";
  const hasMystery = record.smallWinner.length > 0 || record.mediumWinner.length > 0 || record.largeWinner.length > 0;
  if (hasMystery) {
    const drops = [];
    if (record.smallWinner.length > 0)  drops.push(`<div class="mystery-drop small">🔮 Small Mystery · ${e8sToIcp(record.smallAmt)} → ${shortPrincipal(record.smallWinner[0].toText())}</div>`);
    if (record.mediumWinner.length > 0) drops.push(`<div class="mystery-drop medium">✨ Medium Mystery · ${e8sToIcp(record.mediumAmt)} → ${shortPrincipal(record.mediumWinner[0].toText())}</div>`);
    if (record.largeWinner.length > 0)  drops.push(`<div class="mystery-drop large">💎 Large Mystery · ${e8sToIcp(record.largeAmt)} → ${shortPrincipal(record.largeWinner[0].toText())}</div>`);
    mysteryHtml = `<div class="modal-mystery-drops">${drops.join("")}</div>`;
  }

  document.getElementById("modal-body").innerHTML = `
    <div class="modal-winner-hero">
      <div class="mwh-badge badge-normal">Daily Draw</div>
      <div class="mwh-prize">${noTickets ? "No tickets" : e8sToIcp(record.amountWon)}</div>
      ${noTickets ? "" : `<div class="mwh-winner">${record.winner.toText()}</div>`}
      ${winnerChanceHtml}
    </div>
    ${mysteryHtml}
    <div class="modal-meta">
      <div class="meta-item"><span class="meta-label">Tickets sold</span><span class="meta-val">${record.ticketsSold}</span></div>
      <div class="meta-item"><span class="meta-label">Date</span><span class="meta-val">${date}</span></div>
      ${bi > 0 ? `<div class="meta-item"><span class="meta-label">Block</span><a class="tx-link" href="${EXPLORER_BASE}${bi}" target="_blank">#${bi}</a></div>` : ""}
    </div>
    ${participantsHtml}
  `;

  document.getElementById("modal-overlay").classList.remove("hidden");
}

// ── Winners ────────────────────────────────────────────────────────────────

async function refreshWinners() {
  const actor = lotteryActor ?? makeAnonActors().lottery;
  winnersOffset = 0;
  const tbody = document.getElementById("winners-tbody");
  tbody.innerHTML = "";
  try {
    const rows = await actor.getWinnerHistoryPaged(0, WINNERS_PAGE);
    winnersOffset = rows.length;
    if (rows.length === 0) {
      tbody.innerHTML = `<tr><td colspan="6" class="empty-state">No draws yet</td></tr>`;
      return;
    }
    appendWinners(rows);
  } catch (e) { console.error(e); }
}

document.getElementById("load-more-winners").addEventListener("click", async () => {
  const actor = lotteryActor ?? makeAnonActors().lottery;
  const more = await actor.getWinnerHistoryPaged(winnersOffset, WINNERS_PAGE).catch(() => []);
  appendWinners(more);
});

function appendWinners(rows) {
  const tbody = document.getElementById("winners-tbody");
  const empty = tbody.querySelector(".empty-state");
  if (empty) empty.parentElement.remove();

  rows.forEach(r => {
    const date = new Date(Number(r.timestamp) / 1_000_000).toLocaleDateString("en-GB", {
      day: "2-digit", month: "short", year: "numeric",
    });
    const bi = Number(r.blockIndex);
    const noTickets = r.winner.toText() === "aaaaa-aa" && Number(r.amountWon) === 0;

    // Mystery icons for this row
    const mysteries = [
      r.smallWinner.length  > 0 ? "🔮" : "",
      r.mediumWinner.length > 0 ? "✨" : "",
      r.largeWinner.length  > 0 ? "💎" : "",
    ].filter(Boolean).join(" ");

    const tr = document.createElement("tr");
    tr.style.cursor = noTickets ? "default" : "pointer";
    if (!noTickets) tr.title = "Click for details";
    tr.innerHTML = `
      <td>#${r.roundId}</td>
      <td class="principal-short">${noTickets ? `<span style="color:var(--text-muted)">No tickets</span>` : shortPrincipal(r.winner.toText())}</td>
      <td>${noTickets ? `<span style="color:var(--text-muted)">—</span>` : e8sToIcp(r.amountWon)}</td>
      <td>${mysteries || `<span style="color:var(--text-muted)">—</span>`}</td>
      <td><span style="color:var(--text-muted)">${noTickets ? "—" : bi > 0 ? `<a class="tx-link" href="${EXPLORER_BASE}${bi}" target="_blank">#${bi}</a>` : window._isDevMode ? "dev" : "pending"}</span></td>
      <td>${date}</td>
    `;
    if (!noTickets) tr.addEventListener("click", e => {
      if (e.target.tagName === "A") return;
      showWinnerModal(r);
    });
    tbody.appendChild(tr);
  });

  winnersOffset += rows.length;
  const btn = document.getElementById("load-more-winners");
  if (rows.length === WINNERS_PAGE) btn.classList.remove("hidden");
  else btn.classList.add("hidden");
}

// ── Buy progress overlay ───────────────────────────────────────────────────

const BUY_STEPS = [
  { id: "step-approve", icon: "✍",  label: "Approving ICP spend…"    },
  { id: "step-buy",     icon: "🎟", label: "Registering tickets…"    },
  { id: "step-cycles",  icon: "⚙️", label: "Converting 10% to cycles…" },
];

let _progressOverlay = null;

function createProgressOverlay() {
  const overlay = document.createElement("div");
  overlay.className = "buy-progress-overlay";
  overlay.innerHTML = `
    <div class="buy-progress-card">
      <div class="buy-progress-title">Buying tickets</div>
      <div class="buy-step-list">
        ${BUY_STEPS.map(s => `
          <div class="buy-step" id="${s.id}">
            <div class="buy-step-icon">${s.icon}</div>
            <div class="buy-step-label">${s.label}</div>
          </div>`).join("")}
      </div>
    </div>`;
  document.body.appendChild(overlay);
  requestAnimationFrame(() => overlay.classList.add("visible"));
  return overlay;
}

function setStep(stepId, state, labelOverride) {
  if (!_progressOverlay) return;
  const el = _progressOverlay.querySelector(`#${stepId}`);
  if (!el) return;
  el.className = `buy-step ${state}`;
  if (state === "active") el.querySelector(".buy-step-icon").innerHTML = "↻";
  if (labelOverride) el.querySelector(".buy-step-label").textContent = labelOverride;
}

function openProgressOverlay() {
  _progressOverlay = createProgressOverlay();
}

function closeProgressOverlay() {
  if (!_progressOverlay) return;
  const ov = _progressOverlay;
  _progressOverlay = null;
  ov.classList.remove("visible");
  setTimeout(() => ov.remove(), 300);
}

// ── Toast ──────────────────────────────────────────────────────────────────

function toast(message, type = "info") {
  const el = document.createElement("div");
  el.className = `toast toast-${type}`;
  el.textContent = message;
  document.body.appendChild(el);
  setTimeout(() => el.classList.add("toast-show"), 20);
  setTimeout(() => {
    el.classList.remove("toast-show");
    setTimeout(() => el.remove(), 400);
  }, 4000);
}

// ── Helpers ────────────────────────────────────────────────────────────────

function e8sToIcp(e8s) {
  return `${(Number(e8s) / 1e8).toFixed(4)} ICP`;
}

function formatCycles(cycles) {
  const n = Number(cycles);
  if (n >= 1e12) return `${(n / 1e12).toFixed(3)}T`;
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  return String(n);
}

function formatCycleDelta(delta) {
  const n = Number(delta);
  const sign = n > 0 ? "+" : n < 0 ? "-" : "";
  return `${sign}${formatCycles(BigInt(Math.abs(n)))} cycles`;
}

function shortPrincipal(p) {
  const parts = p.split("-");
  return `${parts[0]}...${parts[parts.length - 1]}`;
}

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}

function setMsg(el, text, type) {
  el.textContent = text;
  el.className = `${el.className.split(" ")[0]}${type ? ` ${type}` : ""}`;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function pad(n) { return String(n).padStart(2, "0"); }
