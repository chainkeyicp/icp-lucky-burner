# ICP Lucky Burner

## Deploy locally

```bash
# 1. Start local replica
dfx start --background --clean

# 2. Deploy ledger (local test version)
dfx deploy ledger

# 3. Deploy canisters
dfx deploy treasury
dfx deploy lottery

# 4. Set dev principal (replace with your principal)
dfx canister call treasury setDevPrincipal '("YOUR_PRINCIPAL_HERE")'

# 5. Frontend
cd src/frontend
npm install
npm run build
cd ../..
dfx deploy frontend

# 6. Open in browser
dfx canister id frontend
# → http://localhost:4943?canisterId=<frontend_id>
```

## Dev mode

The app starts in **dev mode** (isDevMode = true).
Use the orange "Simulate End of Day" button to trigger a draw without waiting 24 hours.

To switch to production mode (real 24h timer):
```bash
dfx canister call lottery setDevMode '(false)'
```

## Mainnet deploy

```bash
dfx deploy --network ic
```

## Build & verification

Production:

- Website: https://luckyburner.fun/
- Repository: https://github.com/chainkeyicp/icp-lucky-burner
- Current published commit: `3b7e887253a0`

Canisters:

| Canister | ID | Live module hash |
| --- | --- | --- |
| lottery | `m3n4c-3qaaa-aaaal-qw55a-cai` | `0x06363d1e7ce7287761d2f12fdb711acd184e44998df687a08370523f71eda6c8` |
| treasury | `msox6-nyaaa-aaaal-qw54q-cai` | `0xa17d9ff20c5b052304d3b613ba3524002cb3664d959722363a3ca9eaf161f39b` |
| frontend | `m4m2w-wiaaa-aaaal-qw55q-cai` | `0x865eb25df5a6d857147e078bb33c727797957247f7af2635846d65c5397b36a6` |

Check the live module hashes:

```bash
export DFX_WARNING=-mainnet_plaintext_identity
dfx canister --network ic status m3n4c-3qaaa-aaaal-qw55a-cai
dfx canister --network ic status msox6-nyaaa-aaaal-qw54q-cai
dfx canister --network ic status m4m2w-wiaaa-aaaal-qw55q-cai
```

Rebuild from the published commit:

```bash
git clone https://github.com/chainkeyicp/icp-lucky-burner.git
cd icp-lucky-burner
git checkout 3b7e887253a0
cd src/frontend
npm ci
cd ../..
dfx build --network ic
```

Generate local build hashes:

```bash
sha256sum .dfx/ic/canisters/lottery/lottery.wasm
sha256sum .dfx/ic/canisters/treasury/treasury.wasm
sha256sum .dfx/ic/canisters/frontend/frontend.wasm.gz
find src/frontend/dist -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
```

The GitHub Actions workflow `.github/workflows/verify-build.yml` also builds the project and uploads `build-hashes.txt` as an artifact for each run. Module hashes shown by `dfx canister status` are the IC-installed module hashes; local SHA-256 build hashes are a reproducibility aid and may require the same dfx/toolchain versions to match exactly.
